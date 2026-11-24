package com.nosmai.zegocloud_live

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.os.Handler
import android.os.HandlerThread
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * A process-lifetime OpenGL ES 3 context on its own thread.
 *
 * Its native handle is registered with Nosmai (setAgoraShareContext) before Nosmai initializes,
 * so Nosmai's render context joins this share group and its processed textures can be sampled
 * here. It is never destroyed: Nosmai keeps the share group for the life of the process.
 */
internal class SharedGlContext private constructor(
    private val handler: Handler,
    val context: EGLContext,
    @Suppress("unused") private val surface: EGLSurface, // Keeps the pbuffer alive.
) {
    val nativeHandle: Long get() = context.nativeHandle

    fun post(task: Runnable): Boolean = handler.post(task)

    /** Runs [task] on the GL thread and waits up to [timeoutMs]. */
    fun runAndWait(timeoutMs: Long, task: () -> Unit): Boolean {
        val done = CountDownLatch(1)
        if (!handler.post { try { task() } finally { done.countDown() } }) return false
        return try {
            done.await(timeoutMs, TimeUnit.MILLISECONDS)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
    }

    companion object {
        fun create(): SharedGlContext {
            val thread = HandlerThread("nosmai-zego-gl").apply { start() }
            val handler = Handler(thread.looper)
            val created = AtomicReference<SharedGlContext>()
            val failure = AtomicReference<Throwable>()
            val ready = CountDownLatch(1)
            handler.post {
                try {
                    created.set(makeCurrent(handler))
                } catch (t: Throwable) {
                    failure.set(t)
                } finally {
                    ready.countDown()
                }
            }
            if (!ready.await(5, TimeUnit.SECONDS)) {
                thread.quitSafely()
                throw IllegalStateException("Timed out creating the streaming GL context")
            }
            failure.get()?.let {
                thread.quitSafely()
                throw IllegalStateException("Could not create the streaming GL context", it)
            }
            return created.get()
        }

        // ES 3 only: the I420 shader uses ESSL 3.00, sampler objects and fence syncs.
        private fun makeCurrent(handler: Handler): SharedGlContext {
            val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            check(display != EGL14.EGL_NO_DISPLAY) { "No EGL display" }
            val version = IntArray(2)
            check(EGL14.eglInitialize(display, version, 0, version, 1)) { "eglInitialize failed" }
            val config = chooseConfig(display) ?: error("No OpenGL ES 3 EGL config")
            val context = EGL14.eglCreateContext(
                display, config, EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0,
            )
            check(context != null && context != EGL14.EGL_NO_CONTEXT) {
                "eglCreateContext failed: 0x" + Integer.toHexString(EGL14.eglGetError())
            }
            val surface = EGL14.eglCreatePbufferSurface(
                display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0,
            )
            if (surface == null || surface == EGL14.EGL_NO_SURFACE) {
                EGL14.eglDestroyContext(display, context)
                error("eglCreatePbufferSurface failed")
            }
            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) {
                EGL14.eglDestroySurface(display, surface)
                EGL14.eglDestroyContext(display, context)
                error("eglMakeCurrent failed")
            }
            return SharedGlContext(handler, context, surface)
        }

        private fun chooseConfig(display: EGLDisplay): EGLConfig? {
            val attributes = intArrayOf(
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_NONE,
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            val count = IntArray(1)
            if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0)) return null
            return if (count[0] > 0) configs[0] else null
        }
    }
}
