import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_zegocloud_live/nosmai_zegocloud_live.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NosmaiLiveCredentials host({String? appSign, String token = '', String userId = 'host_1'}) =>
      NosmaiLiveCredentials(appId: testAppId, appSign: appSign ?? testAppSign, token: token, userId: userId, userName: 'Host');

  NosmaiLiveBroadcaster broadcaster(FakeBridge bridge,
          {NosmaiLiveCredentials? credentials,
          bool ready = true,
          bool publishAudio = true,
          bool endSessionOnStop = true,
          NosmaiLiveSession session = const NosmaiLiveSession('room-1')}) =>
      NosmaiLiveBroadcaster(
        credentials: credentials ?? host(),
        session: session,
        video: NosmaiLiveVideoConfig.hd,
        publishAudio: publishAudio,
        endSessionOnStop: endSessionOnStop,
        bridge: bridge,
        nosmaiReady: () => ready,
        clock: () => testNow,
        statsInterval: const Duration(days: 1),
      );

  test('logs in, goes live once ZEGOCLOUD publishes, and ends the live on stop', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge);
    final states = <NosmaiLiveState>[];
    live.addListener(() => states.add(live.state));

    await live.start();
    expect(live.state, NosmaiLiveState.connecting);
    expect(bridge.joinArguments, containsPair('host', true));
    expect(bridge.joinArguments, containsPair('appId', testAppId));
    expect(bridge.joinArguments, containsPair('appSign', testAppSign));
    expect(bridge.joinArguments, containsPair('roomId', 'room-1'));
    expect(bridge.joinArguments, containsPair('userId', 'host_1'));
    expect(bridge.joinArguments, containsPair('streamId', 'room-1_host_1'));
    expect(bridge.joinArguments, containsPair('width', 720));
    expect(bridge.joinArguments, containsPair('height', 1280));
    expect(bridge.joinArguments, containsPair('bitrateKbps', 1800));
    expect(bridge.joinArguments, containsPair('fps', 30));
    expect(bridge.joinArguments, containsPair('micMuted', false));
    expect(bridge.joinArguments, containsPair('prioritizeFrameRate', true));
    expect(live.streamId, 'room-1_host_1');

    bridge.emit({'type': 'sending', 'on': true});
    expect(live.state, NosmaiLiveState.live);
    expect(live.isLive, isTrue);

    await live.stop();
    expect(bridge.calls, contains('leave:true'));
    expect(live.state, NosmaiLiveState.stopped);
    expect(live.error, isNull);
    expect(states, containsAllInOrder([NosmaiLiveState.connecting, NosmaiLiveState.live, NosmaiLiveState.stopped]));
  });

  test('publishes an explicit stream ID and can leave viewers waiting on stop', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge,
        endSessionOnStop: false, session: const NosmaiLiveSession('room-1', streamId: 'main_stream'));
    await live.start();
    expect(bridge.joinArguments, containsPair('streamId', 'main_stream'));
    await live.stop();
    expect(bridge.calls, contains('leave:false'));
  });

  test('rejects bad credentials before contacting ZEGOCLOUD', () async {
    for (final bad in [
      NosmaiLiveCredentials(appId: 0, appSign: testAppSign, userId: 'u'),
      const NosmaiLiveCredentials(appId: testAppId, userId: 'u'),
      const NosmaiLiveCredentials(appId: testAppId, appSign: 'short', userId: 'u'),
      host(userId: 'has space'),
      host(token: token04(expires: testNow.subtract(const Duration(minutes: 1)))),
    ]) {
      final bridge = FakeBridge();
      final live = broadcaster(bridge, credentials: bad);
      await expectLater(live.start(),
          throwsA(isA<NosmaiLiveException>().having((e) => e.code, 'code', 'invalid_credentials')), reason: '$bad');
      expect(bridge.calls, isNot(contains('join')));
      expect(live.state, NosmaiLiveState.failed);
    }
  });

  test('accepts a token without an AppSign', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge, credentials: host(appSign: '', token: token04()));
    await live.start();
    expect(bridge.joinArguments, containsPair('appSign', ''));
    expect(bridge.joinArguments?['token'], startsWith('04'));
    await live.stop();
  });

  test('rejects a bad room ID', () async {
    await expectLater(broadcaster(FakeBridge(), session: const NosmaiLiveSession('room with space')).start(),
        throwsA(isA<NosmaiLiveException>().having((e) => e.code, 'code', 'invalid_config')));
  });

  test('requires NosmaiZegoCloudLive.initialize', () async {
    await expectLater(broadcaster(FakeBridge(), ready: false).start(),
        throwsA(isA<NosmaiLiveException>().having((e) => e.code, 'code', 'not_initialized')));
  });

  test('needs the microphone only when publishing audio', () async {
    await expectLater(broadcaster(FakeBridge(microphone: false)).start(),
        throwsA(isA<NosmaiLiveException>().having((e) => e.code, 'code', 'permission_denied')));
    final bridge = FakeBridge(microphone: false);
    final live = broadcaster(bridge, publishAudio: false);
    await live.start();
    expect(bridge.calls, contains('permissions:true:false'));
    expect(bridge.joinArguments, containsPair('micMuted', true));
    expect(bridge.joinArguments, containsPair('publishAudio', false));
    expect(live.micMuted, isTrue);
    await live.stop();
  });

  test('surfaces native join errors with their code', () async {
    final bridge = FakeBridge(
        joinError: PlatformException(code: 'already_active', message: 'Another ZEGOCLOUD session is active'));
    final live = broadcaster(bridge);
    await expectLater(
        live.start(),
        throwsA(isA<NosmaiLiveException>()
            .having((e) => e.code, 'code', 'already_active')
            .having((e) => e.message, 'message', contains('Another ZEGOCLOUD session'))));
    expect(live.state, NosmaiLiveState.failed);
    // Leave is still sent: native ends the session only if it is this one.
    expect(bridge.calls, contains('leave:true'));
  });

  test('ignores events from another session and leaves its own on stop', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge);
    await live.start();
    final mine = bridge.session!;
    bridge.emit({'type': 'sending', 'on': true});
    expect(live.state, NosmaiLiveState.live);

    // A late `left` from an earlier session must not end this one (it stranded a live stream).
    bridge.emit({'type': 'left', 'reason': 'BySelf', 'session': mine - 1});
    bridge.emit({'type': 'sending', 'on': false, 'session': mine + 1});
    await Future<void>.delayed(Duration.zero);
    expect(live.state, NosmaiLiveState.live);
    expect(live.error, isNull);

    await live.stop();
    expect(bridge.calls, contains('leave:true'));
    expect(live.state, NosmaiLiveState.stopped);
  });

  test('each session gets its own ID', () async {
    final bridge = FakeBridge();
    final first = broadcaster(bridge);
    await first.start();
    final firstId = bridge.session;
    await first.stop();
    final second = broadcaster(bridge);
    await second.start();
    expect(bridge.session, isNot(firstId));
    await second.stop();
  });

  test('fails with invalid_credentials when ZEGOCLOUD rejects the AppSign at login', () async {
    final bridge = FakeBridge(autoJoin: false);
    final live = broadcaster(bridge);
    final starting = live.start();
    await Future<void>.delayed(Duration.zero);
    bridge.emit({'type': 'error', 'code': 1001005, 'message': 'AppSign rejected', 'fatal': true});
    await expectLater(
        starting,
        throwsA(isA<NosmaiLiveException>()
            .having((e) => e.message, 'message', 'AppSign rejected')
            .having((e) => e.code, 'code', 'invalid_credentials')));
    expect(live.state, NosmaiLiveState.failed);
    expect(live.error, 'AppSign rejected');
  });

  test('times out when ZEGOCLOUD never confirms the login', () async {
    final bridge = FakeBridge(autoJoin: false);
    final live = NosmaiLiveBroadcaster(
      credentials: host(),
      session: const NosmaiLiveSession('room-1'),
      bridge: bridge,
      nosmaiReady: () => true,
      clock: () => testNow,
      joinTimeout: const Duration(milliseconds: 10),
    );
    await expectLater(live.start(), throwsA(isA<NosmaiLiveException>().having((e) => e.message, 'message', contains('timed out'))));
    expect(bridge.calls, contains('leave:true'));
  });

  test('fails when the same user ID signs in elsewhere', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge);
    await live.start();
    bridge.emit({'type': 'sending', 'on': true});
    bridge.emit({'type': 'left', 'reason': 'SignedInElsewhere'});
    await Future<void>.delayed(Duration.zero);
    expect(live.state, NosmaiLiveState.failed);
    expect(live.error, contains('another device'));
  });

  test('mutes, pauses in the background and reports reconnecting', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge);
    await live.start();
    bridge.emit({'type': 'sending', 'on': true});

    live.setMicMuted(true);
    live.setVideoMuted(true);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.calls, containsAll(['mic:true', 'video:true']));
    expect(live.micMuted && live.videoMuted, isTrue);

    live.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(live.state, NosmaiLiveState.paused);
    live.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.calls, containsAllInOrder(['foreground:false', 'foreground:true']));
    expect(live.state, NosmaiLiveState.live);

    bridge.emit({'type': 'reconnecting'});
    expect(live.state, NosmaiLiveState.reconnecting);
    bridge.emit({'type': 'reconnected'});
    expect(live.state, NosmaiLiveState.live);
    await live.stop();
  });

  test('warns before the token expires and renews it in place', () async {
    final bridge = FakeBridge();
    final live = broadcaster(bridge, credentials: host(appSign: '', token: token04()));
    await expectLater(live.renewToken(token04()),
        throwsA(isA<NosmaiLiveException>().having((e) => e.code, 'code', 'not_active')));
    await live.start();
    bridge.emit({'type': 'sending', 'on': true});
    bridge.emit({'type': 'tokenWillExpire', 'seconds': 30});
    expect(live.tokenExpiresAt, isNotNull);
    expect(live.warning, contains('renewToken'));

    await expectLater(live.renewToken('not-a-token'),
        throwsA(isA<NosmaiLiveException>().having((e) => e.code, 'code', 'invalid_credentials')));
    await live.renewToken(token04(expires: testNow.add(const Duration(hours: 4))));
    expect(bridge.calls, contains('renew'));
    expect(live.tokenExpiresAt, isNull);
    expect(live.state, NosmaiLiveState.live);
    await live.stop();
  });

  test('a broadcaster starts once', () async {
    final live = broadcaster(FakeBridge());
    await live.start();
    expect(live.start, throwsStateError);
    await live.stop();
  });
}
