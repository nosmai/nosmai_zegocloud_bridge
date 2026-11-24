import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosmai_zegocloud_live/nosmai_zegocloud_live.dart';
import 'package:nosmai_zegocloud_live/src/native_bridge.dart';
import 'package:zego_express_engine/zego_express_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('attaching the camera leaves engine and room management with the host',
      () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const camera = MethodChannel('nosmai_zegocloud_live');
    const effects = MethodChannel('nosmai_camera_sdk');
    const engine = MethodChannel('plugins.zego.im/zego_express_engine');
    const events = MethodChannel('plugins.zego.im/zego_express_event_handler');
    final cameraCalls = <String>[];
    final engineCalls = <String>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(camera, (call) async {
      cameraCalls.add(call.method);
      return call.method == 'prepare' ? {'sharedContext': false} : null;
    });
    messenger.setMockMethodCallHandler(effects,
        (call) async => call.method == 'initWithLicense' ? true : null);
    messenger.setMockMethodCallHandler(engine, (call) async {
      engineCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    addTearDown(() async {
      await ZegoExpressEngine.destroyEngine();
      for (final channel in [camera, effects, engine, events]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
      debugDefaultTargetPlatformOverride = null;
      NosmaiZegoCloudLive.resetForTesting();
    });

    await NosmaiZegoCloudLive.initialize(iosLicenseKey: 'test-license');
    await expectLater(
        NosmaiZegoCloudLive.attachCamera(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'engine_missing'),
        ));
    await ZegoExpressEngine.createEngineWithProfile(
        ZegoEngineProfile(1, ZegoScenario.Broadcast));
    engineCalls.clear();
    await expectLater(
        const NativeBridge().join({}),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'engine_in_use'),
        ));
    for (var session = 0; session < 2; session++) {
      await NosmaiZegoCloudLive.attachCamera();
      await NosmaiZegoCloudLive.detachCamera();
    }
    expect(cameraCalls, [
      'prepare',
      'attachCamera',
      'detachCamera',
      'attachCamera',
      'detachCamera'
    ]);
    expect(engineCalls, isEmpty);
  });
}
