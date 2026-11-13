import AVFoundation
import CoreImage
import CoreMotion
import Flutter
import ImageIO
import UIKit
import Vision

/// eski's camera engine for iOS, built on AVFoundation: manual exposure,
/// focus and white balance, Bayer RAW (DNG) capture, lens selection and a
/// zero-copy preview delivered to a Flutter texture.
final class EskiCameraPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate,
  AVCaptureFileOutputRecordingDelegate
{
  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = EskiCameraPlugin(textures: registrar.textures())
    let channel = FlutterMethodChannel(name: "eski/camera", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: channel)
    FlutterEventChannel(name: "eski/camera/events", binaryMessenger: registrar.messenger())
      .setStreamHandler(plugin)
  }

  private let textures: FlutterTextureRegistry
  private var textureId: Int64 = -1
  private var events: FlutterEventSink?

  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "eski.camera.session")
  private let frameQueue = DispatchQueue(label: "eski.camera.frames")
  private var device: AVCaptureDevice?
  private let photoOutput = AVCapturePhotoOutput()
  private let frameOutput = AVCaptureVideoDataOutput()
  private let movieOutput = AVCaptureMovieFileOutput()
  private var videoMode = false

  private let bufferLock = NSLock()
  private var latestBuffer: CVPixelBuffer?
  private var frameCount = 0

  // Controls
  private var iso: Float?
  private var shutter: Double?
  private var autoExposure = true
  private var ev: Float = 0
  private var aeLock = false
  private var wbAuto = true
  private var temperature: Float = 5500
  private var focusAuto = true
  private var focusDistance: Float = 0
  private var zoom: CGFloat = 1
  private var flash = "off"

  private let motion = CMMotionManager()
  private var captureOrientation: AVCaptureVideoOrientation = .portrait
  private var levelEnabled = false
  private var stateTimer: Timer?

  private var photoResult: FlutterResult?
  private var photoJpeg: String?
  private var photoRaw: String?
  private var videoResult: FlutterResult?

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
  }

  // MARK: Plumbing

  func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    events = eventSink
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    events = nil
    return nil
  }

  private func emit(_ map: [String: Any]) {
    DispatchQueue.main.async { self.events?(map) }
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    bufferLock.lock()
    defer { bufferLock.unlock() }
    guard let buffer = latestBuffer else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "requestPermission":
      requestPermission(audio: args["audio"] as? Bool ?? false, result: result)
    case "getCameras":
      result(listCameras())
    case "open":
      open(args, result: result)
    case "close":
      close()
      result(nil)
    case "setControls":
      setControls(args)
      result(nil)
    case "focusAt":
      focus(at: CGPoint(x: (args["x"] as? NSNumber)?.doubleValue ?? 0.5, y: (args["y"] as? NSNumber)?.doubleValue ?? 0.5))
      result(nil)
    case "setLevel":
      levelEnabled = args["enabled"] as? Bool ?? false
      result(nil)
    case "takePhoto":
      takePhoto(jpeg: args["jpeg"] as? Bool ?? true, raw: args["raw"] as? Bool ?? false, result: result)
    case "startVideo":
      startVideo(result: result)
    case "pauseVideo":
      result(false)  // AVCaptureMovieFileOutput cannot pause on iOS
    case "resumeVideo":
      result(nil)
    case "stopVideo":
      stopVideo(result: result)
    case "encodeJpeg":
      encodeJpeg(args, result: result)
    case "developRaw":
      developRaw(args["path"] as? String ?? "", result: result)
    case "segmentSubject":
      segmentSubject(args["path"] as? String ?? "", out: args["out"] as? String ?? "", result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestPermission(audio: Bool, result: @escaping FlutterResult) {
    AVCaptureDevice.requestAccess(for: .video) { granted in
      if audio {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
          DispatchQueue.main.async { result(granted) }
        }
      } else {
        DispatchQueue.main.async { result(granted) }
      }
    }
  }

  // MARK: Capabilities

  private func discover() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
      mediaType: .video,
      position: .unspecified
    ).devices
  }

  private func listCameras() -> [[String: Any]] {
    let devices = discover()
    let mainFov = devices.first { $0.position == .back && $0.deviceType == .builtInWideAngleCamera }?
      .activeFormat.videoFieldOfView ?? 0
    return devices.map { d in
      let f = d.activeFormat
      var rel = 1.0
      if d.position == .back, mainFov > 0, f.videoFieldOfView > 0 {
        rel = Double(tan(mainFov * .pi / 360) / tan(f.videoFieldOfView * .pi / 360))
      }
      var videoSizes: [[Int]] = []
      for (preset, w, h) in [
        (AVCaptureSession.Preset.hd4K3840x2160, 3840, 2160), (.hd1920x1080, 1920, 1080), (.hd1280x720, 1280, 720),
      ] where d.supportsSessionPreset(preset) {
        var maxFps = 30.0
        for format in d.formats {
          let dim = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
          if Int(dim.width) == w && Int(dim.height) == h {
            for range in format.videoSupportedFrameRateRanges { maxFps = max(maxFps, range.maxFrameRate) }
          }
        }
        videoSizes.append([w, h, Int(min(maxFps, 60))])
      }
      let still = f.highResolutionStillImageDimensions
      let lens: String
      switch d.deviceType {
      case .builtInUltraWideCamera: lens = "ultrawide"
      case .builtInTelephotoCamera: lens = "tele"
      default: lens = "wide"
      }
      return [
        "id": d.uniqueID,
        "facing": d.position == .front ? "front" : "back",
        "lens": lens,
        "zoomLabel": (rel * 10).rounded() / 10,
        "manualExposure": d.isExposureModeSupported(.custom),
        "manualFocus": d.isLockingFocusWithCustomLensPositionSupported,
        "manualWb": d.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
        // Bayer RAW availability is confirmed when the session opens.
        "raw": d.position == .back,
        "flash": d.hasFlash,
        "ois": false,
        "videoStabilization": f.isVideoStabilizationModeSupported(.standard),
        "minIso": Double(f.minISO),
        "maxIso": Double(f.maxISO),
        "minShutter": CMTimeGetSeconds(f.minExposureDuration),
        "maxShutter": min(CMTimeGetSeconds(f.maxExposureDuration), 30),
        "minEv": Double(d.minExposureTargetBias),
        "maxEv": Double(d.maxExposureTargetBias),
        "minZoom": 1.0,
        "maxZoom": Double(min(f.videoMaxZoomFactor, 10)),
        "photoSizes": [[Int(max(still.width, still.height)), Int(min(still.width, still.height))]],
        "videoSizes": videoSizes,
      ]
    }
  }

  // MARK: Session

  private func open(_ args: [String: Any], result: @escaping FlutterResult) {
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
      result(FlutterError(code: "permission", message: "Camera permission not granted", details: nil))
      return
    }
    guard let id = args["cameraId"] as? String, let dev = AVCaptureDevice(uniqueID: id) else {
      result(FlutterError(code: "camera", message: "Camera not found", details: nil))
      return
    }
    let video = args["video"] as? Bool ?? false
    let videoHeight = (args["videoHeight"] as? NSNumber)?.intValue ?? 1080
    let fps = (args["fps"] as? NSNumber)?.doubleValue ?? 30
    let stabilize = args["stabilization"] as? Bool ?? true
    if textureId < 0 { textureId = textures.register(self) }

    sessionQueue.async {
      self.iso = nil; self.shutter = nil; self.autoExposure = true; self.ev = 0; self.aeLock = false
      self.wbAuto = true; self.focusAuto = true; self.zoom = 1
      self.device = dev
      self.videoMode = video
      let s = self.session
      if s.isRunning { s.stopRunning() }
      s.beginConfiguration()
      s.inputs.forEach { s.removeInput($0) }
      s.outputs.forEach { s.removeOutput($0) }
      if video {
        let preset: AVCaptureSession.Preset =
          videoHeight >= 2160 ? .hd4K3840x2160 : (videoHeight >= 1080 ? .hd1920x1080 : .hd1280x720)
        s.sessionPreset = dev.supportsSessionPreset(preset) ? preset : .high
      } else {
        s.sessionPreset = .photo
      }
      guard let input = try? AVCaptureDeviceInput(device: dev), s.canAddInput(input) else {
        s.commitConfiguration()
        DispatchQueue.main.async {
          result(FlutterError(code: "camera", message: "This camera could not be opened", details: nil))
        }
        return
      }
      s.addInput(input)
      if video {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
          let mic = AVCaptureDevice.default(for: .audio),
          let micInput = try? AVCaptureDeviceInput(device: mic), s.canAddInput(micInput)
        {
          s.addInput(micInput)
        }
        if s.canAddOutput(self.movieOutput) { s.addOutput(self.movieOutput) }
      } else if s.canAddOutput(self.photoOutput) {
        s.addOutput(self.photoOutput)
        self.photoOutput.isHighResolutionCaptureEnabled = true
      }
      self.frameOutput.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
      self.frameOutput.alwaysDiscardsLateVideoFrames = true
      self.frameOutput.setSampleBufferDelegate(self, queue: self.frameQueue)
      if s.canAddOutput(self.frameOutput) { s.addOutput(self.frameOutput) }
      if let c = self.frameOutput.connection(with: .video) {
        if c.isVideoOrientationSupported { c.videoOrientation = .portrait }
        if c.isVideoMirroringSupported { c.isVideoMirrored = false }
      }
      if video, let c = self.movieOutput.connection(with: .video), c.isVideoStabilizationSupported {
        c.preferredVideoStabilizationMode = stabilize ? .auto : .off
      }
      s.commitConfiguration()

      if video, (try? dev.lockForConfiguration()) != nil {
        let supported = dev.activeFormat.videoSupportedFrameRateRanges.contains {
          $0.minFrameRate <= fps && fps <= $0.maxFrameRate
        }
        if supported {
          let d = CMTime(value: 1, timescale: CMTimeScale(fps))
          dev.activeVideoMinFrameDuration = d
          dev.activeVideoMaxFrameDuration = d
        }
        dev.unlockForConfiguration()
      }
      s.startRunning()

      let dim = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
      let hasRaw = !video && self.photoOutput.availableRawPhotoPixelFormatTypes.contains {
        AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
      }
      DispatchQueue.main.async {
        self.startSensors()
        result([
          "textureId": self.textureId,
          "width": Int(min(dim.width, dim.height)),
          "height": Int(max(dim.width, dim.height)),
          "quarterTurns": 0,
          "analysis": true,
          "raw": hasRaw,
        ])
      }
    }
  }

  private func close() {
    stateTimer?.invalidate()
    stateTimer = nil
    motion.stopAccelerometerUpdates()
    sessionQueue.async {
      if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
      if self.session.isRunning { self.session.stopRunning() }
      self.bufferLock.lock()
      self.latestBuffer = nil
      self.bufferLock.unlock()
    }
  }

  private func startSensors() {
    stateTimer?.invalidate()
    stateTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
      guard let self = self, let d = self.device else { return }
      self.events?([
        "type": "state",
        "iso": Double(d.iso),
        "shutter": CMTimeGetSeconds(d.exposureDuration),
        "focus": Double(1 - d.lensPosition),
        "aperture": Double(d.lensAperture),
      ])
    }
    guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
    motion.accelerometerUpdateInterval = 1.0 / 15.0
    motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
      guard let self = self, let a = data?.acceleration else { return }
      if (a.x * a.x + a.y * a.y) * 4 < a.z * a.z { return }  // lying flat
      var angle = atan2(a.x, -a.y) * 180 / .pi  // clockwise from upright portrait
      if angle < 0 { angle += 360 }
      switch Int((angle + 45) / 90) % 4 {
      case 1: self.captureOrientation = .landscapeLeft
      case 2: self.captureOrientation = .portraitUpsideDown
      case 3: self.captureOrientation = .landscapeRight
      default: self.captureOrientation = .portrait
      }
      if self.levelEnabled {
        self.events?(["type": "level", "roll": (angle + 45).truncatingRemainder(dividingBy: 90) - 45])
      }
    }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    bufferLock.lock()
    latestBuffer = buffer
    bufferLock.unlock()
    textures.textureFrameAvailable(textureId)

    frameCount += 1
    guard frameCount % 5 == 0, events != nil else { return }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let p = base.assumingMemoryBound(to: UInt8.self)
    var bins = [Int](repeating: 0, count: 64)
    var y = 0
    while y < height {
      var x = 0
      let row = y * stride
      while x < width {
        let i = row + x * 4
        let luma = (Int(p[i]) * 29 + Int(p[i + 1]) * 150 + Int(p[i + 2]) * 77) >> 8
        bins[luma >> 2] += 1
        x += 8
      }
      y += 8
    }
    let peak = max(1, bins.max() ?? 1)
    emit(["type": "histogram", "bins": bins.map { $0 * 255 / peak }])
  }

  // MARK: Controls

  private func setControls(_ a: [String: Any]) {
    if let v = a["autoExposure"] as? Bool { autoExposure = v }
    if a.keys.contains("iso") { iso = (a["iso"] as? NSNumber)?.floatValue }
    if a.keys.contains("shutter") { shutter = (a["shutter"] as? NSNumber)?.doubleValue }
    if let v = a["ev"] as? NSNumber { ev = v.floatValue }
    if let v = a["aeLock"] as? Bool { aeLock = v }
    if let v = a["wbAuto"] as? Bool { wbAuto = v }
    if let v = a["temperature"] as? NSNumber { temperature = v.floatValue }
    if let v = a["focusAuto"] as? Bool { focusAuto = v }
    if let v = a["focusDistance"] as? NSNumber { focusDistance = v.floatValue }
    if let v = a["zoom"] as? NSNumber { zoom = CGFloat(v.doubleValue) }
    if let v = a["flash"] as? String { flash = v }
    let reset = a["focusReset"] as? Bool ?? false
    sessionQueue.async { self.applyControls(resetFocus: reset) }
  }

  private func applyControls(resetFocus: Bool) {
    guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
    defer { d.unlockForConfiguration() }
    let f = d.activeFormat

    if !autoExposure && d.isExposureModeSupported(.custom) {
      let duration: CMTime
      if let s = shutter {
        let lo = CMTimeGetSeconds(f.minExposureDuration), hi = CMTimeGetSeconds(f.maxExposureDuration)
        duration = CMTime(seconds: min(max(s, lo), hi), preferredTimescale: 1_000_000_000)
      } else {
        duration = AVCaptureDevice.currentExposureDuration
      }
      let sensitivity = iso.map { min(max($0, f.minISO), f.maxISO) } ?? AVCaptureDevice.currentISO
      d.setExposureModeCustom(duration: duration, iso: sensitivity, completionHandler: nil)
    } else {
      let mode: AVCaptureDevice.ExposureMode = aeLock ? .locked : .continuousAutoExposure
      if d.isExposureModeSupported(mode) { d.exposureMode = mode }
      d.setExposureTargetBias(min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias), completionHandler: nil)
    }

    if wbAuto {
      if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
        d.whiteBalanceMode = .continuousAutoWhiteBalance
      }
    } else if d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
      var g = d.deviceWhiteBalanceGains(
        for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0))
      let top = d.maxWhiteBalanceGain
      g.redGain = min(max(g.redGain, 1), top)
      g.greenGain = min(max(g.greenGain, 1), top)
      g.blueGain = min(max(g.blueGain, 1), top)
      d.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
    }

    if !focusAuto && d.isLockingFocusWithCustomLensPositionSupported {
      d.setFocusModeLocked(lensPosition: 1 - min(max(focusDistance, 0), 1), completionHandler: nil)
    } else if resetFocus || (focusAuto && d.focusMode == .locked) {
      if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
      if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
      if autoExposure, d.isExposurePointOfInterestSupported {
        d.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
      }
    }

    d.videoZoomFactor = min(max(zoom, d.minAvailableVideoZoomFactor), min(f.videoMaxZoomFactor, 10))

    if d.hasTorch {
      let on = flash == "torch" && d.isTorchModeSupported(.on)
      if d.torchMode != (on ? .on : .off) { d.torchMode = on ? .on : .off }
    }
  }

  private func focus(at point: CGPoint) {
    sessionQueue.async {
      guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
      defer { d.unlockForConfiguration() }
      // Upright portrait coordinates → the sensor's landscape space.
      let poi = CGPoint(x: point.y, y: 1 - point.x)
      if self.focusAuto, d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
        d.focusPointOfInterest = poi
        d.focusMode = .autoFocus
      }
      if self.autoExposure, !self.aeLock, d.isExposurePointOfInterestSupported {
        d.exposurePointOfInterest = poi
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
      }
    }
  }

  // MARK: Stills

  private func tempPath(_ ext: String) -> String {
    NSTemporaryDirectory() + "eski_\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
  }

  private func takePhoto(jpeg: Bool, raw: Bool, result: @escaping FlutterResult) {
    guard !videoMode, session.isRunning, photoResult == nil else {
      result(FlutterError(code: "camera", message: "Camera is not ready", details: nil))
      return
    }
    photoResult = result
    photoJpeg = nil
    photoRaw = nil
    let orientation = captureOrientation
    sessionQueue.async {
      let rawType = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
        AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
      }
      let processed: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.jpeg]
      let settings: AVCapturePhotoSettings
      if raw, let rt = rawType {
        settings =
          jpeg
          ? AVCapturePhotoSettings(rawPixelFormatType: rt, processedFormat: processed)
          : AVCapturePhotoSettings(rawPixelFormatType: rt)
      } else {
        settings = AVCapturePhotoSettings(format: processed)
        settings.isHighResolutionPhotoEnabled = true
        let mode: AVCaptureDevice.FlashMode = self.flash == "on" ? .on : (self.flash == "auto" ? .auto : .off)
        if self.photoOutput.supportedFlashModes.contains(mode) { settings.flashMode = mode }
      }
      if let c = self.photoOutput.connection(with: .video), c.isVideoOrientationSupported {
        c.videoOrientation = orientation
      }
      self.photoOutput.capturePhoto(with: settings, delegate: self)
    }
  }

  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    guard error == nil, let data = photo.fileDataRepresentation() else { return }
    let path = tempPath(photo.isRawPhoto ? "dng" : "jpg")
    do {
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
      if photo.isRawPhoto { photoRaw = path } else { photoJpeg = path }
    } catch {}
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
    error: Error?
  ) {
    let jpeg = photoJpeg
    let raw = photoRaw
    DispatchQueue.main.async {
      let result = self.photoResult
      self.photoResult = nil
      if jpeg == nil && raw == nil {
        result?(FlutterError(code: "capture", message: error?.localizedDescription ?? "Capture failed", details: nil))
      } else {
        result?(["jpeg": jpeg as Any, "raw": raw as Any])
      }
    }
  }

  // MARK: Video

  private func startVideo(result: @escaping FlutterResult) {
    guard videoMode, session.isRunning, !movieOutput.isRecording else {
      result(FlutterError(code: "camera", message: "Camera is not in video mode", details: nil))
      return
    }
    let orientation = captureOrientation
    sessionQueue.async {
      if let c = self.movieOutput.connection(with: .video), c.isVideoOrientationSupported {
        c.videoOrientation = orientation
      }
      self.movieOutput.startRecording(to: URL(fileURLWithPath: self.tempPath("mov")), recordingDelegate: self)
      DispatchQueue.main.async { result(nil) }
    }
  }

  private func stopVideo(result: @escaping FlutterResult) {
    guard movieOutput.isRecording else {
      result(nil)
      return
    }
    videoResult = result
    sessionQueue.async { self.movieOutput.stopRecording() }
  }

  func fileOutput(
    _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection], error: Error?
  ) {
    // A recording that hit a limit still produced a usable file.
    let ok = error == nil
      || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
    DispatchQueue.main.async {
      self.videoResult?(ok ? outputFileURL.path : nil)
      self.videoResult = nil
    }
  }

  // MARK: Imaging helpers

  private func encodeJpeg(_ a: [String: Any], result: @escaping FlutterResult) {
    guard let data = (a["rgba"] as? FlutterStandardTypedData)?.data,
      let width = (a["width"] as? NSNumber)?.intValue, let height = (a["height"] as? NSNumber)?.intValue,
      let path = a["path"] as? String
    else {
      result(FlutterError(code: "encode", message: "Bad arguments", details: nil))
      return
    }
    let quality = Double((a["quality"] as? NSNumber)?.intValue ?? 95) / 100
    DispatchQueue.global(qos: .userInitiated).async {
      let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
      guard let provider = CGDataProvider(data: data as CFData),
        let image = CGImage(
          width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider, decode: nil,
          shouldInterpolate: false, intent: .defaultIntent),
        let dest = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil)
      else {
        DispatchQueue.main.async { result(FlutterError(code: "encode", message: "Could not encode", details: nil)) }
        return
      }
      CGImageDestinationAddImage(
        dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      let ok = CGImageDestinationFinalize(dest)
      DispatchQueue.main.async {
        result(ok ? nil : FlutterError(code: "encode", message: "Could not write file", details: nil))
      }
    }
  }

  private func developRaw(_ path: String, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let url = URL(fileURLWithPath: path)
      guard let filter = CIFilter(imageURL: url, options: [:]), let image = filter.outputImage else {
        DispatchQueue.main.async {
          result(FlutterError(code: "raw", message: "This RAW format is not supported on this device", details: nil))
        }
        return
      }
      let out = NSTemporaryDirectory() + "raw_\(abs(path.hashValue)).jpg"
      let context = CIContext()
      do {
        try context.writeJPEGRepresentation(
          of: image, to: URL(fileURLWithPath: out), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 1.0])
        DispatchQueue.main.async { result(out) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "raw", message: error.localizedDescription, details: nil)) }
      }
    }
  }

  /// Person matte via Vision, fully on-device. Writes a white PNG whose alpha
  /// is the subject, upright like the decoded photograph.
  private func segmentSubject(_ path: String, out: String, result: @escaping FlutterResult) {
    guard #available(iOS 15.0, *) else {
      result(nil)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let done: (String?) -> Void = { v in DispatchQueue.main.async { result(v) } }
      let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 1536,
      ] as CFDictionary
      guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
      else { return done(nil) }
      let request = VNGeneratePersonSegmentationRequest()
      request.qualityLevel = .accurate
      request.outputPixelFormat = kCVPixelFormatType_OneComponent8
      do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
      } catch { return done(nil) }
      guard let buffer = request.results?.first?.pixelBuffer else { return done(nil) }
      var mask = CIImage(cvPixelBuffer: buffer)
      mask = mask.transformed(
        by: CGAffineTransform(
          scaleX: CGFloat(image.width) / mask.extent.width, y: CGFloat(image.height) / mask.extent.height))
      let context = CIContext()
      // A frame with nobody in it would blur everything; report no subject.
      var avg = [UInt8](repeating: 0, count: 4)
      if let mean = CIFilter(
        name: "CIAreaAverage", parameters: [kCIInputImageKey: mask, kCIInputExtentKey: CIVector(cgRect: mask.extent)]
      )?.outputImage {
        context.render(
          mean, toBitmap: &avg, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
          colorSpace: nil)
      }
      if avg[0] < 5 { return done(nil) }
      guard let alpha = CIFilter(name: "CIMaskToAlpha", parameters: [kCIInputImageKey: mask])?.outputImage,
        let matte = context.createCGImage(alpha, from: mask.extent),
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)
      else { return done(nil) }
      CGImageDestinationAddImage(dest, matte, nil)
      done(CGImageDestinationFinalize(dest) ? out : nil)
    }
  }
}
