package com.nosmai.zegocloud_live

import android.app.Application
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.TextureView
import im.zego.zegoexpress.ZegoExpressEngine
import im.zego.zegoexpress.ZegoExpressErrorCode
import im.zego.zegoexpress.callback.IZegoEventHandler
import im.zego.zegoexpress.constants.ZegoPlayerState
import im.zego.zegoexpress.constants.ZegoPublishChannel
import im.zego.zegoexpress.constants.ZegoPublisherState
import im.zego.zegoexpress.constants.ZegoRemoteDeviceState
import im.zego.zegoexpress.constants.ZegoRoomStateChangedReason
import im.zego.zegoexpress.constants.ZegoScenario
import im.zego.zegoexpress.constants.ZegoStreamQualityLevel
import im.zego.zegoexpress.constants.ZegoTrafficControlProperty
import im.zego.zegoexpress.constants.ZegoUpdateType
import im.zego.zegoexpress.constants.ZegoVideoBufferType
import im.zego.zegoexpress.constants.ZegoVideoMirrorMode
import im.zego.zegoexpress.constants.ZegoViewMode
import im.zego.zegoexpress.entity.ZegoCanvas
import im.zego.zegoexpress.entity.ZegoCustomVideoCaptureConfig
import im.zego.zegoexpress.entity.ZegoEngineProfile
import im.zego.zegoexpress.entity.ZegoPlayStreamQuality
import im.zego.zegoexpress.entity.ZegoPublishStreamQuality
import im.zego.zegoexpress.entity.ZegoRoomConfig
import im.zego.zegoexpress.entity.ZegoStream
import im.zego.zegoexpress.entity.ZegoUser
import im.zego.zegoexpress.entity.ZegoVideoConfig
import org.json.JSONObject

/** What Dart asked for when joining. */
internal class JoinRequest(
    /** Chosen by Dart; tags every event so a late event never reaches a newer session. */
    val sessionId: Long,
    val host: Boolean,
    val appId: Long,
    val appSign: String,
    val token: String,
    val roomId: String,
    val userId: String,
    val userName: String,
    /** Broadcaster: the stream to publish. Viewer: the stream to watch, or null for any. */
    val streamId: String?,
    val hostUserId: String?,
    val publishAudio: Boolean,
    val micMuted: Boolean,
    val videoMuted: Boolean,
    val speakerMuted: Boolean,
    val keepScreenOn: Boolean,
    val fps: Int = 24,
    val encodeWidth: Int = 540,
    val encodeHeight: Int = 960,
    val bitrateKbps: Int = 1200,
    val prioritizeFrameRate: Boolean = true,
)

/**
 * The process-wide ZEGO Express room: one broadcaster (publishes [NosmaiZegoVideoSource] through
 * custom video capture) or one viewer (plays the broadcaster's stream into a [TextureView]).
 *
 * Main thread only: ZEGO delivers its callbacks there. Outcomes reach Dart through [emit], each
 * tagged with `session` (the [JoinRequest.sessionId] it belongs to):
 * `joined`, `reconnecting`, `reconnected`, `left {reason}`, `error {code, message, fatal}`,
 * `warning {message}`, `remoteVideo {userId, userName, streamId, on}` and `sending {on}`.
 */
internal class ZegoSession(private val appContext: Context) {
    var emit: (Map<String, Any?>) -> Unit = {}

    private val main = Handler(Looper.getMainLooper())
    private var engine: ZegoExpressEngine? = null
    private var engineKey: Pair<Long, String>? = null

    var request: JoinRequest? = null
        private set
    private var source: NosmaiZegoVideoSource? = null
    private var loggedIn = false
    private var joinedAtMs = 0L
    private var foreground = true
    private var micMuted = false
    private var videoMuted = false
    private var speakerMuted = false

    // Broadcaster.
    private var publisherState = ZegoPublisherState.NO_PUBLISH
    private var capturing = false
    private var reportedSending: Boolean? = null
    private var publishQuality: ZegoPublishStreamQuality? = null

