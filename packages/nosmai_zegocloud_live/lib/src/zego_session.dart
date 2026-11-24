import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'native_bridge.dart';
import 'stats.dart';

/// One ZEGOCLOUD room login for a broadcaster or a viewer.
///
/// ZEGO runs natively; its outcomes arrive as events from the plugin, and this
/// class turns them into flags the broadcaster and viewer map to states.
class ZegoLiveSession extends ChangeNotifier {
  ZegoLiveSession({
    required this.bridge,
    required this.isHost,
    required this.joinArguments,
    this.endSessionOnClose = false,
    this.joinTimeout = const Duration(seconds: 25),
    this.leaveTimeout = const Duration(seconds: 5),
    this.firstFrameTimeout = const Duration(seconds: 15),
    this.statsInterval = const Duration(seconds: 1),
  });

  final NativeBridge bridge;
  final bool isHost;
  final Map<String, Object?> joinArguments;

  /// Tags this session's native calls and events: a late event from an
  /// earlier session (or a newer one) is ignored.
  final int id = _newId();

  static int _lastId = 0;
  static int _newId() {
    // Unique across hot restarts too: the native side outlives the Dart isolate.
    final now = DateTime.now().microsecondsSinceEpoch;
    _lastId = now > _lastId ? now : _lastId + 1;
    return _lastId;
  }

  /// Broadcaster: tell viewers the live ended on close.
  final bool endSessionOnClose;
  final Duration joinTimeout;
  final Duration leaveTimeout;
  final Duration firstFrameTimeout;
  final Duration statsInterval;

  StreamSubscription<Map<String, Object?>>? _events;
  Timer? _joinTimer;
  Timer? _frameTimer;
  Timer? _statsTimer;
  Completer<void>? _leftSignal;
  Future<void>? _closeFuture;
  /// Native reported `left` for this session: nothing is left to end.
  bool _nativeEnded = false;
  bool _started = false;
  bool _disposed = false;
  bool _foreground = true;

  bool joined = false;
  bool reconnecting = false;
  bool closing = false;
  bool closed = false;

  /// Broadcaster: ZEGOCLOUD is publishing and asking for frames.
  bool sending = false;

  /// Viewer: the watched broadcaster's video is on screen.
  bool remoteVideo = false;

  /// Viewer: the broadcaster being watched.
  String? remoteUserId;
  String? remoteUserName;
  String? remoteStreamId;

  /// Viewer: the broadcaster ended the live.
  bool endedByHost = false;

  String? error;
  String? warning;

  /// Set when ZEGOCLOUD warns that the room token is about to expire; cleared by [renewToken].
  DateTime? tokenExpiresAt;
  NosmaiLiveStats stats = NosmaiLiveStats.empty;

  bool get foreground => _foreground;

  /// Completes when the room is joined, or with an error if it fails first.
  Future<void> get entered => _entered.future;
  final Completer<void> _entered = Completer<void>();

  Future<void> start() async {
    if (_started || closing || _disposed) return;
    _started = true;
    _events = bridge.events.listen(_onEvent);
    _joinTimer = Timer(joinTimeout, () {
      _fail('Logging in to the ZEGOCLOUD room timed out. Check the network, the AppID and the AppSign.');
    });
    try {
      await bridge.join({...joinArguments, 'sessionId': id});
      if (closing) return;
    } on PlatformException catch (e) {
      _fail(e.message ?? e.code, code: e.code);
    } catch (e) {
      _fail('Could not start ZEGOCLOUD: $e');
    }
  }

