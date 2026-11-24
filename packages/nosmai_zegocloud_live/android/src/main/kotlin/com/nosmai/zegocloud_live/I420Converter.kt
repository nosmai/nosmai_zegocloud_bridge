package com.nosmai.zegocloud_live

import android.opengl.GLES20
import android.opengl.GLES30
import java.nio.ByteBuffer

/**
 * GPU RGBA -> I420 (BT.601 limited range) conversion. GL thread only.
 *
 * One draw renders the whole I420 frame into an RGBA8 target of (width/4) x (height*3/2) pixels:
 * every output pixel packs four consecutive bytes of the Y, U or V plane, so one glReadPixels
 * writes a tightly packed I420 frame straight into the caller's direct buffer. The source is
 * sampled bilinearly, so scaling to the output size and 2x2 chroma averaging come for free.
 *
 * Requirements: width % 8 == 0 and height % 4 == 0 (see [alignedSize]).
 */
internal class I420Converter {
    private var program = 0
    private var framebuffer = 0
    private var target = 0
    private var sampler = 0
    private var targetWidth = 0
    private var targetHeight = 0
    private var uSize = -1
    private var uFlip = -1
    private var uRotate = -1

    /**
     * Issues the conversion draw of [source] (a GL_TEXTURE_2D) into a [width] x [height] I420
     * layout. With [rotateCcw] the source is turned 90° counter-clockwise first, so a portrait
     * source fills a landscape output (its top becomes the output's left edge). After this
     * returns the source may be handed back to its producer: later GPU work (e.g. a producer
     * fence) is ordered after the draw.
     */
    fun render(source: Int, width: Int, height: Int, flipVertical: Boolean, rotateCcw: Boolean = false) {
        require(width % 8 == 0 && height % 4 == 0) { "I420 output must be 8x4 aligned" }
        ensureProgram()
        ensureTarget(width, height)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
        GLES20.glViewport(0, 0, width / 4, height * 3 / 2)
        GLES20.glDisable(GLES20.GL_BLEND)
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glDisable(GLES20.GL_SCISSOR_TEST)
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, source)
        // A sampler object overrides filtering/wrap without touching Nosmai's texture state.
        GLES30.glBindSampler(0, sampler)
        GLES20.glUniform2f(uSize, width.toFloat(), height.toFloat())
        GLES20.glUniform1f(uFlip, if (flipVertical) 1f else 0f)
        GLES20.glUniform1f(uRotate, if (rotateCcw) 1f else 0f)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLES, 0, 3)
        GLES30.glBindSampler(0, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
    }

    /** Reads the last [render] result (tightly packed I420) into the direct buffer [out]. */
    fun readInto(out: ByteBuffer) {
        val bytes = frameBytes(targetWidth, targetHeight)
        require(out.isDirect && out.capacity() >= bytes) { "Output buffer too small" }
        out.clear()
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
        GLES20.glPixelStorei(GLES20.GL_PACK_ALIGNMENT, 4)
        GLES20.glReadPixels(
            0, 0, targetWidth / 4, targetHeight * 3 / 2, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, out,
        )
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        val error = GLES20.glGetError()
        check(error == GLES20.GL_NO_ERROR) { "GL error 0x" + Integer.toHexString(error) }
        out.position(0)
        out.limit(bytes)
    }

    fun release() {
        if (program != 0) GLES20.glDeleteProgram(program)
        if (framebuffer != 0) GLES20.glDeleteFramebuffers(1, intArrayOf(framebuffer), 0)
        if (target != 0) GLES20.glDeleteTextures(1, intArrayOf(target), 0)
        if (sampler != 0) GLES30.glDeleteSamplers(1, intArrayOf(sampler), 0)
        program = 0; framebuffer = 0; target = 0; sampler = 0; targetWidth = 0; targetHeight = 0
    }

    private fun ensureTarget(width: Int, height: Int) {
        if (target != 0 && width == targetWidth && height == targetHeight) return
        if (target == 0) {
            val ids = IntArray(1)
            GLES20.glGenTextures(1, ids, 0)
            target = ids[0]
            GLES20.glGenFramebuffers(1, ids, 0)
            framebuffer = ids[0]
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, target)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST)
        GLES20.glTexImage2D(
            GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width / 4, height * 3 / 2, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null,
        )
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
        GLES20.glFramebufferTexture2D(
            GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, target, 0,
        )
        val status = GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        check(status == GLES20.GL_FRAMEBUFFER_COMPLETE) {
            "I420 target incomplete: 0x" + Integer.toHexString(status)
        }
        targetWidth = width
        targetHeight = height
    }

    private fun ensureProgram() {
        if (program != 0) return
        val vertex = compile(GLES20.GL_VERTEX_SHADER, VERTEX)
        val fragment = compile(GLES20.GL_FRAGMENT_SHADER, FRAGMENT)
        val linked = GLES20.glCreateProgram()
        GLES20.glAttachShader(linked, vertex)
        GLES20.glAttachShader(linked, fragment)
        GLES20.glLinkProgram(linked)
        GLES20.glDeleteShader(vertex)
        GLES20.glDeleteShader(fragment)
        val status = IntArray(1)
        GLES20.glGetProgramiv(linked, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(linked)
            GLES20.glDeleteProgram(linked)
            error("I420 program link failed: $log")
        }
        program = linked
        uSize = GLES20.glGetUniformLocation(program, "uSize")
        uFlip = GLES20.glGetUniformLocation(program, "uFlip")
        uRotate = GLES20.glGetUniformLocation(program, "uRotate")
        GLES20.glUseProgram(program)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "uTex"), 0)
        val ids = IntArray(1)
        GLES30.glGenSamplers(1, ids, 0)
        sampler = ids[0]
        GLES30.glSamplerParameteri(sampler, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES30.glSamplerParameteri(sampler, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES30.glSamplerParameteri(sampler, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES30.glSamplerParameteri(sampler, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
    }

    private fun compile(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            error("I420 shader compile failed: $log")
        }
        return shader
    }

    companion object {
        fun frameBytes(width: Int, height: Int): Int = width * height * 3 / 2

        /**
         * Output size for a [srcW] x [srcH] source whose long side is capped at [maxLongSide]:
         * keeps the aspect ratio, never upscales, and rounds down to the 8x4 alignment.
         */
        fun alignedSize(srcW: Int, srcH: Int, maxLongSide: Int): Pair<Int, Int> {
            val scale = minOf(1.0, maxLongSide.toDouble() / maxOf(srcW, srcH))
            val w = ((srcW * scale).toInt() / 8) * 8
            val h = ((srcH * scale).toInt() / 4) * 4
            return Pair(maxOf(8, w), maxOf(4, h))
        }

        // Full-screen triangle from gl_VertexID; no vertex buffers needed in ES 3.
        private const val VERTEX = """#version 300 es
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}"""

        // Output row r (glReadPixels row r) is I420 byte row r. Rows [0,H) hold Y, each pixel
        // 4 luma samples. Rows [H, H+H/4) hold U and [H+H/4, 3H/2) hold V: each output row of
        // W bytes carries two chroma rows of W/2 samples.
        private const val FRAGMENT = """#version 300 es
precision highp float;
uniform sampler2D uTex;
uniform vec2 uSize;
uniform float uFlip;
uniform float uRotate;
out vec4 outColor;

// px is in output pixels, rows top-down. Source coordinates are top-down too until the flip.
vec3 rgbAt(vec2 px) {
    vec2 o = px / uSize;
    vec2 uv = mix(o, vec2(1.0 - o.y, o.x), uRotate);
    uv.y = mix(uv.y, 1.0 - uv.y, uFlip);
    return texture(uTex, uv).rgb;
}
float lumaOf(vec3 c) { return dot(c, vec3(0.2568, 0.5041, 0.0979)) + 0.0627; }
float uOf(vec3 c) { return dot(c, vec3(-0.1482, -0.2910, 0.4392)) + 0.5020; }
float vOf(vec3 c) { return dot(c, vec3(0.4392, -0.3678, -0.0714)) + 0.5020; }

void main() {
    vec2 cell = floor(gl_FragCoord.xy);
    float x0 = cell.x * 4.0;
    float height = uSize.y;
    vec4 result;
    if (cell.y < height) {
        float y = cell.y + 0.5;
        result = vec4(lumaOf(rgbAt(vec2(x0 + 0.5, y))), lumaOf(rgbAt(vec2(x0 + 1.5, y))),
                      lumaOf(rgbAt(vec2(x0 + 2.5, y))), lumaOf(rgbAt(vec2(x0 + 3.5, y))));
    } else {
        float chromaWidth = uSize.x * 0.5;
        float quarter = height * 0.25;
        float r = cell.y - height;
        bool isV = r >= quarter;
        if (isV) r -= quarter;
        float second = x0 >= chromaWidth ? 1.0 : 0.0;
        float cy = r * 2.0 + second;
        float cx = x0 - second * chromaWidth;
        // Sampling at the shared corner of each 2x2 luma block averages it bilinearly.
        float sy = 2.0 * cy + 1.0;
        vec3 c0 = rgbAt(vec2(2.0 * cx + 1.0, sy));
        vec3 c1 = rgbAt(vec2(2.0 * cx + 3.0, sy));
        vec3 c2 = rgbAt(vec2(2.0 * cx + 5.0, sy));
        vec3 c3 = rgbAt(vec2(2.0 * cx + 7.0, sy));
        result = isV ? vec4(vOf(c0), vOf(c1), vOf(c2), vOf(c3))
                     : vec4(uOf(c0), uOf(c1), uOf(c2), uOf(c3));
    }
    outColor = result;
}"""
    }
}