    // Viewer.
    private val roomStreams = LinkedHashMap<String, ZegoStream>()
    /** Streams that failed to play (e.g. left behind by a crashed broadcaster) until they show video. */
    private val failedStreams = HashSet<String>()
    private var playing: ZegoStream? = null
    private var playerState = ZegoPlayerState.NO_PLAY
    private var firstFrameShown = false
    private var remoteCameraOn = true
    private var remoteView: TextureView? = null
    private var playQuality: ZegoPlayStreamQuality? = null
    private var playSize = Pair(0, 0)
    private var reportedRemote: List<Any?>? = null

    // Both.
    private val others = HashSet<String>()
    private var onlineCount = 0
    private var leaving: Runnable? = null

    private val handler = object : IZegoEventHandler() {
        override fun onRoomStateChanged(roomID: String?, reason: ZegoRoomStateChangedReason?, errorCode: Int, extendedData: JSONObject?) =
            guard("onRoomStateChanged") { onRoomState(roomID, reason, errorCode) }

        override fun onRoomUserUpdate(roomID: String?, updateType: ZegoUpdateType?, userList: ArrayList<ZegoUser>?) =
            guard("onRoomUserUpdate") {
                if (!isMyRoom(roomID)) return@guard
                val ids = userList.orEmpty().mapNotNull { it.userID }.filter { it != request?.userId }
                if (updateType == ZegoUpdateType.ADD) others.addAll(ids) else others.removeAll(ids.toSet())
            }

        override fun onRoomOnlineUserCountUpdate(roomID: String?, count: Int) =
            guard("onRoomOnlineUserCountUpdate") { if (isMyRoom(roomID)) onlineCount = count }

        override fun onRoomStreamUpdate(roomID: String?, updateType: ZegoUpdateType?, streamList: ArrayList<ZegoStream>?, extendedData: JSONObject?) =
            guard("onRoomStreamUpdate") {
                if (!isMyRoom(roomID)) return@guard
                for (stream in streamList.orEmpty()) {
                    val id = stream.streamID ?: continue
                    if (updateType != ZegoUpdateType.ADD && endedLive(stream)) return@guard
                    // Re-insert so the map stays in arrival order (newest last).
                    roomStreams.remove(id)
                    failedStreams.remove(id)
                    if (updateType == ZegoUpdateType.ADD) roomStreams[id] = stream
                }
                refreshPlayback()
            }

        override fun onRoomStreamExtraInfoUpdate(roomID: String?, streamList: ArrayList<ZegoStream>?) =
            guard("onRoomStreamExtraInfoUpdate") {
                if (!isMyRoom(roomID)) return@guard
                for (stream in streamList.orEmpty()) {
                    if (endedLive(stream)) return@guard
                    stream.streamID?.let { id -> roomStreams[id]?.extraInfo = stream.extraInfo }
                }
            }

        override fun onRoomTokenWillExpire(roomID: String?, remainTimeInSecond: Int) =
            guard("onRoomTokenWillExpire") {
                if (isMyRoom(roomID)) send(mapOf("type" to "tokenWillExpire", "seconds" to remainTimeInSecond))
            }

        override fun onPublisherStateUpdate(streamID: String?, state: ZegoPublisherState?, errorCode: Int, extendedData: JSONObject?) =
            guard("onPublisherStateUpdate") { onPublisherState(streamID, state ?: ZegoPublisherState.NO_PUBLISH, errorCode) }

        override fun onPublisherQualityUpdate(streamID: String?, quality: ZegoPublishStreamQuality?) =
            guard("onPublisherQualityUpdate") { if (request?.host == true) publishQuality = quality }

        override fun onPlayerStateUpdate(streamID: String?, state: ZegoPlayerState?, errorCode: Int, extendedData: JSONObject?) =
            guard("onPlayerStateUpdate") { onPlayerState(streamID, state ?: ZegoPlayerState.NO_PLAY, errorCode) }

        override fun onPlayerQualityUpdate(streamID: String?, quality: ZegoPlayStreamQuality?) =
            guard("onPlayerQualityUpdate") { if (streamID == playing?.streamID) playQuality = quality }

        override fun onPlayerRenderVideoFirstFrame(streamID: String?) =
            guard("onPlayerRenderVideoFirstFrame") {
                if (streamID != playing?.streamID) return@guard
                firstFrameShown = true
                failedStreams.remove(streamID)
                reportRemote()
            }

        override fun onPlayerVideoSizeChanged(streamID: String?, width: Int, height: Int) =
            guard("onPlayerVideoSizeChanged") { if (streamID == playing?.streamID) playSize = Pair(width, height) }

        override fun onRemoteCameraStateUpdate(streamID: String?, state: ZegoRemoteDeviceState?) =
            guard("onRemoteCameraStateUpdate") {
                if (streamID != playing?.streamID) return@guard
                remoteCameraOn = state == ZegoRemoteDeviceState.OPEN
                reportRemote()
            }

        override fun onIMRecvCustomCommand(roomID: String?, fromUser: ZegoUser?, command: String?) =
            guard("onIMRecvCustomCommand") {
                val current = request ?: return@guard
                if (current.host || !isMyRoom(roomID) || command != END_MARK) return@guard
                // Only the broadcaster being watched may end the live for this viewer.
                val from = fromUser?.userID
                if (from != null && playing != null && playing?.user?.userID != from) return@guard
                finishLeave(reason = "EndByHost")
            }

        override fun onDebugError(errorCode: Int, funcName: String?, info: String?) {
            Log.w(TAG, "ZEGO $funcName: $errorCode $info")
        }
    }

