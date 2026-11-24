package com.nosmai.zegocloud_live

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.TextureView
import android.view.View
import android.view.WindowManager
import com.nosmai.effect.api.NosmaiSDK
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import im.zego.zegoexpress.ZegoExpressEngine
import im.zego.zegoexpress.constants.ZegoPublishChannel
import im.zego.zegoexpress.constants.ZegoVideoBufferType
import im.zego.zegoexpress.entity.ZegoCustomVideoCaptureConfig
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Flutter side of nosmai_zegocloud_live: MethodChannel `nosmai_zegocloud_live` (commands),
 * EventChannel `nosmai_zegocloud_live/events` (session events) and platform view
 * `nosmai_zegocloud_live/remote_video`.
 *
 * Threads: ZEGO calls run on the main thread; Nosmai/GL setup and teardown run on one command
 * thread so they neither block the UI nor reorder.
 */
class NosmaiZegoLivePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private val main = Handler(Looper.getMainLooper())
    private lateinit var appContext: Context
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private var sink: EventChannel.EventSink? = null
    private var activity: ActivityPluginBinding? = null
    private var pendingPermissions: MethodChannel.Result? = null
    private var screenOn = false
    private val diagnostics = ProcessDiagnostics()
    private val emitter: (Map<String, Any?>) -> Unit = { event -> main.post { onSessionEvent(event) } }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        val owner = session(appContext)
        owner.emit = emitter
        owner.onLeft = { left ->
            // Queued before any newer session's capture start, so it never stops that one.
            if (left.host) currentSource()?.let { source -> commands.execute { source.shutdown() } }
        }
        methods = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
        events = EventChannel(binding.binaryMessenger, "$CHANNEL/events").also { it.setStreamHandler(this) }
        binding.platformViewRegistry.registerViewFactory("$CHANNEL/remote_video", RemoteVideoViewFactory(owner))
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
        // Hot restart or engine teardown: never leave a room or the camera stream running.
        val owner = session(appContext)
        main.post {
            // A new engine (hot restart) may already own the session; leave it alone then.
            detachCamera()
            if (owner.emit !== emitter) return@post
            owner.emit = {}
            runCatching { owner.leave(sessionId = null, endSession = false) }
            runCatching { owner.releaseNow() }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    private fun onSessionEvent(event: Map<String, Any?>) {
        when (event["type"]) {
            "joined" -> if (session(appContext).request?.keepScreenOn == true) setScreenOn(true)
            "left" -> if (!session(appContext).active) setScreenOn(false)
        }
        sink?.success(event)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val owner = session(appContext)
        when (call.method) {
            "prepare" -> background(result) { prepare() }
            "requestPermissions" -> requestPermissions(
                camera = call.argument<Boolean>("camera") != false,
                microphone = call.argument<Boolean>("microphone") != false,
                result = result,
            )
            "attachCamera" -> onMain(result) { attachCamera(owner); null }
            "detachCamera" -> onMain(result, awaitSource = true) {
                detachCamera()
                null
            }
            "join" -> onMain(result) { join(owner, call) }
            "leave" -> onMain(result) {
                owner.leave(call.argument<Number>("sessionId")?.toLong(), call.argument<Boolean>("endSession") == true)
                null
            }
            "renewToken" -> onMain(result) {
                owner.renewToken(call.argument<Number>("sessionId")?.toLong(), call.text("token"))
                null
            }
            "setMicMuted" -> onMain(result) { owner.setMicMuted(call.flag("muted")); null }
            "setVideoMuted" -> onMain(result) { owner.setVideoMuted(call.flag("muted")); null }
            "setSpeakerMuted" -> onMain(result) { owner.setSpeakerMuted(call.flag("muted")); null }
            "setForeground" -> onMain(result) { owner.setForeground(call.flag("foreground")); null }
            "setMaxFps" -> onMain(result) { currentSource()?.setMaxFps(call.argument<Int>("fps") ?: 30); null }
            "stats" -> onMain(result) {
                val host = owner.request?.host == true
                mapOf(
                    "engine" to owner.stats(),
                    "source" to if (host) currentSource()?.stats() else null,
                    "process" to diagnostics.sample(),
                )
            }
            "version" -> onMain(result) {
                mapOf("zego" to owner.sdkVersion(), "sharedContext" to (sharedGl != null))
            }
            else -> result.notImplemented()
        }
    }

    private fun attachCamera(owner: ZegoSession) {
        val engine = ZegoExpressEngine.getEngine()
            ?: throw BridgeException("engine_missing", "Create the ZEGO engine before attaching the Nosmai camera.")
        if (owner.ownsEngine(engine) || owner.active) {
            throw BridgeException("engine_in_use", "The bridge-managed session owns this engine.")
        }
        if (cameraOwner != null) {
            if (cameraOwner === this && attachedSource?.hostEngine === engine) return
            throw BridgeException("camera_in_use", "Detach the previous Nosmai camera first.")
        }
        val source = NosmaiZegoVideoSource(appContext, synchronized(LOCK) { sharedGl }, commands, engine)
        source.configure(30, 1280, "auto", false, true)
        attachedSource = source
        cameraOwner = this
        try {
            engine.setCustomVideoCaptureHandler(source)
            engine.enableCustomVideoCapture(true, ZegoCustomVideoCaptureConfig().apply {
                bufferType = ZegoVideoBufferType.RAW_DATA
            }, ZegoPublishChannel.MAIN)
        } catch (e: Throwable) {
            detachCamera()
            throw e
        }
    }

    private fun detachCamera() {
        if (cameraOwner !== this) return
        val source = attachedSource ?: return
        source.retire()
        val engine = source.hostEngine
        try {
            if (engine != null && ZegoExpressEngine.getEngine() === engine) {
                engine.setCustomVideoCaptureHandler(null)
                engine.enableCustomVideoCapture(false, null, ZegoPublishChannel.MAIN)
            }
        } finally {
            attachedSource = null
            cameraOwner = null
        }
    }

    private fun join(owner: ZegoSession, call: MethodCall): Map<String, Any?> {
        if (cameraOwner != null) throw BridgeException("camera_in_use", "Detach the host camera first.")
        val host = call.flag("host")
        val appId = (call.argument<Number>("appId"))?.toLong()?.takeIf { it > 0 }
            ?: throw BridgeException("invalid_config", "Missing appId.")
        val request = JoinRequest(
            sessionId = call.argument<Number>("sessionId")?.toLong() ?: System.nanoTime(),
            host = host,
            appId = appId,
            appSign = call.argument<String>("appSign").orEmpty(),
            token = call.argument<String>("token").orEmpty(),
            roomId = call.text("roomId"),
            userId = call.text("userId"),
            userName = call.argument<String>("userName")?.takeIf { it.isNotBlank() } ?: call.text("userId"),
            streamId = call.argument<String>("streamId")?.takeIf { it.isNotBlank() },
            hostUserId = call.argument<String>("hostUserId")?.takeIf { it.isNotBlank() },
            publishAudio = call.argument<Boolean>("publishAudio") != false,
            micMuted = call.flag("micMuted"),
            videoMuted = call.flag("videoMuted"),
            speakerMuted = call.flag("speakerMuted"),
            keepScreenOn = call.argument<Boolean>("keepScreenOn") != false,
            fps = (call.argument<Int>("fps") ?: 24).coerceIn(1, 30),
            // Multiple of 8: the GPU converter's frames then match the encode size exactly.
            encodeWidth = ((call.argument<Int>("width") ?: 540).coerceIn(96, 1920) / 8) * 8,
            encodeHeight = ((call.argument<Int>("height") ?: 960).coerceIn(160, 1920) / 4) * 4,
            bitrateKbps = (call.argument<Int>("bitrateKbps") ?: 1200).coerceIn(100, 10_000),
            prioritizeFrameRate = call.argument<Boolean>("prioritizeFrameRate") != false,
        )
        if (request.appSign.isEmpty() && request.token.isEmpty()) {
            throw BridgeException("invalid_config", "Pass the ZEGOCLOUD AppSign or a token.")
        }
        if (!host) {
            owner.join(request, null)
            return mapOf("sharedContext" to false)
        }
        if (request.streamId == null) throw BridgeException("invalid_config", "Missing streamId.")
        if (!granted(Manifest.permission.CAMERA)) {
            throw BridgeException("permission_denied", "Camera access is required to broadcast.")
        }
        val source = sourceOrCreate()
        source.configure(
            fps = request.fps,
            longSide = maxOf(request.encodeWidth, request.encodeHeight),
            transport = call.argument<String>("transport") ?: "auto",
            flip = call.argument<Boolean>("flipVertical") ?: false,
            thermal = call.argument<Boolean>("adaptToThermalState") ?: true,
        )
        source.resetCounters()
        source.onCapturingChanged = { _ -> main.post { owner.onCapturing() } }
        owner.join(request, source)
        return mapOf("sharedContext" to source.sharedContextAvailable)
    }

    /**
     * Must run before NosmaiFlutter.initialize: Nosmai only joins a share group that is
     * registered before its render context exists. Without it, frames flow as Nosmai I420.
     */
    private fun prepare(): Map<String, Any?> {
        val alreadyInitialized = runCatching { NosmaiSDK.isInitialized() }.getOrDefault(false)
        synchronized(LOCK) {
            if (sharedGl == null && !alreadyInitialized) {
                try {
                    val context = SharedGlContext.create()
                    runCatching { System.loadLibrary("nosmai") } // NosmaiSDK usually loads it itself.
                    NosmaiSDK.setAgoraShareContext(context.nativeHandle)
                    sharedGl = context
                } catch (t: Throwable) {
                    Log.w(TAG, "Shared GL context unavailable; Nosmai I420 frames will be used", t)
                }
            }
        }
        return mapOf("sharedContext" to (sharedGl != null), "nosmaiAlreadyInitialized" to alreadyInitialized)
    }

    private fun sourceOrCreate(): NosmaiZegoVideoSource = synchronized(LOCK) {
        source ?: NosmaiZegoVideoSource(appContext, sharedGl, commands).also { source = it }
    }

    private fun setScreenOn(on: Boolean) {
        if (screenOn == on) return
        val window = activity?.activity?.window ?: return
        if (on) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        screenOn = on
    }

    // ---- Permissions ----

    private fun requestPermissions(camera: Boolean, microphone: Boolean, result: MethodChannel.Result) {
        val wanted = buildList {
            if (camera) add(Manifest.permission.CAMERA)
            if (microphone) add(Manifest.permission.RECORD_AUDIO)
            // ZEGO routes audio to Bluetooth headsets when this is granted.
            if (microphone && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        val needed = wanted.filterNot(::granted)
        val host = activity?.activity
        if (needed.isEmpty() || host == null) {
            result.success(permissionState())
            return
        }
        if (pendingPermissions != null) {
            result.error("permission_request_in_progress", "A permission request is already showing.", null)
            return
        }
        pendingPermissions = result
        host.requestPermissions(needed.toTypedArray(), PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        pendingPermissions?.success(permissionState())
        pendingPermissions = null
        return true
    }

    private fun permissionState() = mapOf(
        "camera" to granted(Manifest.permission.CAMERA),
        "microphone" to granted(Manifest.permission.RECORD_AUDIO),
    )

    private fun granted(permission: String) =
        appContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
        if (screenOn) {
            screenOn = false
            setScreenOn(true)
        }
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
        pendingPermissions?.success(permissionState())
        pendingPermissions = null
    }

    // ---- Helpers ----

    private fun onMain(result: MethodChannel.Result, awaitSource: Boolean = false, block: () -> Any?) {
        main.post { deliver(result, "main", awaitSource, block) }
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        commands.execute { deliver(result, "command", false, block) }
    }

    private fun deliver(result: MethodChannel.Result, thread: String, awaitSource: Boolean, block: () -> Any?) {
        try {
            val value = block()
            if (awaitSource) {
                commands.execute { main.post { result.success(value) } }
            } else {
                main.post { result.success(value) }
            }
        } catch (error: BridgeException) {
            main.post { result.error(error.code, error.message, null) }
        } catch (error: Throwable) {
            Log.e(TAG, "Call failed on $thread thread", error)
            main.post { result.error("native_error", error.message ?: error.javaClass.simpleName, null) }
        }
    }

    private fun MethodCall.text(key: String): String =
        argument<String>(key)?.takeIf { it.isNotBlank() }
            ?: throw BridgeException("invalid_config", "Missing $key.")

    private fun MethodCall.flag(key: String): Boolean = argument<Boolean>(key) == true

    /**
     * Shows the broadcaster through ZEGO's own renderer. A TextureView composes in Flutter like
     * any texture; a SurfaceView would need hybrid composition, which left stale Flutter overlay
     * pixels on top of the video in the Zoom bridge.
     */
    private class RemoteVideoViewFactory(
        private val owner: ZegoSession,
    ) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            val view = TextureView(context)
            owner.attachRemoteView(view)
            return object : PlatformView {
                override fun getView(): View = view
                override fun dispose() = owner.detachRemoteView(view)
            }
        }
    }

    companion object {
        private const val TAG = "NosmaiZegoLive"
        private const val CHANNEL = "nosmai_zegocloud_live"
        private const val PERMISSION_REQUEST_CODE = 0x4E5A // "NZ"

        // Process-wide: ZEGO and Nosmai are process singletons, and Nosmai keeps the share group
        // for the life of the process.
        private val LOCK = Any()
        private var sharedGl: SharedGlContext? = null
        private var source: NosmaiZegoVideoSource? = null
        private var zego: ZegoSession? = null
        private var cameraOwner: NosmaiZegoLivePlugin? = null
        private var attachedSource: NosmaiZegoVideoSource? = null
        private val commands: ExecutorService =
            Executors.newSingleThreadExecutor { Thread(it, "nosmai-zego-live") }

        private fun currentSource(): NosmaiZegoVideoSource? = synchronized(LOCK) { source }

        private fun session(context: Context): ZegoSession = synchronized(LOCK) {
            zego ?: ZegoSession(context.applicationContext).also { zego = it }
        }
    }
}
