import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_zegocloud_live/nosmai_zegocloud_live.dart';

import 'fakes.dart';

void main() {
  test('reads the expiry of a Token04', () {
    final token = NosmaiZegoToken.tryParse(token04());
    expect(token?.expiresAt, testNow.add(const Duration(hours: 2)));
    expect(NosmaiZegoToken.tryParse('not-a-token'), isNull);
    expect(NosmaiZegoToken.tryParse('04!!!!notbase64!!!!'), isNull);
    expect(NosmaiZegoToken.problemFor(token04(), now: testNow), isNull);
    expect(NosmaiZegoToken.problemFor(token04(expires: testNow), now: testNow), contains('expired'));
    expect(NosmaiZegoToken.problemFor('eyJhbGciOi', now: testNow), contains('Token04'));
  });

  test('validates rooms and stream IDs', () {
    expect(const NosmaiLiveSession('room-1').validate(), isNull);
    expect(const NosmaiLiveSession(' ').validate(), isNotNull);
    expect(NosmaiLiveSession('x' * 128).validate(), contains('128'));
    expect(const NosmaiLiveSession('a b').validate(), contains('letters'));
    expect(const NosmaiLiveSession('r', streamId: 'bad.id').validate(), contains('stream ID'));
    expect(const NosmaiLiveSession('r', streamId: 'good_id-1').validate(), isNull);
  });

  test('derives a valid stream ID from room and user', () {
    expect(const NosmaiLiveSession('room-1').streamIdFor('host_1'), 'room-1_host_1');
    expect(const NosmaiLiveSession('room.1#a').streamIdFor('u@x'), 'room_1_a_u_x');
    expect(const NosmaiLiveSession('room', streamId: 'fixed').streamIdFor('u'), 'fixed');
  });

  test('validates credentials', () {
    NosmaiLiveCredentials c({int appId = testAppId, String? appSign, String token = '', String userId = 'u1'}) =>
        NosmaiLiveCredentials(appId: appId, appSign: appSign ?? testAppSign, token: token, userId: userId);
    expect(c().validate(now: testNow), isNull);
    expect(c(appId: 0).validate(now: testNow), contains('AppID'));
    expect(c(appSign: '').validate(now: testNow), contains('AppSign or a token'));
    expect(c(appSign: 'zz' * 32).validate(now: testNow), contains('64 hexadecimal'));
    expect(c(appSign: '', token: token04()).validate(now: testNow), isNull);
    expect(c(userId: '').validate(now: testNow), contains('empty'));
    expect(c(userId: 'x' * 64).validate(now: testNow), contains('64 bytes'));
    expect(c().userName, 'u1');
    expect(NosmaiLiveCredentials(appId: 1, appSign: testAppSign, userId: 'u', userName: ' Ana ').userName, 'Ana');
    expect(c().toString(), isNot(contains(testAppSign)));
  });

  test('presets map to portrait encode sizes and bitrates', () {
    expect(NosmaiLiveVideoConfig.low.resolution.longSide, 640);
    expect(NosmaiLiveVideoConfig.low.resolution.shortSide, 360);
    expect(NosmaiLiveVideoConfig.standard.resolution.shortSide, 540);
    expect(NosmaiLiveVideoConfig.standard.fps, 24);
    expect(NosmaiLiveVideoConfig.standard.effectiveBitrateKbps, 1200);
    expect(NosmaiLiveVideoConfig.hd.resolution.shortSide, 720);
    expect(NosmaiLiveVideoConfig.hd.fps, 30);
    expect(const NosmaiLiveVideoConfig(bitrateKbps: 900).effectiveBitrateKbps, 900);
  });

  test('parses native stats', () {
    final stats = NosmaiLiveStats.fromNative({
      'engine': {'inRoom': true, 'fps': 29.5, 'encodeFps': 30.0, 'width': 720, 'height': 1280, 'bitrateKbps': 1500.4,
        'rttMs': 40, 'latencyMs': 0, 'lossPercent': 0.5, 'network': 'Excellent', 'participants': 3,
        'hardwareCodec': true},
      'source': {'framesIn': 300, 'sent': 290, 'dropped': 2, 'inputFps': 30.1, 'txFps': 29.7, 'convertMsAvg': 1.25,
        'transport': 'texture', 'lastError': ''},
      'process': {'cpuPercent': 41.5, 'rssMb': 310.2},
    });
    expect(stats.width, 720);
    expect(stats.fps, 29.5);
    expect(stats.encodeFps, 30);
    expect(stats.bitrateKbps, 1500.4);
    expect(stats.rttMs, 40);
    expect(stats.lossPercent, 0.5);
    expect(stats.network, 'Excellent');
    expect(stats.participants, 3);
    expect(stats.hardwareCodec, isTrue);
    expect(stats.framesFromNosmai, 300);
    expect(stats.framesSent, 290);
    expect(stats.nosmaiFps, 30.1);
    expect(stats.sendFps, 29.7);
    expect(stats.transport, 'texture');
    expect(stats.cpuPercent, 41.5);
    expect(stats.memoryMb, 310.2);
    expect(NosmaiLiveStats.fromNative(null).fps, 0);
  });
}