  void _onEvent(Map<String, Object?> event) {
    assert(() {
      debugPrint('[NosmaiZegoLive] native event (mine=${event['session'] == id}, closed=$closed) $event');
      return true;
    }());
    if (_disposed || closed) return;
    final session = event['session'];
    if (session is num && session.toInt() != id) return;
    switch (event['type']) {
      case 'joined':
        if (closing) return;
        _joinTimer?.cancel();
        joined = true;
        reconnecting = false;
        if (!_entered.isCompleted) _entered.complete();
        _statsTimer ??= Timer.periodic(statsInterval, (_) => unawaited(_refreshStats()));
        if (isHost) _watchFirstFrame();
      case 'reconnecting':
        if (closing) return;
        reconnecting = true;
      case 'reconnected':
        reconnecting = false;
      case 'left':
        _nativeEnded = true;
        joined = false;
        sending = false;
        remoteVideo = false;
        final signal = _leftSignal;
        if (signal != null && !signal.isCompleted) signal.complete();
        if (closing) break;
        final reason = event['reason']?.toString() ?? 'Unknown';
        if (!isHost && reason == 'EndByHost') {
          endedByHost = true;
          unawaited(close());
        } else {
          _fail(switch (reason) {
            'NetworkError' => 'Disconnected from ZEGOCLOUD by a network error.',
            'SignedInElsewhere' => 'Signed out: the same user ID joined from another device.',
            'KickedOut' => 'Removed from the ZEGOCLOUD room.',
            _ => 'Left the ZEGOCLOUD room ($reason).',
          });
        }
      case 'error':
        if (event['fatal'] == true) {
          _fail(event['message']?.toString() ?? 'ZEGOCLOUD error ${event['code']}.', code: _codeFor(event['code']));
          return;
        }
        warning = event['message']?.toString();
      case 'warning':
        warning = event['message']?.toString();
      case 'tokenWillExpire':
        final seconds = (event['seconds'] as num?)?.toInt() ?? 0;
        tokenExpiresAt = DateTime.now().add(Duration(seconds: seconds));
        warning = 'The ZEGOCLOUD token expires in $seconds s. Call renewToken with a new one.';
      case 'remoteVideo':
        remoteStreamId = event['streamId']?.toString();
        remoteUserId = event['userId']?.toString();
        remoteUserName = event['userName']?.toString();
        remoteVideo = event['on'] == true;
        if (remoteVideo) warning = null;
      case 'sending':
        sending = event['on'] == true;
        if (sending) warning = null;
      default:
        return;
    }
    _notify();
  }

  static String _codeFor(Object? native) {
    final code = native is num ? native.toInt() : null;
    if (code == null) return 'start_failed';
    if (code >= 1001000 && code < 1002000) return 'invalid_credentials';
    if (code == 1002033 || code == 1002067) return 'invalid_credentials';
    return 'zego_$code';
  }

  Future<void> _refreshStats() async {
    if (closing || _disposed) return;
    try {
      final next = NosmaiLiveStats.fromNative(await bridge.stats());
      if (closing || _disposed) return;
      stats = next;
      if (isHost && next.framesSent > 0) _frameTimer?.cancel();
      _notify();
    } catch (_) {/* Stats must never break the session. */}
  }

  void _watchFirstFrame() {
    _frameTimer?.cancel();
    _frameTimer = Timer(firstFrameTimeout, () {
      if (closing || !_foreground || stats.framesSent > 0) return;
      warning = 'No video sent yet. Keep the Nosmai camera preview on screen.';
      _notify();
    });
  }

  Future<void> renewToken(String token) async {
    if (closing || _disposed) throw StateError('The session has ended.');
    await bridge.renewToken(sessionId: id, token: token);
    tokenExpiresAt = null;
    warning = null;
    _notify();
  }

  void setMicMuted(bool muted) => _send(() => bridge.setMicMuted(muted));

  void setVideoMuted(bool muted) => _send(() => bridge.setVideoMuted(muted));

  void setSpeakerMuted(bool muted) => _send(() => bridge.setSpeakerMuted(muted));

  void setForeground(bool foreground) {
    if (closing || _foreground == foreground) return;
    _foreground = foreground;
    _send(() => bridge.setForeground(foreground));
    _notify();
  }

  void _send(Future<void> Function() call) {
    if (closing || _disposed) return;
    unawaited(call().catchError((Object e) {
      warning = e is PlatformException ? (e.message ?? e.code) : '$e';
      _notify();
    }));
  }

  void _fail(String message, {String? code}) {
    if (closing || _disposed) return;
    error = message;
    failureCode = code;
    if (!_entered.isCompleted) _entered.completeError(StateError(message));
    _notify();
    unawaited(close());
  }

  /// The plugin's error code for [error], when it came from native code.
  String? failureCode;

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    closing = true;
    _joinTimer?.cancel();
    _frameTimer?.cancel();
    _statsTimer?.cancel();
    if (!_entered.isCompleted) {
      _entered.completeError(StateError(error ?? 'The session was closed.'));
    }
    // Callers that never awaited [entered] must not see an unhandled error.
    unawaited(_entered.future.catchError((_) {}));
    _notify();
    // Ask unless native already ended this session: it ends the session only
    // if it is still this one, and confirms with `left` either way.
    if (_started && !_nativeEnded) {
      final signal = _leftSignal = Completer<void>();
      try {
        await bridge.leave(sessionId: id, endSession: endSessionOnClose);
        await signal.future.timeout(leaveTimeout);
      } catch (_) {
        warning = 'ZEGOCLOUD did not confirm leaving the room.';
      }
    }
    await _events?.cancel();
    _events = null;
    joined = false;
    sending = false;
    remoteVideo = false;
    closed = true;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(close());
    _disposed = true;
    super.dispose();
  }
}
