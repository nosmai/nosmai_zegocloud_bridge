import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:nosmai_zegocloud_live/src/native_bridge.dart';

final testNow = DateTime.utc(2026, 11, 16, 12);

const testAppId = 117962517;
final testAppSign = 'ab' * 32;

/// A Token04-shaped string expiring at [expires] (the encrypted part is filler).
String token04({DateTime? expires}) {
  final exp = (expires ?? testNow.add(const Duration(hours: 2))).millisecondsSinceEpoch ~/ 1000;
  final header = ByteData(8)..setInt64(0, exp);
  final bytes = [...header.buffer.asUint8List(), 0, 16, ...List.filled(16, 7), 0, 4, 1, 2, 3, 4];
  return '04${base64.encode(bytes)}';
}

/// Records calls and plays the native side: `joined` after join, `left` after leave.
class FakeBridge extends NativeBridge {
  FakeBridge({this.camera = true, this.microphone = true, this.autoJoin = true, this.joinError});

  final controller = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final calls = <String>[];
  bool camera;
  bool microphone;
  bool autoJoin;
  PlatformException? joinError;
  Map<String, Object?>? joinArguments;
  Map<Object?, Object?>? statsSample;

  void emit(Map<String, Object?> event) => controller.add({'session': session, ...event});

  @override
  Stream<Map<String, Object?>> get events => controller.stream;

  @override
  Future<bool> prepare() async {
    calls.add('prepare');
    return true;
  }

  @override
  Future<({bool camera, bool microphone})> requestPermissions({bool camera = true, bool microphone = true}) async {
    calls.add('permissions:$camera:$microphone');
    return (camera: this.camera, microphone: this.microphone);
  }

  /// The `sessionId` of the last join; tags [emit]ted events like the native side.
  int? session;

  @override
  Future<void> join(Map<String, Object?> arguments) async {
    calls.add('join');
    joinArguments = arguments;
    session = arguments['sessionId'] as int?;
    final error = joinError;
    if (error != null) throw error;
    if (autoJoin) scheduleMicrotask(() => emit({'type': 'joined'}));
  }

  @override
  Future<void> leave({required int sessionId, required bool endSession}) async {
    calls.add('leave:$endSession');
    scheduleMicrotask(() => emit({'type': 'left', 'reason': 'BySelf', 'session': sessionId}));
  }

  @override
  Future<void> renewToken({required int sessionId, required String token}) async {
    if (sessionId != session) throw PlatformException(code: 'not_active', message: 'This session has ended.');
    calls.add('renew');
  }

  @override
  Future<void> setMicMuted(bool muted) async => calls.add('mic:$muted');

  @override
  Future<void> setVideoMuted(bool muted) async => calls.add('video:$muted');

  @override
  Future<void> setSpeakerMuted(bool muted) async => calls.add('speaker:$muted');

  @override
  Future<void> setForeground(bool foreground) async => calls.add('foreground:$foreground');

  @override
  Future<void> setMaxFps(int fps) async => calls.add('fps:$fps');

  @override
  Future<Map<Object?, Object?>?> stats() async => statsSample;
}