    val active: Boolean get() = request != null

    fun ownsEngine(candidate: ZegoExpressEngine) = engine === candidate

    fun sdkVersion(): String = runCatching { ZegoExpressEngine.getVersion() }.getOrDefault("")

    /** Creates the engine for [appId]/[appSign], replacing one made for other credentials. */
    private fun ensureEngine(appId: Long, appSign: String): ZegoExpressEngine {
        val key = Pair(appId, appSign)
        val current = ZegoExpressEngine.getEngine()
        if (current != null && current !== engine) {
            throw BridgeException("engine_in_use", "Use attachCamera with your existing ZEGO engine.")
        }
        if (current != null && engineKey == key) return current
        releaseEngine()
        val profile = ZegoEngineProfile().apply {
            this.appID = appId
            this.appSign = appSign
            scenario = ZegoScenario.BROADCAST
            application = appContext.applicationContext as Application
        }
        val created = ZegoExpressEngine.createEngine(profile, handler)
            ?: throw BridgeException("start_failed", "ZEGOCLOUD engine could not be created.")
        engine = created
        engineKey = key
        return created
    }

    private fun releaseEngine() {
        if (engine == null || request != null) return
        Log.i(TAG, "Releasing the idle ZEGO engine")
        if (ZegoExpressEngine.getEngine() === engine) {
            runCatching { ZegoExpressEngine.destroyEngine(null) }.onFailure { Log.w(TAG, "destroyEngine failed", it) }
        }
        engine = null
        engineKey = null
    }

    /** Releases the engine now, e.g. when Flutter detaches. */
    fun releaseNow() {
        if (request == null) releaseEngine()
    }

    /** Swaps the room token before it expires (token authentication). */
    fun renewToken(sessionId: Long?, token: String) {
        val current = request ?: throw BridgeException("not_active", "No ZEGOCLOUD session is active.")
        if (sessionId != null && current.sessionId != sessionId) {
            throw BridgeException("not_active", "This session has ended.")
        }
        val zego = engine ?: throw BridgeException("not_active", "No ZEGOCLOUD session is active.")
        zego.renewToken(current.roomId, token)
    }

