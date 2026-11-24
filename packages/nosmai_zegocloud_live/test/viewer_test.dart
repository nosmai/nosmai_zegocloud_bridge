import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_zegocloud_live/nosmai_zegocloud_live.dart';

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NosmaiLiveViewer viewer(FakeBridge bridge,
          {String userId = 'viewer_1', String? hostUserId, NosmaiLiveSession session = const NosmaiLiveSession('room-1')}) =>
      NosmaiLiveViewer(
        credentials: NosmaiLiveCredentials(appId: testAppId, appSign: testAppSign, userId: userId),
        session: session,
        hostUserId: hostUserId,
        bridge: bridge,
        clock: () => testNow,
        statsInterval: const Duration(days: 1),
      );

  test('waits for the broadcaster, then plays its video', () async {
    final bridge = FakeBridge();
    final watch = viewer(bridge, hostUserId: 'host_1');
    await watch.start();
    expect(bridge.joinArguments, containsPair('host', false));
    expect(bridge.joinArguments, containsPair('hostUserId', 'host_1'));
    expect(bridge.joinArguments, containsPair('roomId', 'room-1'));
    expect(bridge.joinArguments, containsPair('userName', 'viewer_1'));
    // Viewers only play: no permission prompt.
    expect(bridge.calls.where((c) => c.startsWith('permissions')), isEmpty);
    expect(watch.state, NosmaiLiveState.waitingForHost);
    expect(watch.hasVideo, isFalse);

    bridge.emit({'type': 'remoteVideo', 'streamId': 's1', 'userId': 'host_1', 'userName': 'Host', 'on': true});
    expect(watch.state, NosmaiLiveState.live);
    expect(watch.hasVideo, isTrue);
    expect(watch.watchingUserName, 'Host');
    expect(watch.watchingUserId, 'host_1');
    expect(watch.watchingStreamId, 's1');

    bridge.emit({'type': 'remoteVideo', 'streamId': null, 'userId': null, 'userName': null, 'on': false});
    expect(watch.state, NosmaiLiveState.waitingForHost);

    watch.setSpeakerMuted(true);
    await Future<void>.delayed(Duration.zero);
    expect(bridge.calls, contains('speaker:true'));

    await watch.stop();
    expect(bridge.calls, contains('leave:false'));
    expect(watch.state, NosmaiLiveState.stopped);
  });

  test('passes the stream to watch', () async {
    final bridge = FakeBridge();
    final watch = viewer(bridge, session: const NosmaiLiveSession('room-1', streamId: 'main_stream'));
    await watch.start();
    expect(bridge.joinArguments, containsPair('streamId', 'main_stream'));
    await watch.stop();
  });

  test('stops cleanly when the broadcaster ends the live', () async {
    final bridge = FakeBridge();
    final watch = viewer(bridge);
    await watch.start();
    bridge.emit({'type': 'left', 'reason': 'EndByHost'});
    await Future<void>.delayed(Duration.zero);
    expect(watch.state, NosmaiLiveState.stopped);
    expect(watch.endedByHost, isTrue);
    expect(watch.error, isNull);
  });

  test('rejects a user ID with spaces', () async {
    final bridge = FakeBridge();
    await expectLater(viewer(bridge, userId: 'viewer one').start(),
        throwsA(isA<NosmaiLiveException>().having((e) => e.code, 'code', 'invalid_credentials')));
    expect(bridge.calls, isNot(contains('join')));
  });

  test('non-fatal errors become warnings and reconnects are reported', () async {
    final bridge = FakeBridge();
    final watch = viewer(bridge);
    await watch.start();
    bridge.emit({'type': 'warning', 'message': 'Playing retry'});
    expect(watch.warning, 'Playing retry');
    expect(watch.state, NosmaiLiveState.waitingForHost);
    bridge.emit({'type': 'reconnecting'});
    expect(watch.state, NosmaiLiveState.reconnecting);
    bridge.emit({'type': 'reconnected'});
    expect(watch.state, NosmaiLiveState.waitingForHost);
    await watch.stop();
  });
}
