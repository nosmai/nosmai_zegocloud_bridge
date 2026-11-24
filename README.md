# Nosmai ZEGOCLOUD Bridge for Flutter

Publish a camera with Nosmai beauty effects, makeup and filters to a ZEGOCLOUD room on Android and iOS. If your app already uses ZEGO Express, the bridge supplies video to the main publishing channel. Your app keeps its engine, room login, audio and remote player.

## Install

Add the bridge to your Flutter app's `pubspec.yaml` and run `flutter pub get`.

```yaml
dependencies:
  zego_express_engine: 3.21.0
  nosmai_zegocloud_live:
    git:
      url: https://github.com/nosmai/nosmai_zegocloud_bridge.git
      path: packages/nosmai_zegocloud_live
```

Use Flutter 3.29 or later. The host needs a physical Android device with API 24+ and OpenGL ES 3.0, or an iPhone with iOS 15+. For iOS builds, use CocoaPods and add camera and microphone usage descriptions to the app's `Info.plist`. Obtain a Nosmai license for each platform's application identifier.

## Use your existing ZEGO engine

1. Request permissions and initialize Nosmai before mounting the host's camera view. On Android, initializing through the bridge first enables shared-texture capture.

```dart
import 'package:nosmai_zegocloud_live/nosmai_zegocloud_live.dart';

Future<bool> prepareHost(String androidKey, String iosKey) async {
  final permissions = await NosmaiZegoCloudLive.requestPermissions();
  if (!permissions.allGranted) return false;

  await NosmaiZegoCloudLive.initialize(
    androidLicenseKey: androidKey,
    iosLicenseKey: iosKey,
  );
  return true;
}
```

2. Once `prepareHost` returns true, show `NosmaiCameraPreview` in place of the host's ZEGO camera view. Enable the **Go live** button when its `onInitialized` callback fires. The host can now preview effects locally.
3. After your existing `createEngineWithProfile` completes, insert the following call **before room login or publishing**. Use the Nosmai widget for local preview and remove the host's ZEGO `startPreview` call. Only one component can own the engine's custom capture handler at a time.

```dart
await NosmaiZegoCloudLive.attachCamera();
```

4. Use your existing `loginRoom` and `startPublishingStream` calls. Viewers keep their existing `startPlayingStream` flow. Effects applied through `NosmaiZegoCloudLive.effects` appear in the local preview and the published stream.
5. On exit, stop publishing, stop any ZEGO local preview your app started, and log out. Then call `await NosmaiZegoCloudLive.detachCamera()` before reusing or destroying the engine. Also detach if startup fails after attachment. When closing the Nosmai preview, call `await NosmaiZegoCloudLive.effects.endCameraSession()`.

## Run the example

The [example app](lib/main.dart) at the repository root includes a [host](lib/src/host_page.dart) and a [viewer](lib/src/viewer_page.dart). It uses the bridge-managed room helpers. The Android application ID and iOS bundle ID are both `com.nosmai.zegocloudbridge.example`.

```sh
cp config/local.example.json config/local.json
```

Enter your Nosmai license, ZEGO AppID and test AppSign or user token in `config/local.json`. For iOS, select your development team in Xcode. Run from the repository root on each device.

```sh
flutter pub get
flutter run --dart-define-from-file=config/local.json
```

Choose **Host** on one device and **Viewer** on the other. Use the same room and distinct user IDs. When using tokens, supply a token issued for each participant's user ID. Production apps should obtain tokens from their backend and keep the ZEGO ServerSecret there.

## Known limitation

In a fixed-portrait test with an iOS host, smoothing was visible on the Android viewer. Setting smoothing back to zero did not consistently restore the original skin texture in that test.

See the [package guide](packages/nosmai_zegocloud_live/README.md) for the two integration options.
