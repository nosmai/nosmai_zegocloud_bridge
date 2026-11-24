import 'package:nosmai_zegocloud_live/nosmai_zegocloud_live.dart';

/// Build-time configuration of this example (`--dart-define-from-file=config/local.json`).
///
/// ZEGOCLOUD's AppSign authentication puts the AppID and AppSign in the app.
/// For production, enable token authentication in the ZEGOCLOUD console and
/// issue Token04 tokens from your server with the ServerSecret, which never
/// goes into the app.
class AppConfig {
  const AppConfig({
    this.nosmaiLicenseKey = '',
    this.nosmaiIosLicenseKey = '',
    this.zegoAppId = '',
    this.zegoAppSign = '',
    this.zegoToken = '',
    this.roomId = 'nosmai-live',
    this.autoRole = '',
    this.autoStopSeconds = 0,
  });

  const AppConfig.fromEnvironment()
      : nosmaiLicenseKey = const String.fromEnvironment('NOSMAI_LICENSE_KEY'),
        nosmaiIosLicenseKey = const String.fromEnvironment('NOSMAI_IOS_LICENSE_KEY'),
        zegoAppId = const String.fromEnvironment('ZEGO_APP_ID'),
        zegoAppSign = const String.fromEnvironment('ZEGO_APP_SIGN'),
        zegoToken = const String.fromEnvironment('ZEGO_TOKEN'),
        roomId = const String.fromEnvironment('ZEGO_ROOM_ID', defaultValue: 'nosmai-live'),
        autoRole = const String.fromEnvironment('AUTO_ROLE'),
        autoStopSeconds = const int.fromEnvironment('AUTO_STOP_SECONDS');

  /// Nosmai key for Android (bound to the applicationId).
  final String nosmaiLicenseKey;

  /// Nosmai key for iOS (bound to the bundle identifier). Empty: [nosmaiLicenseKey] is used.
  final String nosmaiIosLicenseKey;

  String get iosLicenseKey => nosmaiIosLicenseKey.isNotEmpty ? nosmaiIosLicenseKey : nosmaiLicenseKey;

  /// ZEGOCLOUD console → Project Configuration → AppID.
  final String zegoAppId;

  /// ZEGOCLOUD console → Project Configuration → AppSign (64 hex characters).
  final String zegoAppSign;

  /// Optional Token04 for one user ID (development only; tokens are per user).
  final String zegoToken;

  final String roomId;

  /// Test automation (`--dart-define=AUTO_ROLE=host|viewer`): opens that screen at launch, a host
  /// also starts the live, and state and stats are printed every 3 seconds.
  /// `AUTO_STOP_SECONDS` makes the host stop its live that many seconds after it went live.
  final String autoRole;
  final int autoStopSeconds;

  int get appId => int.tryParse(zegoAppId.trim()) ?? 0;

  NosmaiLiveCredentials credentials({required String userId, String? userName}) => NosmaiLiveCredentials(
        appId: appId,
        appSign: zegoAppSign.trim(),
        token: zegoToken.trim(),
        userId: userId,
        userName: userName,
      );

  /// A problem with the build-time ZEGOCLOUD settings, or null.
  String? problem() {
    if (appId <= 0) return 'ZEGO_APP_ID is missing from config/local.json.';
    return credentials(userId: 'check').validate();
  }
}

/// A ZEGOCLOUD user ID made from a display name: no spaces, allowed characters only.
String userIdFor(String name) {
  final cleaned = name.trim().replaceAll(RegExp(r"[^A-Za-z0-9_\-]"), '_');
  return cleaned.isEmpty ? 'user' : (cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned);
}
