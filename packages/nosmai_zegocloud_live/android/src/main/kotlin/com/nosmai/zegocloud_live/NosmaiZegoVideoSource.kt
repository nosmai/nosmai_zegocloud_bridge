package com.nosmai.zegocloud_live

import android.content.Context
import android.opengl.GLES20
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import com.nosmai.effect.api.NosmaiSDK
import im.zego.zegoexpress.ZegoExpressEngine
import im.zego.zegoexpress.callback.IZegoCustomVideoCaptureHandler
import im.zego.zegoexpress.constants.ZegoPublishChannel
import im.zego.zegoexpress.constants.ZegoVideoFrameFormat
import im.zego.zegoexpress.entity.ZegoVideoFrameParam
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * ZEGOCLOUD custom video capture source fed by Nosmai's processed camera frames. Nosmai owns the
 * camera; ZEGO never opens it.
 *
 * TEXTURE (default when Nosmai joined [SharedGlContext]'s share group): per Nosmai's consumer
 * protocol (waitStreamFrame -> GPU reads -> completeStreamFrame) the processed texture is scaled
 * and converted to I420 on the GPU by [I420Converter] on the dedicated GL thread, read back once
 * into a pooled direct buffer and handed to ZEGO. Nosmai's render thread never blocks on it.
 *
 * I420 (fallback): Nosmai's frame callback delivers a pooled I420 byte[]; it is copied once into
 * a pooled direct buffer for ZEGO (ZEGO scales it to the encode size itself).
 *
 * Frames are produced only between ZEGO's [onStart] and [onStop] (publishing), and not while
 * [paused] (video muted or app in the background).
 */
internal class NosmaiZegoVideoSource(
    private val appContext: Context,
    private val gl: SharedGlContext?,
    private val control: ExecutorService,
    val hostEngine: ZegoExpressEngine? = null,
) : IZegoCustomVideoCaptureHandler() {

    enum class Transport { TEXTURE, I420 }

    private class TextureUnavailable(message: String) : Exception(message)

    /** Small ring of direct buffers so ZEGO never sees a buffer being refilled. */
    private class BufferRing {
        private val buffers = arrayOfNulls<ByteBuffer>(RING_SIZE)
        private var next = 0
        fun take(bytes: Int): ByteBuffer {
            val index = next
            next = (next + 1) % RING_SIZE
            val existing = buffers[index]
            if (existing != null && existing.capacity() == bytes) return existing
            return ByteBuffer.allocateDirect(bytes).also { buffers[index] = it }
        }
        fun clear() = buffers.fill(null)
    }

    // ---- Configuration (set before publishing) ----
    @Volatile private var maxFps = 30
    @Volatile private var maxLongSide = 960
    @Volatile private var flipVertical = false
    @Volatile private var preferTexture = true
    @Volatile private var adaptToThermalState = true

    // ---- ZEGO state ----
    private val capturing = AtomicBoolean(false)
    private var retired = false
    private val submissionLock = Any()
    private var submissionsClosed = false // Guarded by submissionLock.
    private var outputActive = false // Accessed on the control executor.
    @Volatile private var paused = false

    // ---- Pipeline state ----
    @Volatile private var transport = Transport.I420
    @Volatile private var thermalCapFps = Int.MAX_VALUE
    @Volatile private var lastError = ""
    @Volatile private var lastWidth = 0
    @Volatile private var lastHeight = 0
    private val copyPending = AtomicBoolean(false)
    private var nextDeadlineNs = 0L // Nosmai render/callback thread only.

    // GL thread only.
    private val converter = I420Converter()
    private val textureRing = BufferRing()
    private val textureParam = ZegoVideoFrameParam().apply { format = ZegoVideoFrameFormat.I420 }
    private var textureFailures = 0
    // Nosmai callback thread only.
    private val pixelRing = BufferRing()
    private val pixelParam = ZegoVideoFrameParam().apply { format = ZegoVideoFrameFormat.I420 }

    // ---- Counters (cumulative; rates are derived in [stats]) ----
    private val framesIn = AtomicLong()
    private val sent = AtomicLong()
    private val dropped = AtomicLong()
    private val paced = AtomicLong()
    private val errors = AtomicLong()
    private val convertNsTotal = AtomicLong()
    private val convertNsMax = AtomicLong()
    private val sendNsTotal = AtomicLong()
    private var lastStatsAtMs = 0L
    private var lastStatsSent = 0L
    private var lastStatsIn = 0L
    private var lastStatsConvertNs = 0L
    private var lastStatsSendNs = 0L

    // Nosmai's JNI layer may only keep weak references; hold both callbacks strongly.
    private val textureCallback =
        NosmaiSDK.TextureFrameCallback { texture, width, height, _, _ -> onTexture(texture, width, height) }
    private val frameCallback = NosmaiSDK.FrameCallback { onPixels(it) }
    private val thermalListener: Any? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            PowerManager.OnThermalStatusChangedListener { thermalCapFps = capFor(it) }
        } else null

    val sharedContextAvailable: Boolean
        get() {
            val context = gl ?: return false
            return runCatching { NosmaiSDK.isAgoraShareContext(context.nativeHandle) }.getOrDefault(false)
        }

    fun configure(fps: Int, longSide: Int, transport: String, flip: Boolean, thermal: Boolean) {
        maxFps = fps.coerceIn(1, 60)
        maxLongSide = longSide.coerceIn(320, 1920)
        preferTexture = transport != "i420"
        flipVertical = flip
        adaptToThermalState = thermal
    }

    fun setMaxFps(fps: Int) {
        maxFps = fps.coerceIn(1, 60)
    }

    /** Video muted or app backgrounded: Nosmai frames are returned unconverted. */
    fun setPaused(value: Boolean) {
        paused = value
        if (!value) nextDeadlineNs = 0L
    }

    /** Told whenever ZEGO starts or stops asking for frames. Any thread. */
    @Volatile var onCapturingChanged: ((Boolean) -> Unit)? = null

    val isCapturing: Boolean get() = capturing.get()

    // ---- IZegoCustomVideoCaptureHandler (called by ZEGO) ----

    @Synchronized
    override fun onStart(channel: ZegoPublishChannel?) {
        if (channel != null && channel != ZegoPublishChannel.MAIN) return
        if (retired || !capturing.compareAndSet(false, true)) return
        Log.i(TAG, "ZEGO custom capture started")
        control.execute { startOutput() }
        onCapturingChanged?.invoke(true)
    }

    @Synchronized
    override fun onStop(channel: ZegoPublishChannel?) {
        if (channel != null && channel != ZegoPublishChannel.MAIN) return
        if (!capturing.compareAndSet(true, false)) return
        Log.i(TAG, "ZEGO custom capture stopped")
        control.execute { stopOutput() }
        onCapturingChanged?.invoke(false)
    }

    /** Retire a host attachment permanently before the next one can start. */
    @Synchronized
    fun retire() {
        retired = true
        capturing.set(false)
        control.execute {
            // Drain both GPU and I420 senders before detachment completes.
            synchronized(submissionLock) { submissionsClosed = true }
            stopOutput()
        }
    }

    /** Detaches from Nosmai and drains in-flight frames. Safe to call repeatedly; blocks briefly. */
    fun shutdown() {
        val wasCapturing = capturing.getAndSet(false)
        stopOutput()
        if (wasCapturing) onCapturingChanged?.invoke(false)
    }

    // ---- Output lifecycle (control thread) ----

    private fun startOutput() {
        if (!capturing.get()) return
        nextDeadlineNs = 0L
        outputActive = true
        transport = if (preferTexture && sharedContextAvailable) Transport.TEXTURE else Transport.I420
        lastError = when {
            transport == Transport.TEXTURE -> ""
            preferTexture -> "Shared GPU context unavailable; using Nosmai CPU frames"
            else -> ""
        }
        if (adaptToThermalState) registerThermalListener()
        try {
            NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.DUAL_OUTPUT)
            installCallback(transport)
        } catch (t: Throwable) {
            report("Starting Nosmai output failed: ${describe(t)}")
        }
    }

    private fun stopOutput() {
        if (!outputActive) return
        outputActive = false
        try {
            NosmaiSDK.setTextureFrameCallback(null)
            NosmaiSDK.setFrameCallback(null)
            NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.PREVIEW_ONLY)
        } catch (t: Throwable) {
            Log.w(TAG, "Removing Nosmai callbacks failed", t)
        }
        // Queued conversions observe capturing=false and return their Nosmai slot; then free GPU
        // and CPU buffers so an idle app holds none.
        gl?.runAndWait(DRAIN_TIMEOUT_MS) {
            converter.release()
            textureRing.clear()
        }
        unregisterThermalListener()
    }

    private fun installCallback(selected: Transport) {
        if (selected == Transport.TEXTURE) {
            NosmaiSDK.setFrameCallback(null)
            NosmaiSDK.setTextureFrameCallback(textureCallback)
        } else {
            NosmaiSDK.setTextureFrameCallback(null)
            NosmaiSDK.setFrameCallback(frameCallback)
        }
    }

    // ---- Texture transport ----

    /** Nosmai render thread: never blocks; hands at most one frame to the GL thread. */
    private fun onTexture(texture: Int, width: Int, height: Int) {
        framesIn.incrementAndGet()
        val context = gl
        if (!capturing.get() || paused || transport != Transport.TEXTURE || context == null) {
            NosmaiSDK.releaseStreamSlot(texture)
            return
        }
        if (width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION) {
            dropped.incrementAndGet()
            NosmaiSDK.releaseStreamSlot(texture)
            return
        }
        if (!admitFrame()) {
            paced.incrementAndGet()
            NosmaiSDK.releaseStreamSlot(texture)
            return
        }
        // One conversion in flight: a slow GPU drops frames instead of building latency.
        if (!copyPending.compareAndSet(false, true)) {
            dropped.incrementAndGet()
            NosmaiSDK.releaseStreamSlot(texture)
            return
        }
        if (!context.post { convertAndSend(texture, width, height) }) {
            copyPending.set(false)
            dropped.incrementAndGet()
            NosmaiSDK.releaseStreamSlot(texture)
        }
    }

    /** GL thread. */
    private fun convertAndSend(texture: Int, srcW: Int, srcH: Int) {
        var returned = false
        try {
            if (!capturing.get()) return
            // ZEGO keeps portrait frames as they are (no centre crop), so they go out upright,
            // scaled on the GPU to the configured size: no rotation flag needed.
            val (width, height) = I420Converter.alignedSize(srcW, srcH, maxLongSide)
            val buffer = textureRing.take(I420Converter.frameBytes(width, height))
            if (!NosmaiSDK.waitStreamFrame(texture)) {
                dropped.incrementAndGet()
                return
            }
            val started = SystemClock.elapsedRealtimeNanos()
            try {
                if (!GLES20.glIsTexture(texture)) {
                    throw TextureUnavailable("Nosmai texture is not visible in the shared GL context")
                }
                converter.render(texture, width, height, flipVertical, false)
            } finally {
                // Records Nosmai's fence after our draw; Nosmai may reuse the texture after it.
                NosmaiSDK.completeStreamFrame(texture)
                returned = true
            }
            converter.readInto(buffer)
            recordConvert(SystemClock.elapsedRealtimeNanos() - started)
            if (!capturing.get()) return
            send(buffer, width, height, textureParam)
            textureFailures = 0
        } catch (error: TextureUnavailable) {
            dropped.incrementAndGet()
            onTextureFailure(error.message ?: "Texture unavailable")
        } catch (error: Throwable) {
            dropped.incrementAndGet()
            onTextureFailure("Texture frame failed: ${describe(error)}")
        } finally {
            if (!returned) NosmaiSDK.releaseStreamSlot(texture)
            copyPending.set(false)
        }
    }

    private fun onTextureFailure(message: String) {
        report(message)
        if (++textureFailures < TEXTURE_FAILURES_BEFORE_FALLBACK) return
        Log.w(TAG, "$message; switching to Nosmai I420 frames")
        lastError = "$message; switched to CPU frames"
        transport = Transport.I420
        if (capturing.get()) control.execute { if (capturing.get()) installCallback(Transport.I420) }
    }

    // ---- I420 transport ----

    /** Nosmai callback thread. The byte[] is pooled by Nosmai, so it is copied before returning. */
    private fun onPixels(frame: NosmaiSDK.FrameData?) {
        framesIn.incrementAndGet()
        if (frame == null || !capturing.get() || paused || transport != Transport.I420) return
        val data = frame.pixelBuffer
        val width = frame.width
        val height = frame.height
        if (data == null || width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION) {
            dropped.incrementAndGet()
            return
        }
        if (frame.format != NOSMAI_FORMAT_I420) {
            dropped.incrementAndGet()
            report("Unsupported Nosmai frame format ${frame.format}")
            return
        }
        if (width % 2 != 0 || height % 2 != 0) {
            dropped.incrementAndGet()
            report("Odd-sized Nosmai frame ${width}x$height is not supported")
            return
        }
        val bytes = I420Converter.frameBytes(width, height)
        if (data.size < bytes) {
            dropped.incrementAndGet()
            return
        }
        if (!admitFrame()) {
            paced.incrementAndGet()
            return
        }
        try {
            val started = SystemClock.elapsedRealtimeNanos()
            val buffer = pixelRing.take(bytes)
            buffer.clear()
            buffer.put(data, 0, bytes)
            buffer.flip()
            recordConvert(SystemClock.elapsedRealtimeNanos() - started)
            send(buffer, width, height, pixelParam)
        } catch (error: Throwable) {
            dropped.incrementAndGet()
            report("I420 frame failed: ${describe(error)}")
        }
    }

    // ---- Shared helpers ----

    private fun send(buffer: ByteBuffer, width: Int, height: Int, param: ZegoVideoFrameParam) {
        val engine = ZegoExpressEngine.getEngine() ?: run { dropped.incrementAndGet(); return }
        if (hostEngine != null && engine !== hostEngine) return
        param.width = width
        param.height = height
        param.strides[0] = width
        param.strides[1] = width / 2
        param.strides[2] = width / 2
        param.rotation = 0
        val started = SystemClock.elapsedRealtimeNanos()
        synchronized(submissionLock) {
            if (submissionsClosed || !capturing.get()) return
            engine.sendCustomVideoCaptureRawData(buffer, buffer.limit(), param, SystemClock.elapsedRealtime())
        }
        sendNsTotal.addAndGet(SystemClock.elapsedRealtimeNanos() - started)
        sent.incrementAndGet()
        lastWidth = width
        lastHeight = height
    }

    private fun recordConvert(ns: Long) {
        convertNsTotal.addAndGet(ns)
        while (true) {
            val max = convertNsMax.get()
            if (ns <= max || convertNsMax.compareAndSet(max, ns)) return
        }
    }

    /**
     * Even spacing at the target rate; encoders want a steady cadence. A frame may arrive up to
     * a quarter interval early, so camera jitter at the target rate itself drops nothing.
     */
    private fun admitFrame(): Boolean {
        val fps = effectiveFps()
        // The camera runs at 30: pacing at its own rate would only drop frames that arrive with
        // a little jitter, so at NO_PACING_FPS or more every frame passes.
        if (fps >= NO_PACING_FPS) return true
        val now = SystemClock.elapsedRealtimeNanos()
        val interval = 1_000_000_000L / fps
        val deadline = nextDeadlineNs
        if (deadline != 0L && now + interval / 4 < deadline) return false
        nextDeadlineNs = if (deadline == 0L || now - deadline > RESYNC_AFTER_NS) now + interval else deadline + interval
        return true
    }

    private fun effectiveFps(): Int = minOf(maxFps, thermalCapFps).coerceAtLeast(1)

    /** Called about once per second from the stats poll (main thread). */
    fun stats(): Map<String, Any?> {
        val now = SystemClock.elapsedRealtime()
        val sentNow = sent.get()
        val inNow = framesIn.get()
        val convertNs = convertNsTotal.get()
        val sendNs = sendNsTotal.get()
        val elapsedMs = if (lastStatsAtMs == 0L) 0L else now - lastStatsAtMs
        val sentDelta = sentNow - lastStatsSent
        fun perSecond(delta: Long) = if (elapsedMs > 0) delta * 1000.0 / elapsedMs else 0.0
        fun avgMs(totalDelta: Long) = if (sentDelta > 0) totalDelta / sentDelta / 1_000_000.0 else 0.0
        val result = mapOf(
            "capturing" to capturing.get(),
            "paused" to paused,
            "transport" to transport.name.lowercase(),
            "sharedContext" to sharedContextAvailable,
            "framesIn" to inNow,
            "sent" to sentNow,
            "dropped" to dropped.get(),
            "paced" to paced.get(),
            "errors" to errors.get(),
            "inputFps" to perSecond(inNow - lastStatsIn),
            "txFps" to perSecond(sentDelta),
            "convertMsAvg" to avgMs(convertNs - lastStatsConvertNs),
            "convertMsMax" to convertNsMax.getAndSet(0) / 1_000_000.0,
            "sendMsAvg" to avgMs(sendNs - lastStatsSendNs),
            "width" to lastWidth,
            "height" to lastHeight,
            "targetFps" to effectiveFps(),
            "lastError" to lastError,
        )
        lastStatsAtMs = now
        lastStatsSent = sentNow
        lastStatsIn = inNow
        lastStatsConvertNs = convertNs
        lastStatsSendNs = sendNs
        return result
    }

    fun resetCounters() {
        for (counter in listOf(framesIn, sent, dropped, paced, errors, convertNsTotal, convertNsMax, sendNsTotal)) {
            counter.set(0)
        }
        lastStatsAtMs = 0L; lastStatsSent = 0L; lastStatsIn = 0L; lastStatsConvertNs = 0L; lastStatsSendNs = 0L
        lastWidth = 0; lastHeight = 0; lastError = ""; paused = false
    }

    private fun registerThermalListener() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val power = appContext.getSystemService(PowerManager::class.java) ?: return
        try {
            thermalCapFps = capFor(power.currentThermalStatus)
            power.addThermalStatusListener(thermalListener as PowerManager.OnThermalStatusChangedListener)
        } catch (t: Throwable) {
            Log.w(TAG, "Thermal status unavailable", t)
        }
    }

    private fun unregisterThermalListener() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching {
                appContext.getSystemService(PowerManager::class.java)
                    ?.removeThermalStatusListener(thermalListener as PowerManager.OnThermalStatusChangedListener)
            }
        }
        thermalCapFps = Int.MAX_VALUE
    }

    private fun report(message: String) {
        lastError = message
        if (errors.incrementAndGet() <= 5) Log.e(TAG, message)
    }

    companion object {
        private const val TAG = "NosmaiZegoSource"
        private const val RING_SIZE = 3
        private const val MAX_DIMENSION = 4096
        private const val NOSMAI_FORMAT_I420 = 1
        private const val TEXTURE_FAILURES_BEFORE_FALLBACK = 3
        private const val DRAIN_TIMEOUT_MS = 2_000L
        private const val RESYNC_AFTER_NS = 200_000_000L
        private const val NO_PACING_FPS = 30

        private fun capFor(status: Int): Int = when {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q -> Int.MAX_VALUE
            status >= PowerManager.THERMAL_STATUS_CRITICAL -> 10
            status >= PowerManager.THERMAL_STATUS_SEVERE -> 15
            else -> Int.MAX_VALUE
        }

        private fun describe(error: Throwable) = error.message ?: error.javaClass.simpleName
    }
}