    /**
     * Logs in to the room asynchronously; success arrives as the `joined` event. A broadcaster
     * passes [videoSource] so ZEGO publishes Nosmai's frames instead of opening a camera.
     */
    fun join(join: JoinRequest, videoSource: NosmaiZegoVideoSource?) {
        // Dart allows one active session at a time, so one still here was abandoned (its Dart side
        // is gone). The newest caller wins: end the old one and tell its listeners.
        request?.let { stale ->
            Log.w(TAG, "Replacing abandoned session ${stale.sessionId} with ${join.sessionId}")
            finishLeave("Replaced")
        }
        val zego = ensureEngine(join.appId, join.appSign)
        resetState()
        request = join
        source = if (join.host) videoSource else null
        micMuted = join.micMuted
        videoMuted = join.videoMuted
        speakerMuted = join.speakerMuted

        if (join.host) {
            configurePublisher(zego, join, videoSource ?: throw BridgeException("start_failed", "No video source."))
        } else {
            zego.muteSpeaker(join.speakerMuted)
        }

        val user = ZegoUser(join.userId, join.userName)
        val config = ZegoRoomConfig().apply {
            isUserStatusNotify = true
            token = join.token
        }
        zego.loginRoom(join.roomId, user, config) { code, _ ->
            guard("onRoomLoginResult") { onLoginResult(join, code) }
        }
    }

    private fun configurePublisher(zego: ZegoExpressEngine, join: JoinRequest, videoSource: NosmaiZegoVideoSource) {
        // Custom capture can only change outside a room; it is set before every login.
        zego.enableCustomVideoCapture(
            true,
            ZegoCustomVideoCaptureConfig().apply { bufferType = ZegoVideoBufferType.RAW_DATA },
            ZegoPublishChannel.MAIN,
        )
        zego.setCustomVideoCaptureHandler(videoSource)
        // A previous live on this stream ID may have left the end mark behind.
        zego.setStreamExtraInfo("", null)
        // Viewers must see exactly the Nosmai preview, as rendered.
        zego.setVideoMirrorMode(ZegoVideoMirrorMode.NO_MIRROR)
        zego.setVideoConfig(ZegoVideoConfig().apply {
            setCaptureResolution(join.encodeWidth, join.encodeHeight)
            setEncodeResolution(join.encodeWidth, join.encodeHeight)
            setVideoFPS(join.fps)
            setVideoBitrate(join.bitrateKbps)
        })
        // Bad network: keep the frame rate and lower resolution, or let ZEGO lower both.
        val property = if (join.prioritizeFrameRate) {
            ZegoTrafficControlProperty.ADAPTIVE_RESOLUTION.value()
        } else {
            ZegoTrafficControlProperty.ADAPTIVE_FPS.value() or ZegoTrafficControlProperty.ADAPTIVE_RESOLUTION.value()
        }
        zego.enableTrafficControl(true, property)
        zego.enableAudioCaptureDevice(join.publishAudio)
        zego.mutePublishStreamAudio(join.micMuted || !join.publishAudio)
        zego.mutePublishStreamVideo(join.videoMuted)
        videoSource.setPaused(join.videoMuted)
    }

    private fun onLoginResult(join: JoinRequest, code: Int) {
        if (request !== join) return // Left while logging in.
        if (code != 0) {
            Log.w(TAG, "loginRoom failed: $code")
            val message = describeError(code)
            cleanUpEngine(join)
            resetState()
            releaseEngine()
            send(mapOf("type" to "error", "code" to code, "message" to message, "fatal" to true), join.sessionId)
            return
        }
        loggedIn = true
        joinedAtMs = System.currentTimeMillis()
        send(mapOf("type" to "joined"))
        val zego = engine ?: return
        if (join.host) {
            zego.startPublishingStream(join.streamId ?: return)
        } else {
            refreshPlayback()
        }
    }

