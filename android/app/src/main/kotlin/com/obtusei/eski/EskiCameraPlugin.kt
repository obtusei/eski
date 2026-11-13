package com.obtusei.eski

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.DngCreator
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.ColorSpaceTransform
import android.hardware.camera2.params.MeteringRectangle
import android.hardware.camera2.params.RggbChannelVector
import android.media.Image
import android.media.ExifInterface
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Range
import android.util.Size
import android.view.Surface
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * eski's camera engine for Android, built directly on Camera2 so that manual
 * sensor controls, RAW (DNG) capture and per-device capability detection are
 * available. Preview frames go straight to a Flutter texture; no frame copies.
 */
class EskiCameraPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, PluginRegistry.RequestPermissionsResultListener, SensorEventListener {

    private lateinit var context: Context
    private lateinit var textures: TextureRegistry
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private var thread: HandlerThread? = null
    private var bg: Handler? = null
    private var pendingPermission: MethodChannel.Result? = null

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var chars: CameraCharacteristics? = null
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var previewSurface: Surface? = null
    private var jpegReader: ImageReader? = null
    private var rawReader: ImageReader? = null
    private var analysisReader: ImageReader? = null
    private var analysisActive = false
    private var recorder: MediaRecorder? = null
    private var recorderSurface: Surface? = null
    private var videoMode = false
    private var videoSize = Size(1920, 1080)
    private var fps = 30
    private var recording = false
    private var videoPath: String? = null
    private var recordAudio = true

    // Controls
    private var iso: Int? = null
    private var shutterNs: Long? = null
    private var autoExposure = true
    private var evSteps = 0
    private var aeLock = false
    private var wbAuto = true
    private var temperature = 5500f
    private var focusAuto = true
    private var focusDistance = 0f
    private var zoom = 1f
    private var flash = "off"
    private var stabilization = true
    private var afRegion: MeteringRectangle? = null

    // Last values reported by the sensor
    private var lastIso = 100
    private var lastShutter = 10_000_000L
    private var lastGains: RggbChannelVector? = null
    private var baseGains: RggbChannelVector? = null
    private var lastTransform: ColorSpaceTransform? = null
    private var lastStateEvent = 0L
    private var lastHistogram = 0L
    private var lastLevel = 0L

    private var deviceOrientation = 0
    private var levelEnabled = false
    private var shot: PendingShot? = null

    private class PendingShot(val result: MethodChannel.Result, val wantJpeg: Boolean, val wantRaw: Boolean) {
        var jpegPath: String? = null
        var rawPath: String? = null
        var rawImage: Image? = null
        var capture: TotalCaptureResult? = null
    }

