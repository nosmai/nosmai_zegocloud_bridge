package com.nosmai.zegocloud_live

import android.os.Debug
import android.os.Process
import android.os.SystemClock
import java.io.File

/** Real process CPU and memory figures, sampled on demand (about once per second). */
internal class ProcessDiagnostics {
    private val cores = Runtime.getRuntime().availableProcessors()
    private var lastCpuMs = Process.getElapsedCpuTime()
    private var lastWallMs = SystemClock.elapsedRealtime()

    fun sample(): Map<String, Any?> {
        val cpuMs = Process.getElapsedCpuTime()
        val wallMs = SystemClock.elapsedRealtime()
        val wallDelta = wallMs - lastWallMs
        // Percent of one core, as `top` reports it; divide by cores for device share.
        val cpuPercent = if (wallDelta > 0) (cpuMs - lastCpuMs) * 100.0 / wallDelta else 0.0
        lastCpuMs = cpuMs
        lastWallMs = wallMs
        val runtime = Runtime.getRuntime()
        return mapOf(
            "cpuPercent" to cpuPercent,
            "cpuCores" to cores,
            "rssMb" to rssKb() / 1024.0,
            "javaHeapMb" to (runtime.totalMemory() - runtime.freeMemory()) / 1048576.0,
            "nativeHeapMb" to Debug.getNativeHeapAllocatedSize() / 1048576.0,
        )
    }

    private fun rssKb(): Long = try {
        File("/proc/self/status").useLines { lines ->
            lines.firstOrNull { it.startsWith("VmRSS:") }
                ?.split(Regex("\\s+"))?.getOrNull(1)?.toLongOrNull() ?: 0L
        }
    } catch (_: Exception) {
        0L
    }
}