    /**
     * Leaves the room. A broadcaster with [endSession] first tells viewers the live is over, so
     * they stop instead of waiting for a new broadcaster. `left` follows.
     */
    fun leave(sessionId: Long?, endSession: Boolean) {
        val current = request
        if (current == null || (sessionId != null && current.sessionId != sessionId)) {
            // Not this session's to end (already over, or a newer session is active): confirm at
            // once so Dart never waits, and leave any newer session alone.
            send(mapOf("type" to "left", "reason" to "BySelf"), sessionId)
            return
        }
        if (leaving != null) return
        val zego = engine
        if (current.host && endSession && loggedIn && zego != null) {
            // Two signals: a room command (instant, unreliable) and the stream's extra info (kept
            // by the server, so viewers also see it on the stream's removal). Never wait long.
            val fallback = Runnable { finishLeave("BySelf") }
            leaving = fallback
            main.postDelayed(fallback, END_NOTICE_WAIT_MS)
            var pending = 2
            val done = { code: Int ->
                if (code != 0) Log.w(TAG, "End-of-live notice failed: $code")
                main.post { if (--pending == 0 && leaving === fallback) finishLeave("BySelf") }
            }
            zego.setStreamExtraInfo(END_MARK) { code -> done(code) }
            zego.sendCustomCommand(current.roomId, END_MARK, null) { code -> done(code) }
            return
        }
        finishLeave("BySelf")
    }

    private fun finishLeave(reason: String) {
        val current = request ?: return
        leaving?.let(main::removeCallbacks)
        leaving = null
        cleanUpEngine(current)
        resetState()
        send(mapOf("type" to "left", "reason" to reason), current.sessionId)
        onLeft(current)
        releaseEngine()
    }

    /** Viewer: [stream] is the watched broadcaster's and carries the end mark. Ends the live. */
    private fun endedLive(stream: ZegoStream): Boolean {
        val current = request ?: return false
        if (current.host || stream.extraInfo != END_MARK) return false
        if (stream.streamID != playing?.streamID) {
            // An ended stream still listed (e.g. a leftover): never pick it.
            stream.streamID?.let(failedStreams::add)
            return false
        }
        finishLeave("EndByHost")
        return true
    }

    /** Told after a session ended (the plugin stops the video source). */
    var onLeft: (JoinRequest) -> Unit = {}

    private fun send(event: Map<String, Any?>, sessionId: Long? = request?.sessionId) {
        emit(event + ("session" to sessionId))
    }

    private fun cleanUpEngine(current: JoinRequest) {
        val zego = engine ?: return
        runCatching {
            if (current.host) {
                zego.stopPublishingStream()
                zego.mutePublishStreamAudio(false)
                zego.mutePublishStreamVideo(false)
                zego.enableAudioCaptureDevice(true)
            } else {
                playing?.streamID?.let(zego::stopPlayingStream)
                zego.muteSpeaker(false)
            }
            zego.logoutRoom(current.roomId)
            if (current.host) zego.enableCustomVideoCapture(false, null, ZegoPublishChannel.MAIN)
        }.onFailure { Log.w(TAG, "Leaving the ZEGOCLOUD room failed", it) }
        // The plugin shuts the video source down off the main thread when `left` arrives.
    }

    fun setMicMuted(muted: Boolean) {
        micMuted = muted
        applyMedia()
    }

    fun setVideoMuted(muted: Boolean) {
        videoMuted = muted
        applyMedia()
    }

    fun setSpeakerMuted(muted: Boolean) {
        speakerMuted = muted
        applyMedia()
    }

    /** Backgrounded: stop sending (broadcaster) or receiving (viewer) until foregrounded. */
    fun setForeground(value: Boolean) {
        if (foreground == value) return
        foreground = value
        applyMedia()
    }