    private val manager get() = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    // region plumbing

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        textures = binding.textureRegistry
        MethodChannel(binding.binaryMessenger, "eski/camera").setMethodCallHandler(this)
        EventChannel(binding.binaryMessenger, "eski/camera/events").setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) = closeCamera()

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activity = null
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    private fun emit(map: Map<String, Any?>) = main.post { events?.success(map) }

    private fun granted(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray): Boolean {
        if (code != PERMISSION_CODE) return false
        pendingPermission?.success(granted(Manifest.permission.CAMERA))
        pendingPermission = null
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "requestPermission" -> requestPermission(call.argument<Boolean>("audio") == true, result)
                "getCameras" -> result.success(listCameras())
                "open" -> open(call, result)
                "close" -> {
                    closeCamera()
                    result.success(null)
                }
                "setControls" -> {
                    setControls(call)
                    result.success(null)
                }
                "focusAt" -> {
                    focusAt(call.argument<Number>("x")!!.toFloat(), call.argument<Number>("y")!!.toFloat())
                    result.success(null)
                }
                "setLevel" -> {
                    levelEnabled = call.argument<Boolean>("enabled") == true
                    result.success(null)
                }
                "takePhoto" -> takePhoto(call.argument<Boolean>("jpeg") != false, call.argument<Boolean>("raw") == true, result)
                "startVideo" -> startVideo(call.argument<Boolean>("audio") != false, result)
                "pauseVideo" -> {
                    recorder?.pause()
                    result.success(true)
                }
                "resumeVideo" -> {
                    recorder?.resume()
                    result.success(null)
                }
                "stopVideo" -> stopVideo(result)
                "encodeJpeg" -> encodeJpeg(call, result)
                "developRaw" -> developRaw(call.argument<String>("path")!!, result)
                "segmentSubject" -> segmentSubject(call.argument<String>("path")!!, call.argument<String>("out")!!, result)
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("camera", e.message ?: e.toString(), null)
        }
    }

    private fun requestPermission(audio: Boolean, result: MethodChannel.Result) {
        val need = mutableListOf<String>()
        if (!granted(Manifest.permission.CAMERA)) need.add(Manifest.permission.CAMERA)
        if (audio && !granted(Manifest.permission.RECORD_AUDIO)) need.add(Manifest.permission.RECORD_AUDIO)
        val a = activity
        if (need.isEmpty() || a == null) {
            result.success(granted(Manifest.permission.CAMERA))
            return
        }
        pendingPermission = result
        a.requestPermissions(need.toTypedArray(), PERMISSION_CODE)
    }

    // endregion
    // region capabilities

    private fun hasCap(c: CameraCharacteristics, cap: Int) =
        c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.contains(cap) == true

    private fun fovRatio(c: CameraCharacteristics): Float {
        val f = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.firstOrNull() ?: return 1f
        val s = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE) ?: return 1f
        return f / Math.hypot(s.width.toDouble(), s.height.toDouble()).toFloat()
    }

    private fun listCameras(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        var mainRatio = 0f
        for (id in manager.cameraIdList) {
            val c = manager.getCameraCharacteristics(id)
            val facing = c.get(CameraCharacteristics.LENS_FACING)
            if (facing == CameraCharacteristics.LENS_FACING_EXTERNAL) continue
            val front = facing == CameraCharacteristics.LENS_FACING_FRONT
            val ratio = fovRatio(c)
            if (!front && mainRatio == 0f) mainRatio = ratio
            val rel = if (front || mainRatio == 0f) 1f else ratio / mainRatio
            val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: continue
            val manual = hasCap(c, CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR)
            val isoRange = c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
            val expRange = c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
            val evRange = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
            val evStep = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)?.toFloat() ?: 0f
            val minFocus = c.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
            val zoomRange = if (Build.VERSION.SDK_INT >= 30) c.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) else null
            val maxZoom = zoomRange?.upper ?: c.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
            val fpsRanges = c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES) ?: emptyArray()
            val maxFps = fpsRanges.filter { it.lower == it.upper }.maxOfOrNull { it.upper } ?: 30
            val photoSizes = (map.getOutputSizes(ImageFormat.JPEG) ?: emptyArray())
                .sortedByDescending { it.width.toLong() * it.height }
                .filter { abs(it.width.toFloat() / it.height - 4f / 3f) < 0.03f }
                .take(4).map { listOf(it.width, it.height) }
            val videoSizes = (map.getOutputSizes(MediaRecorder::class.java) ?: emptyArray())
                .filter { it.height in listOf(2160, 1080, 720) && abs(it.width.toFloat() / it.height - 16f / 9f) < 0.03f }
                .sortedByDescending { it.height }
                .map { listOf(it.width, it.height, if (it.height > 1080) min(maxFps, 30) else maxFps) }
            val ois = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
                ?.contains(CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON) == true
            val vstab = c.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
                ?.contains(CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_ON) == true
            out.add(
                mapOf(
                    "id" to id,
                    "facing" to if (front) "front" else "back",
                    "lens" to if (rel < 0.75f) "ultrawide" else if (rel > 1.5f) "tele" else "wide",
                    "zoomLabel" to (rel * 10).roundToInt() / 10.0,
                    "manualExposure" to (manual && isoRange != null && expRange != null),
                    "manualFocus" to (manual && minFocus > 0f),
                    "manualWb" to hasCap(c, CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING),
                    "raw" to (hasCap(c, CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_RAW) &&
                        map.getOutputSizes(ImageFormat.RAW_SENSOR)?.isNotEmpty() == true),
                    "flash" to (c.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true),
                    "ois" to ois,
                    "videoStabilization" to vstab,
                    "minIso" to (isoRange?.lower ?: 0),
                    "maxIso" to (isoRange?.upper ?: 0),
                    "minShutter" to (expRange?.lower ?: 0L) / 1e9,
                    "maxShutter" to min((expRange?.upper ?: 0L) / 1e9, 30.0),
                    "minEv" to (evRange?.lower ?: 0) * evStep.toDouble(),
                    "maxEv" to (evRange?.upper ?: 0) * evStep.toDouble(),
                    "minZoom" to (zoomRange?.lower ?: 1f).toDouble(),
                    "maxZoom" to min(maxZoom, 10f).toDouble(),
                    "photoSizes" to photoSizes,
                    "videoSizes" to videoSizes,
                ),
            )
        }
        return out
    }

    // endregion
    // region session

    @SuppressLint("MissingPermission")
    private fun open(call: MethodCall, result: MethodChannel.Result) {
        closeCamera()
        if (!granted(Manifest.permission.CAMERA)) {
            result.error("permission", "Camera permission not granted", null)
            return
        }
        val id = call.argument<String>("cameraId")!!
        val c = manager.getCameraCharacteristics(id)
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
        chars = c
        videoMode = call.argument<Boolean>("video") == true
        fps = call.argument<Number>("fps")?.toInt() ?: 30
        stabilization = call.argument<Boolean>("stabilization") != false
        val wantRaw = call.argument<Boolean>("raw") == true && !videoMode
        // Per-camera state does not carry across lenses.
        iso = null; shutterNs = null; autoExposure = true; aeLock = false; afRegion = null
        focusAuto = true; wbAuto = true; baseGains = null; zoom = 1f; evSteps = 0

        thread = HandlerThread("eski-camera").also { it.start() }
        bg = Handler(thread!!.looper)

        val aspect = if (videoMode) 16f / 9f else 4f / 3f
        val previewSizes = map.getOutputSizes(SurfaceTexture::class.java)
        val preview = previewSizes
            .filter { abs(it.width.toFloat() / it.height - aspect) < 0.03f && it.height <= 1440 }
            .maxByOrNull { it.width.toLong() * it.height } ?: previewSizes.first()

        val p = textures.createSurfaceProducer()
        p.setSize(preview.width, preview.height)
        producer = p
        previewSurface = p.surface

        val surfaces = mutableListOf(previewSurface!!)
        if (videoMode) {
            val vh = call.argument<Number>("videoHeight")?.toInt() ?: 1080
            val vs = map.getOutputSizes(MediaRecorder::class.java)
                .filter { abs(it.width.toFloat() / it.height - 16f / 9f) < 0.03f }
            videoSize = vs.firstOrNull { it.height == vh } ?: vs.firstOrNull { it.height == 1080 } ?: vs.first()
            recorderSurface = MediaCodec.createPersistentInputSurface()
            prepareRecorder()
            surfaces.add(recorderSurface!!)
        } else {
            val pw = call.argument<Number>("photoWidth")?.toInt() ?: 0
            val ph = call.argument<Number>("photoHeight")?.toInt() ?: 0
            val jpegSizes = map.getOutputSizes(ImageFormat.JPEG)
            val js = jpegSizes.firstOrNull { it.width == pw && it.height == ph }
                ?: jpegSizes.filter { abs(it.width.toFloat() / it.height - 4f / 3f) < 0.03f }
                    .maxByOrNull { it.width.toLong() * it.height }
                ?: jpegSizes.maxByOrNull { it.width.toLong() * it.height }!!
            jpegReader = ImageReader.newInstance(js.width, js.height, ImageFormat.JPEG, 2).also {
                it.setOnImageAvailableListener({ r -> onJpeg(r) }, bg)
                surfaces.add(it.surface)
            }
            if (wantRaw) {
                map.getOutputSizes(ImageFormat.RAW_SENSOR)?.maxByOrNull { it.width.toLong() * it.height }?.let { rs ->
                    rawReader = ImageReader.newInstance(rs.width, rs.height, ImageFormat.RAW_SENSOR, 2).also {
                        it.setOnImageAvailableListener({ r -> onRaw(r) }, bg)
                        surfaces.add(it.surface)
                    }
                }
            }
        }
        val ys = map.getOutputSizes(ImageFormat.YUV_420_888)
            ?.filter { it.width >= 320 }?.minByOrNull { it.width.toLong() * it.height }
        if (ys != null) {
            analysisReader = ImageReader.newInstance(ys.width, ys.height, ImageFormat.YUV_420_888, 2).also {
                it.setOnImageAvailableListener({ r -> onAnalysis(r) }, bg)
            }
        }

        var replied = false
        fun reply(error: String?) {
            if (replied) return
            replied = true
            main.post {
                if (error != null) {
                    result.error("camera", error, null)
                } else {
                    val so = c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
                    result.success(
                        mapOf(
                            "textureId" to p.id(),
                            "width" to if (so % 180 == 0) preview.width else preview.height,
                            "height" to if (so % 180 == 0) preview.height else preview.width,
                            "quarterTurns" to if (p.handlesCropAndRotation()) 0 else so / 90,
                            "analysis" to analysisActive,
                            "raw" to (rawReader != null),
                        ),
                    )
                }
            }
        }

        fun configure(d: CameraDevice, withAnalysis: Boolean) {
            val list = if (withAnalysis && analysisReader != null) surfaces + analysisReader!!.surface else surfaces
            val cb = object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(s: CameraCaptureSession) {
                    session = s
                    analysisActive = withAnalysis && analysisReader != null
                    try {
                        startRepeating()
                        reply(null)
                    } catch (e: Exception) {
                        reply(e.message ?: "Could not start preview")
                    }
                }

                override fun onConfigureFailed(s: CameraCaptureSession) {
                    // Four concurrent streams are not guaranteed on every device;
                    // drop the histogram stream and try again.
                    if (withAnalysis) configure(d, false) else reply("This camera could not be configured")
                }
            }
            @Suppress("DEPRECATION")
            d.createCaptureSession(list, cb, bg)
        }

        manager.openCamera(id, object : CameraDevice.StateCallback() {
            override fun onOpened(d: CameraDevice) {
                device = d
                try {
                    configure(d, true)
                } catch (e: Exception) {
                    reply(e.message ?: "Could not configure camera")
                }
            }

            override fun onDisconnected(d: CameraDevice) {
                d.close()
                if (device == d) device = null
                reply("Camera disconnected")
            }

            override fun onError(d: CameraDevice, error: Int) {
                d.close()
                if (device == d) device = null
                reply("Camera error $error")
                emit(mapOf("type" to "error", "message" to "Camera error $error"))
            }
        }, bg)

        val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
            sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
        }
    }

    private fun closeCamera() {
        try {
            if (recording) recorder?.stop()
        } catch (_: Exception) {
        }
        recording = false
        try { session?.close() } catch (_: Exception) {}
        try { device?.close() } catch (_: Exception) {}
        session = null
        device = null
        jpegReader?.close(); jpegReader = null
        rawReader?.close(); rawReader = null
        analysisReader?.close(); analysisReader = null
        analysisActive = false
        recorder?.release(); recorder = null
        recorderSurface?.release(); recorderSurface = null
        producer?.release(); producer = null
        previewSurface = null
        thread?.quitSafely(); thread = null; bg = null
        shot = null
        (context.getSystemService(Context.SENSOR_SERVICE) as SensorManager).unregisterListener(this)
    }

    private val captureCallback = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureCompleted(s: CameraCaptureSession, request: CaptureRequest, r: TotalCaptureResult) {
            r.get(CaptureResult.SENSOR_SENSITIVITY)?.let { lastIso = it }
            r.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let { lastShutter = it }
            if (wbAuto) {
                r.get(CaptureResult.COLOR_CORRECTION_GAINS)?.let { lastGains = it }
                r.get(CaptureResult.COLOR_CORRECTION_TRANSFORM)?.let { lastTransform = it }
            }
            val now = System.currentTimeMillis()
            if (now - lastStateEvent < 200) return
            lastStateEvent = now
            val minFocus = chars?.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
            val fd = r.get(CaptureResult.LENS_FOCUS_DISTANCE) ?: 0f
            emit(
                mapOf(
                    "type" to "state",
                    "iso" to lastIso,
                    "shutter" to lastShutter / 1e9,
                    "focus" to if (minFocus > 0f) (fd / minFocus).toDouble() else 0.0,
                    "aperture" to (r.get(CaptureResult.LENS_APERTURE) ?: 0f).toDouble(),
                ),
            )
        }
    }

    private fun startRepeating() {
        val d = device ?: return
        val s = session ?: return
        val b = d.createCaptureRequest(if (videoMode) CameraDevice.TEMPLATE_RECORD else CameraDevice.TEMPLATE_PREVIEW)
        b.addTarget(previewSurface!!)
        if (analysisActive) b.addTarget(analysisReader!!.surface)
        if (recording) b.addTarget(recorderSurface!!)
        applyControls(b, false)
        s.setRepeatingRequest(b.build(), captureCallback, bg)
    }

    private fun applyControls(b: CaptureRequest.Builder, still: Boolean) {
        val c = chars ?: return
        b.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)

        if (Build.VERSION.SDK_INT >= 30) {
            b.set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom)
        } else {
            c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)?.let { a ->
                val z = max(1f, zoom)
                val w = (a.width() / z).toInt()
                val h = (a.height() / z).toInt()
                val x = (a.width() - w) / 2
                val y = (a.height() - h) / 2
                b.set(CaptureRequest.SCALER_CROP_REGION, Rect(x, y, x + w, y + h))
            }
        }

        val manual = !autoExposure && hasCap(c, CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR)
        if (manual) {
            b.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_OFF)
            b.set(CaptureRequest.SENSOR_SENSITIVITY, iso ?: lastIso)
            b.set(CaptureRequest.SENSOR_EXPOSURE_TIME, shutterNs ?: lastShutter)
            b.set(
                CaptureRequest.FLASH_MODE,
                when {
                    flash == "torch" -> CameraMetadata.FLASH_MODE_TORCH
                    still && flash == "on" -> CameraMetadata.FLASH_MODE_SINGLE
                    else -> CameraMetadata.FLASH_MODE_OFF
                },
            )
        } else {
            b.set(
                CaptureRequest.CONTROL_AE_MODE,
                when (flash) {
                    "auto" -> CameraMetadata.CONTROL_AE_MODE_ON_AUTO_FLASH
                    "on" -> CameraMetadata.CONTROL_AE_MODE_ON_ALWAYS_FLASH
                    else -> CameraMetadata.CONTROL_AE_MODE_ON
                },
            )
            b.set(
                CaptureRequest.FLASH_MODE,
                if (flash == "torch") CameraMetadata.FLASH_MODE_TORCH else CameraMetadata.FLASH_MODE_OFF,
            )
            b.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, evSteps)
            b.set(CaptureRequest.CONTROL_AE_LOCK, aeLock)
            if (videoMode) {
                val ranges = c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES) ?: emptyArray()
                ranges.firstOrNull { it.lower == fps && it.upper == fps }?.let {
                    b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(fps, fps))
                }
            }
        }

        if (wbAuto) {
            b.set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_AUTO)
        } else if (hasCap(c, CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING)) {
            b.set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_OFF)
            b.set(CaptureRequest.COLOR_CORRECTION_MODE, CameraMetadata.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX)
            b.set(CaptureRequest.COLOR_CORRECTION_GAINS, manualGains())
            lastTransform?.let { b.set(CaptureRequest.COLOR_CORRECTION_TRANSFORM, it) }
        } else {
            // No manual gains on this device: use the nearest built-in illuminant.
            val modes = c.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES) ?: intArrayOf()
            val want = when {
                temperature < 3600 -> CameraMetadata.CONTROL_AWB_MODE_INCANDESCENT
                temperature < 4600 -> CameraMetadata.CONTROL_AWB_MODE_FLUORESCENT
                temperature < 6000 -> CameraMetadata.CONTROL_AWB_MODE_DAYLIGHT
                temperature < 7200 -> CameraMetadata.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT
                else -> CameraMetadata.CONTROL_AWB_MODE_SHADE
            }
            b.set(CaptureRequest.CONTROL_AWB_MODE, if (modes.contains(want)) want else CameraMetadata.CONTROL_AWB_MODE_AUTO)
        }

        val minFocus = c.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
        val region = afRegion
        if (!focusAuto && minFocus > 0f) {
            b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
            b.set(CaptureRequest.LENS_FOCUS_DISTANCE, focusDistance * minFocus)
        } else if (region != null) {
            b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_AUTO)
            if ((c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0) > 0) {
                b.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(region))
            }
        } else {
            b.set(
                CaptureRequest.CONTROL_AF_MODE,
                if (videoMode) CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO
                else CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE,
            )
        }
        if (region != null && !manual && (c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0) > 0) {
            b.set(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(region))
        }

        val ois = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
            ?.contains(CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON) == true
        if (ois) {
            b.set(
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                if (stabilization) CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_ON
                else CameraMetadata.LENS_OPTICAL_STABILIZATION_MODE_OFF,
            )
        }
        if (videoMode && stabilization && !ois &&
            c.get(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
                ?.contains(CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_ON) == true
        ) {
            b.set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CameraMetadata.CONTROL_VIDEO_STABILIZATION_MODE_ON)
        }
    }

    /** Approximate RGB of a black-body illuminant (Tanner Helland's fit). */
    private fun kelvinRgb(k: Float): FloatArray {
        val t = k / 100f
        val r = if (t <= 66) 255.0 else 329.698727446 * (t - 60.0).pow(-0.1332047592)
        val g = if (t <= 66) 99.4708025861 * ln(t.toDouble()) - 161.1195681661
        else 288.1221695283 * (t - 60.0).pow(-0.0755148492)
        val b = if (t >= 66) 255.0 else if (t <= 19) 0.0 else 138.5177312231 * ln(t - 10.0) - 305.0447927307
        return floatArrayOf(
            (r.coerceIn(1.0, 255.0) / 255).toFloat(),
            (g.coerceIn(1.0, 255.0) / 255).toFloat(),
            (b.coerceIn(1.0, 255.0) / 255).toFloat(),
        )
    }

    /** Gains for the chosen colour temperature, relative to the last auto result. */
    private fun manualGains(): RggbChannelVector {
        val base = baseGains ?: lastGains ?: RggbChannelVector(2f, 1f, 1f, 1.6f)
        val ref = kelvinRgb(5500f)
        val cur = kelvinRgb(temperature)
        val gk = ref[1] / cur[1]
        return RggbChannelVector(
            base.red * (ref[0] / cur[0]) / gk,
            base.greenEven,
            base.greenOdd,
            base.blue * (ref[2] / cur[2]) / gk,
        )
    }

    private fun setControls(call: MethodCall) {
        val c = chars ?: return
        if (call.hasArgument("autoExposure")) autoExposure = call.argument<Boolean>("autoExposure") != false
        if (call.hasArgument("iso")) iso = call.argument<Number>("iso")?.toInt()
        if (call.hasArgument("shutter")) shutterNs = call.argument<Number>("shutter")?.let { (it.toDouble() * 1e9).toLong() }
        if (call.hasArgument("ev")) {
            val step = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)?.toFloat() ?: 0f
            if (step > 0f) evSteps = (call.argument<Number>("ev")!!.toFloat() / step).roundToInt()
        }
        if (call.hasArgument("aeLock")) aeLock = call.argument<Boolean>("aeLock") == true
        if (call.hasArgument("wbAuto")) {
            val auto = call.argument<Boolean>("wbAuto") != false
            if (wbAuto && !auto) baseGains = lastGains
            wbAuto = auto
        }
        if (call.hasArgument("temperature")) temperature = call.argument<Number>("temperature")!!.toFloat()
        if (call.hasArgument("focusAuto")) {
            focusAuto = call.argument<Boolean>("focusAuto") != false
            if (focusAuto && call.argument<Boolean>("focusReset") == true) afRegion = null
        }
        if (call.hasArgument("focusReset") && call.argument<Boolean>("focusReset") == true) afRegion = null
        if (call.hasArgument("focusDistance")) focusDistance = call.argument<Number>("focusDistance")!!.toFloat()
        if (call.hasArgument("zoom")) zoom = call.argument<Number>("zoom")!!.toFloat()
        if (call.hasArgument("flash")) flash = call.argument<String>("flash") ?: "off"
        bg?.post { try { startRepeating() } catch (_: Exception) {} }
    }

    private fun focusAt(x: Float, y: Float) {
        val c = chars ?: return
        val a = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return
        // Undo the display rotation to land in sensor coordinates.
        val (sx, sy) = when (c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90) {
            90 -> y to 1f - x
            180 -> 1f - x to 1f - y
            270 -> 1f - y to x
            else -> x to y
        }
        val half = (min(a.width(), a.height()) * 0.08f).toInt()
        val cx = (sx * a.width()).toInt().coerceIn(half, a.width() - half)
        val cy = (sy * a.height()).toInt().coerceIn(half, a.height() - half)
        afRegion = MeteringRectangle(cx - half, cy - half, half * 2, half * 2, MeteringRectangle.METERING_WEIGHT_MAX)
        bg?.post {
            try {
                startRepeating()
                if (focusAuto) {
                    val d = device ?: return@post
                    val b = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                    b.addTarget(previewSurface!!)
                    applyControls(b, false)
                    b.set(CaptureRequest.CONTROL_AF_TRIGGER, CameraMetadata.CONTROL_AF_TRIGGER_START)
                    session?.capture(b.build(), null, bg)
                }
            } catch (_: Exception) {
            }
        }
    }

    // endregion
    // region stills

    private fun captureRotation(): Int {
        val c = chars ?: return 0
        val so = c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        val front = c.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT
        val dev = if (front) -deviceOrientation else deviceOrientation
        return (so + dev + 360) % 360
    }

    private fun takePhoto(jpeg: Boolean, raw: Boolean, result: MethodChannel.Result) {
        val d = device
        val s = session
        if (d == null || s == null || videoMode) {
            result.error("camera", "Camera is not ready", null)
            return
        }
        if (shot != null) {
            result.error("busy", "A capture is already in progress", null)
            return
        }
        val useRaw = raw && rawReader != null
        val useJpeg = jpeg || !useRaw
        val handler = bg ?: return
        handler.post {
            try {
                shot = PendingShot(result, useJpeg, useRaw)
                val needsPrecapture = flash != "off" && flash != "torch" && autoExposure
                if (needsPrecapture) {
                    val pb = d.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                    pb.addTarget(previewSurface!!)
                    applyControls(pb, false)
                    pb.set(
                        CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER,
                        CameraMetadata.CONTROL_AE_PRECAPTURE_TRIGGER_START,
                    )
                    s.capture(pb.build(), null, handler)
                }
                handler.postDelayed({ fireStill(d, s, useJpeg, useRaw) }, if (needsPrecapture) 900L else 0L)
            } catch (e: Exception) {
                failShot(e.message ?: "Capture failed")
            }
        }
    }

    private fun fireStill(d: CameraDevice, s: CameraCaptureSession, jpeg: Boolean, raw: Boolean) {
        try {
            val b = d.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
            if (jpeg) b.addTarget(jpegReader!!.surface)
            if (raw) {
                b.addTarget(rawReader!!.surface)
                b.set(
                    CaptureRequest.STATISTICS_LENS_SHADING_MAP_MODE,
                    CameraMetadata.STATISTICS_LENS_SHADING_MAP_MODE_ON,
                )
            }
            applyControls(b, true)
            b.set(CaptureRequest.JPEG_ORIENTATION, captureRotation())
            b.set(CaptureRequest.JPEG_QUALITY, 97.toByte())
            s.capture(b.build(), object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(cs: CameraCaptureSession, rq: CaptureRequest, r: TotalCaptureResult) {
                    shot?.capture = r
                    finishShot()
                }

                override fun onCaptureFailed(
                    cs: CameraCaptureSession,
                    rq: CaptureRequest,
                    failure: android.hardware.camera2.CaptureFailure,
                ) = failShot("Capture failed")
            }, bg)
        } catch (e: Exception) {
            failShot(e.message ?: "Capture failed")
        }
    }

    private fun onJpeg(reader: ImageReader) {
        val image = reader.acquireNextImage() ?: return
        try {
            val sh = shot ?: return
            val buf = image.planes[0].buffer
            val bytes = ByteArray(buf.remaining())
            buf.get(bytes)
            val part = File(context.cacheDir, "eski_${System.currentTimeMillis()}.jpg.part")
            FileOutputStream(part).use { it.write(bytes) }
            val out = File(part.path.removeSuffix(".part"))
            part.renameTo(out)
            sh.jpegPath = out.path
        } catch (e: Exception) {
            failShot(e.message ?: "Could not save photo")
            return
        } finally {
            image.close()
        }
        finishShot()
    }

    private fun onRaw(reader: ImageReader) {
        val image = reader.acquireNextImage() ?: return
        val sh = shot
        if (sh == null || !sh.wantRaw) {
            image.close()
            return
        }
        sh.rawImage = image
        finishShot()
    }

    private fun finishShot() {
        val sh = shot ?: return
        val c = chars ?: return
        val cap = sh.capture
        val rawImage = sh.rawImage
        if (sh.wantRaw && sh.rawPath == null && rawImage != null && cap != null) {
            try {
                val part = File(context.cacheDir, "eski_${System.currentTimeMillis()}.dng.part")
                DngCreator(c, cap).use { dng ->
                    dng.setOrientation(
                        when (captureRotation()) {
                            90 -> 6
                            180 -> 3
                            270 -> 8
                            else -> 1
                        },
                    )
                    FileOutputStream(part).use { dng.writeImage(it, rawImage) }
                }
                val out = File(part.path.removeSuffix(".part"))
                part.renameTo(out)
                sh.rawPath = out.path
            } catch (e: Exception) {
                rawImage.close()
                sh.rawImage = null
                failShot(e.message ?: "Could not write DNG")
                return
            }
            rawImage.close()
            sh.rawImage = null
        }
        if ((sh.wantJpeg && sh.jpegPath == null) || (sh.wantRaw && sh.rawPath == null)) return
        shot = null
        main.post { sh.result.success(mapOf("jpeg" to sh.jpegPath, "raw" to sh.rawPath)) }
    }

    private fun failShot(message: String) {
        val sh = shot ?: return
        shot = null
        sh.rawImage?.close()
        main.post { sh.result.error("capture", message, null) }
    }

    // endregion
    // region video

    private fun prepareRecorder() {
        recorder?.release()
        val audio = recordAudio && granted(Manifest.permission.RECORD_AUDIO)
        @Suppress("DEPRECATION")
        val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
        if (audio) r.setAudioSource(MediaRecorder.AudioSource.CAMCORDER)
        r.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        val path = File(context.cacheDir, "eski_${System.currentTimeMillis()}.mp4").path
        r.setOutputFile(path)
        r.setVideoEncodingBitRate((videoSize.width * videoSize.height * fps * 0.14).toInt())
        r.setVideoFrameRate(fps)
        r.setVideoSize(videoSize.width, videoSize.height)
        r.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
        if (audio) {
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioEncodingBitRate(192_000)
            r.setAudioSamplingRate(48_000)
        }
        r.setOrientationHint(captureRotation())
        r.setInputSurface(recorderSurface!!)
        r.prepare()
        recorder = r
        videoPath = path
    }

    private fun startVideo(audio: Boolean, result: MethodChannel.Result) {
        if (!videoMode || session == null) {
            result.error("camera", "Camera is not in video mode", null)
            return
        }
        recordAudio = audio
        videoPath?.let { File(it).delete() }
        prepareRecorder() // re-prepare so the orientation hint matches how the phone is held now
        recording = true
        bg?.post {
            try {
                startRepeating()
                recorder?.start()
                main.post { result.success(null) }
            } catch (e: Exception) {
                recording = false
                main.post { result.error("video", e.message, null) }
            }
        }
    }

    private fun stopVideo(result: MethodChannel.Result) {
        if (!recording) {
            result.success(null)
            return
        }
        val path = videoPath
        var ok = true
        try {
            recorder?.stop()
        } catch (_: Exception) {
            ok = false // stopped before any frame was written
        }
        recording = false
        videoPath = null
        if (!ok && path != null) File(path).delete()
        bg?.post {
            try {
                startRepeating()
                prepareRecorder()
            } catch (_: Exception) {
            }
        }
        result.success(if (ok) path else null)
    }

    // endregion
    // region analysis + sensors

    private fun onAnalysis(reader: ImageReader) {
        val image = reader.acquireLatestImage() ?: return
        try {
            val now = System.currentTimeMillis()
            if (now - lastHistogram < 120 || events == null) return
            lastHistogram = now
            val plane = image.planes[0]
            val buf = plane.buffer
            val bins = IntArray(64)
            val stride = plane.rowStride
            var y = 0
            while (y < image.height) {
                var x = 0
                val row = y * stride
                while (x < image.width) {
                    val idx = row + x
                    if (idx < buf.limit()) bins[(buf.get(idx).toInt() and 0xFF) shr 2]++
                    x += 4
                }
                y += 4
            }
            val peak = max(1, bins.max())
            emit(mapOf("type" to "histogram", "bins" to bins.map { it * 255 / peak }))
        } catch (_: Exception) {
        } finally {
            image.close()
        }
    }

    override fun onSensorChanged(e: SensorEvent) {
        val x = -e.values[0]
        val y = -e.values[1]
        val z = -e.values[2]
        if ((x * x + y * y) * 4 < z * z) return // lying flat: orientation is undefined
        var angle = 90.0 - Math.toDegrees(atan2(-y.toDouble(), x.toDouble()))
        while (angle >= 360) angle -= 360
        while (angle < 0) angle += 360
        deviceOrientation = ((angle + 45) / 90).toInt() * 90 % 360
        val now = System.currentTimeMillis()
        if (levelEnabled && now - lastLevel > 60) {
            lastLevel = now
            emit(mapOf("type" to "level", "roll" to ((angle + 45) % 90) - 45))
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    // endregion
    // region imaging helpers

    private fun encodeJpeg(call: MethodCall, result: MethodChannel.Result) {
        val rgba = call.argument<ByteArray>("rgba")!!
        val w = call.argument<Int>("width")!!
        val h = call.argument<Int>("height")!!
        val q = call.argument<Int>("quality") ?: 95
        val path = call.argument<String>("path")!!
        Thread {
            try {
                val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                bmp.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
                FileOutputStream(path).use { bmp.compress(Bitmap.CompressFormat.JPEG, q, it) }
                bmp.recycle()
                main.post { result.success(null) }
            } catch (e: Throwable) {
                main.post { result.error("encode", e.message, null) }
            }
        }.start()
    }

    private fun developRaw(path: String, result: MethodChannel.Result) {
        Thread {
            try {
                val bmp = BitmapFactory.decodeFile(path)
                if (bmp == null) {
                    main.post { result.error("raw", "This RAW format is not supported on this device", null) }
                    return@Thread
                }
                val out = File(context.cacheDir, "raw_${File(path).name.hashCode()}_${File(path).length()}.jpg")
                FileOutputStream(out).use { bmp.compress(Bitmap.CompressFormat.JPEG, 100, it) }
                bmp.recycle()
                main.post { result.success(out.path) }
            } catch (e: Throwable) {
                main.post { result.error("raw", e.message, null) }
            }
        }.start()
    }

    /** Person matte via ML Kit selfie segmentation, which runs fully on-device. */
    private fun segmentSubject(path: String, out: String, result: MethodChannel.Result) {
        Thread {
            try {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(path, bounds)
                var sample = 1
                while (max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 1024) sample *= 2
                val decoded = BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })
                if (decoded == null) {
                    main.post { result.success(null) }
                    return@Thread
                }
                val rotation = when (ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                    ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
                val upright = if (rotation == 0f) decoded else
                    Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, Matrix().apply { postRotate(rotation) }, true)
                val segmenter = Segmentation.getClient(
                    SelfieSegmenterOptions.Builder().setDetectorMode(SelfieSegmenterOptions.SINGLE_IMAGE_MODE).build()
                )
                segmenter.process(InputImage.fromBitmap(upright, 0))
                    .addOnSuccessListener { mask ->
                        Thread {
                            try {
                                val w = mask.width
                                val h = mask.height
                                val buf = mask.buffer.apply { rewind() }.asFloatBuffer()
                                val px = IntArray(w * h)
                                var sum = 0.0
                                for (i in 0 until w * h) {
                                    val c = buf.get().coerceIn(0f, 1f)
                                    sum += c
                                    px[i] = ((c * 255f).roundToInt() shl 24) or 0xFFFFFF
                                }
                                if (sum / (w * h) < 0.02) {
                                    main.post { result.success(null) }
                                    return@Thread
                                }
                                val bmp = Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
                                FileOutputStream(out).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                                bmp.recycle()
                                main.post { result.success(out) }
                            } catch (e: Throwable) {
                                main.post { result.success(null) }
                            } finally {
                                segmenter.close()
                                upright.recycle()
                            }
                        }.start()
                    }
                    .addOnFailureListener {
                        segmenter.close()
                        main.post { result.success(null) }
                    }
            } catch (e: Throwable) {
                main.post { result.success(null) }
            }
        }.start()
    }

    // endregion

    companion object {
        private const val PERMISSION_CODE = 7301
    }
}
