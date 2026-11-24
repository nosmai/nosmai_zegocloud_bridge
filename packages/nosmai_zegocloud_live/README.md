# Nosmai ZEGOCLOUD Live

Flutter bridge for sending the Nosmai camera to ZEGO Express on Android and iOS. The package re-exports the Nosmai Flutter effects API and provides two ways to publish.

## Existing ZEGO app

Initialize with `NosmaiZegoCloudLive.initialize` and show `NosmaiCameraPreview` on the host. Create the ZEGO engine as usual, then call `NosmaiZegoCloudLive.attachCamera()` before room login, local ZEGO preview or publishing. Use your existing publisher, remote player, audio and room callbacks. On exit, stop publishing and log out before calling `detachCamera()`. Detach before destroying the engine.

The bridge takes ownership of the engine's custom capture handler for the main publishing channel. If your app already provides custom video capture, release that source before attaching Nosmai. [Installation, permissions and complete setup](../../README.md)

## Bridge-managed room

For a new streaming screen, use `NosmaiLiveBroadcaster` on the host and `NosmaiLiveViewer` with `NosmaiLiveViewerView` on the viewer. These helpers manage their own ZEGO session. Choose one engine owner for a given session.

- [Host example with local preview and effects](../../lib/src/host_page.dart)
- [Viewer example with remote video and session state](../../lib/src/viewer_page.dart)
- [Example configuration](../../config/local.example.json)