    private fun applyMedia() {
        val current = request ?: return
        val zego = engine ?: return
        if (current.host) {
            val stopVideo = videoMuted || !foreground
            source?.setPaused(stopVideo)
            zego.mutePublishStreamVideo(stopVideo)
            zego.mutePublishStreamAudio(micMuted || !foreground || !current.publishAudio)
        } else {
            zego.muteSpeaker(speakerMuted)
            playing?.streamID?.let { id ->
                zego.mutePlayStreamVideo(id, !foreground)
                zego.mutePlayStreamAudio(id, !foreground)
            }
            reportRemote()
        }
    }

    // ---- Broadcaster ----

    /** From the video source (main thread): ZEGO started or stopped asking for frames. */
    fun onCapturing() {
        val current = request ?: return
        if (!current.host) return
        // Read the source itself: a late notice from a previous broadcast must not count.
        capturing = source?.isCapturing == true
        reportSending()
    }

    private fun onPublisherState(streamID: String?, state: ZegoPublisherState, code: Int) {
        val current = request ?: return
        if (!current.host || streamID != current.streamId) return
        publisherState = state
        Log.i(TAG, "Publisher $state ($code)")
        when {
            code == 0 -> Unit
            state == ZegoPublisherState.NO_PUBLISH -> send(mapOf(
                "type" to "error", "code" to code, "message" to describeError(code), "fatal" to true,
            ))
            // ZEGO keeps retrying (PUBLISH_REQUESTING) on network trouble.
            else -> warn("Publishing is retrying: ${describeError(code)}")
        }
        reportSending()
    }

    private fun reportSending() {
        val on = capturing && publisherState == ZegoPublisherState.PUBLISHING
        if (on == reportedSending) return
        reportedSending = on
        send(mapOf("type" to "sending", "on" to on))
    }

    // ---- Viewer ----

    fun attachRemoteView(view: TextureView) {
        remoteView = view
        val id = playing?.streamID ?: return
        engine?.startPlayingStream(id, canvas(view))
    }

    fun detachRemoteView(view: TextureView) {
        if (remoteView !== view) return
        remoteView = null
        val id = playing?.streamID ?: return
        val zego = engine ?: return
        // Keep the audio; drop only the picture.
        runCatching { zego.startPlayingStream(id, null as ZegoCanvas?) }
            .onFailure { Log.w(TAG, "Detaching the remote view failed", it) }
        firstFrameShown = false
        reportRemote()
    }

    private fun canvas(view: TextureView) = ZegoCanvas(view).apply { viewMode = ZegoViewMode.ASPECT_FIT }

    /** Plays the stream to watch, switching when it changes, and reports what is shown. */
    private fun refreshPlayback() {
        val current = request ?: return
        if (current.host || !loggedIn) return
        val zego = engine ?: return
        val target = pickStream(current)
        if (target?.streamID != playing?.streamID) {
            playing?.streamID?.let(zego::stopPlayingStream)
            playing = target
            playerState = ZegoPlayerState.NO_PLAY
            firstFrameShown = false
            remoteCameraOn = true
            playQuality = null
            playSize = Pair(0, 0)
            target?.streamID?.let { id ->
                val view = remoteView
                if (view != null) zego.startPlayingStream(id, canvas(view)) else zego.startPlayingStream(id)
                if (!foreground) {
                    zego.mutePlayStreamVideo(id, true)
                    zego.mutePlayStreamAudio(id, true)
                }
            }
        }
        reportRemote()
    }

    /**
     * The stream to watch: the requested stream ID, else the requested user's, else the newest
     * stream that has not failed. A stream a crashed broadcaster left behind stays listed until
     * ZEGOCLOUD times it out, so the newest working one is the likely live one.
     */
    private fun pickStream(current: JoinRequest): ZegoStream? {
        val streams = roomStreams.values.filter { it.user?.userID != current.userId && it.extraInfo != END_MARK }
        current.streamId?.let { wanted -> return streams.lastOrNull { it.streamID == wanted } }
        current.hostUserId?.let { wanted ->
            val theirs = streams.filter { it.user?.userID == wanted }
            return theirs.lastOrNull { it.streamID !in failedStreams } ?: theirs.lastOrNull()
        }
        return streams.lastOrNull { it.streamID !in failedStreams } ?: streams.lastOrNull()
    }

    private fun onPlayerState(streamID: String?, state: ZegoPlayerState, code: Int) {
        if (request?.host != false || streamID != playing?.streamID) return
        playerState = state
        Log.i(TAG, "Player $state ($code)")
        if (state != ZegoPlayerState.PLAYING) firstFrameShown = false
        if (code != 0) {
            streamID?.let(failedStreams::add)
            val before = playing?.streamID
            refreshPlayback() // Moves to another stream if one has not failed.
            if (playing?.streamID != before) return
            warn("Playing the broadcaster's stream: ${describeError(code)}")
        }
        reportRemote()
    }

    private fun reportRemote() {
        val current = request ?: return
        if (current.host) return
        val stream = playing
        val on = stream != null && loggedIn && foreground && remoteView != null &&
            playerState == ZegoPlayerState.PLAYING && firstFrameShown && remoteCameraOn
        val next = listOf(stream?.streamID, stream?.user?.userID, on)
        if (next == reportedRemote) return
        reportedRemote = next
        send(mapOf(
            "type" to "remoteVideo",
            "streamId" to stream?.streamID,
            "userId" to stream?.user?.userID,
            "userName" to stream?.user?.userName,
            "on" to on,
        ))
    }

    // ---- Room ----

    private fun onRoomState(roomID: String?, reason: ZegoRoomStateChangedReason?, code: Int) {
        val current = request ?: return
        if (roomID != current.roomId) return
        Log.i(TAG, "Room $reason ($code)")
        when (reason) {
            ZegoRoomStateChangedReason.RECONNECTING -> if (loggedIn) send(mapOf("type" to "reconnecting"))
            ZegoRoomStateChangedReason.RECONNECTED -> if (loggedIn) send(mapOf("type" to "reconnected"))
            ZegoRoomStateChangedReason.RECONNECT_FAILED -> finishLeave("NetworkError")
            ZegoRoomStateChangedReason.KICK_OUT -> finishLeave(
                if (code == ZegoExpressErrorCode.RoomKickedOut) "SignedInElsewhere" else "KickedOut",
            )
            else -> Unit // Login results arrive through the loginRoom callback.
        }
    }

    // ---- Stats ----

    fun stats(): Map<String, Any?> {
        val current = request
        val stats = HashMap<String, Any?>()
        stats["inRoom"] = loggedIn
        if (current == null || !loggedIn) return stats
        stats["participants"] = maxOf(others.size, onlineCount - 1, 0)
        stats["secondsLive"] = if (joinedAtMs > 0) (System.currentTimeMillis() - joinedAtMs) / 1000 else 0
        if (current.host) {
            stats["micMuted"] = micMuted || !current.publishAudio
            stats["width"] = current.encodeWidth
            stats["height"] = current.encodeHeight
            publishQuality?.let { q ->
                stats["fps"] = q.videoSendFPS
                stats["encodeFps"] = q.videoEncodeFPS
                stats["bitrateKbps"] = maxOf(q.videoKBPS, 0.0)
                stats["rttMs"] = maxOf(q.rtt, 0)
                stats["lossPercent"] = maxOf(q.packetLostRate * 100, 0.0)
                stats["network"] = qualityName(q.level)
                stats["hardwareCodec"] = q.isHardwareEncode
            }
        } else {
            stats["width"] = playSize.first
            stats["height"] = playSize.second
            playQuality?.let { q ->
                stats["fps"] = if (q.videoRenderFPS > 0) q.videoRenderFPS else q.videoRecvFPS
                stats["bitrateKbps"] = maxOf(q.videoKBPS, 0.0)
                stats["latencyMs"] = maxOf(q.peerToPeerDelay, 0)
                stats["rttMs"] = maxOf(q.rtt, 0)
                stats["lossPercent"] = maxOf(q.packetLostRate * 100, 0.0)
                stats["network"] = qualityName(q.level)
                stats["hardwareCodec"] = q.isHardwareDecode
            }
        }
        return stats
    }

    private fun qualityName(level: ZegoStreamQualityLevel?): String = when (level) {
        ZegoStreamQualityLevel.EXCELLENT -> "Excellent"
        ZegoStreamQualityLevel.GOOD -> "Good"
        ZegoStreamQualityLevel.MEDIUM -> "Medium"
        ZegoStreamQualityLevel.BAD -> "Bad"
        ZegoStreamQualityLevel.DIE -> "Down"
        else -> "Unknown"
    }

    // ---- Helpers ----

    private fun isMyRoom(roomID: String?) = request != null && roomID == request?.roomId

    private fun warn(message: String) {
        Log.w(TAG, message)
        send(mapOf("type" to "warning", "message" to message))
    }

    private inline fun guard(name: String, block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            Log.e(TAG, "$name failed", t)
        }
    }

    private fun resetState() {
        request = null
        source = null
        loggedIn = false
        joinedAtMs = 0L
        foreground = true
        publisherState = ZegoPublisherState.NO_PUBLISH
        capturing = false
        reportedSending = null
        publishQuality = null
        roomStreams.clear()
        failedStreams.clear()
        playing = null
        playerState = ZegoPlayerState.NO_PLAY
        firstFrameShown = false
        remoteCameraOn = true
        playQuality = null
        playSize = Pair(0, 0)
        reportedRemote = null
        others.clear()
        onlineCount = 0
    }

    companion object {
        private const val TAG = "NosmaiZegoLive"

        /** Room command and stream extra info a broadcaster sets when it ends the live for everyone. */
        const val END_MARK = "nosmai_zegocloud_live:end"
        private const val END_NOTICE_WAIT_MS = 800L

        fun describeError(code: Int): String = when (code) {
            ZegoExpressErrorCode.EngineAppsignIncorrect,
            ZegoExpressErrorCode.EngineAppidIncorrectOrNotOnline,
            ZegoExpressErrorCode.EngineAppsignInvalidLength,
            ZegoExpressErrorCode.EngineAppsignInvalidCharacter ->
                "ZEGOCLOUD rejected the AppID or AppSign. Copy both from the same project in the ZEGOCLOUD console."
            ZegoExpressErrorCode.RoomErrorAuthenticationFailed ->
                "ZEGOCLOUD authentication failed. Check the AppID, AppSign or token."
            ZegoExpressErrorCode.RoomNoToken -> "This ZEGOCLOUD project needs a token to log in."
            ZegoExpressErrorCode.RoomErrorConnectFailed, ZegoExpressErrorCode.RoomErrorLoginTimeout ->
                "Could not reach ZEGOCLOUD. Check the network."
            ZegoExpressErrorCode.RoomRetryTimeout -> "Lost the connection to ZEGOCLOUD."
            ZegoExpressErrorCode.RoomErrorExceedMaximumMember -> "The room is full."
            ZegoExpressErrorCode.RoomKickedOut -> "Signed out: the same user ID joined from another device."
            ZegoExpressErrorCode.RoomUserInBlacklist -> "This user is blocked from the room."
            ZegoExpressErrorCode.RoomCountExceed -> "Already in a ZEGOCLOUD room."
            ZegoExpressErrorCode.PublisherErrorRepetitivePublishStream ->
                "Another broadcaster is already publishing this stream ID."
            ZegoExpressErrorCode.PublisherErrorServerForbid -> "ZEGOCLOUD does not allow publishing this stream."
            in 1002000..1002999 -> "ZEGOCLOUD room error $code."
            in 1003000..1003999 -> "ZEGOCLOUD publishing error $code."
            in 1004000..1004999 -> "ZEGOCLOUD playing error $code."
            else -> "ZEGOCLOUD error $code."
        }
    }
}

internal class BridgeException(val code: String, message: String) : Exception(message)
