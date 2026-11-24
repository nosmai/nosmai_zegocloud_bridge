import 'dart:convert';
import 'dart:typed_data';

/// A ZEGOCLOUD room, and optionally the stream to publish or watch in it.
///
/// Everyone who logs in to the same [roomId] (with the same AppID) meets in
/// the same room. ZEGOCLOUD creates the room on the first login.
class NosmaiLiveSession {
  const NosmaiLiveSession(this.roomId, {this.streamId});

  /// Up to 127 bytes: letters, digits and ``~!@#$%^&*()_+=-`;',.<>\``.
  final String roomId;

  /// Broadcaster: the stream ID to publish; when null it is made from the room
  /// and user ID (see [streamIdFor]). Viewer: the stream to watch; when null
  /// the viewer watches the first broadcaster in the room.
  ///
  /// Stream IDs are unique across the whole AppID, up to 255 characters of
  /// letters, digits, `-` and `_`.
  final String? streamId;

  /// The stream a broadcaster with [userId] publishes in this room.
  String streamIdFor(String userId) {
    final explicit = streamId;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final made = '${roomId}_$userId'.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return made.length > 255 ? made.substring(0, 255) : made;
  }

  /// A human-readable problem, or null when the values are usable.
  String? validate() {
    if (roomId.trim().isEmpty) return 'The room ID is empty.';
    if (utf8.encode(roomId).length > 127) return 'The room ID must be shorter than 128 bytes.';
    if (!_roomOrUserId.hasMatch(roomId)) {
      return 'The room ID may only contain letters, digits and ~!@#\$%^&*()_+=-`;\',.<>\\.';
    }
    final stream = streamId;
    if (stream != null && stream.isNotEmpty) {
      if (stream.length > 255) return 'The stream ID must be at most 255 characters.';
      if (!_streamId.hasMatch(stream)) return 'The stream ID may only contain letters, digits, - and _.';
    }
    return null;
  }

  @override
  String toString() => 'room "$roomId"${streamId == null ? '' : ' stream "$streamId"'}';

  @override
  bool operator ==(Object other) =>
      other is NosmaiLiveSession && other.roomId == roomId && other.streamId == streamId;

  @override
  int get hashCode => Object.hash(roomId, streamId);
}

final _roomOrUserId = RegExp(r"^[A-Za-z0-9~!@#$%^&*()_+=\-`;',.<>\\]+$");
final _streamId = RegExp(r'^[A-Za-z0-9_-]+$');
final _appSign = RegExp(r'^[0-9a-fA-F]{64}$');

/// ZEGOCLOUD identity for one participant.
///
/// [appId] and [appSign] come from the project in the ZEGOCLOUD console
/// (Project Configuration → Basic Configurations). Pass a [token] instead of
/// (or as well as) [appSign] when the project uses token authentication; the
/// token is a Token04 issued by **your server** with the ServerSecret. Never
/// ship the ServerSecret inside a mobile app.
class NosmaiLiveCredentials {
  const NosmaiLiveCredentials({
    required this.appId,
    this.appSign = '',
    this.token = '',
    required this.userId,
    String? userName,
  }) : _userName = userName;

  final int appId;

  /// The project's 64-character hexadecimal AppSign.
  final String appSign;

  /// Optional Token04 for this [userId].
  final String token;

  /// Unique per person across the AppID: a second login with the same ID
  /// signs the first one out. Up to 63 bytes, same characters as a room ID.
  final String userId;

  final String? _userName;

  /// The name other participants see; [userId] when not given.
  String get userName {
    final name = _userName?.trim() ?? '';
    return name.isEmpty ? userId : name;
  }

  /// A human-readable problem, or null when the credentials are usable.
  String? validate({DateTime? now}) {
    if (appId <= 0) return 'The ZEGOCLOUD AppID is missing.';
    if (appSign.isEmpty && token.trim().isEmpty) {
      return 'Pass the ZEGOCLOUD AppSign or a token issued by your server.';
    }
    if (appSign.isNotEmpty && !_appSign.hasMatch(appSign)) {
      return 'The AppSign must be the 64 hexadecimal characters shown in the ZEGOCLOUD console.';
    }
    if (userId.trim().isEmpty) return 'The user ID is empty.';
    if (utf8.encode(userId).length > 63) return 'The user ID must be shorter than 64 bytes.';
    if (!_roomOrUserId.hasMatch(userId)) {
      return 'The user ID may only contain letters, digits and ~!@#\$%^&*()_+=-`;\',.<>\\ (no spaces).';
    }
    if (utf8.encode(userName).length > 255) return 'The user name must be shorter than 256 bytes.';
    if (token.trim().isNotEmpty) return NosmaiZegoToken.problemFor(token, now: now);
    return null;
  }

  @override
  String toString() => 'NosmaiLiveCredentials(appId: $appId, userId: $userId)';
}

/// The readable part of a ZEGOCLOUD Token04: its expiry. The rest is encrypted
/// with the ServerSecret, so only ZEGOCLOUD can check it.
class NosmaiZegoToken {
  const NosmaiZegoToken({required this.expiresAt});

  final DateTime expiresAt;

  /// Decodes [token], or returns null when it is not a Token04.
  static NosmaiZegoToken? tryParse(String token) {
    final trimmed = token.trim();
    if (!trimmed.startsWith('04') || trimmed.length < 14) return null;
    try {
      final bytes = base64.decode(base64.normalize(trimmed.substring(2)));
      if (bytes.length < 8) return null;
      final seconds = ByteData.sublistView(Uint8List.fromList(bytes), 0, 8).getInt64(0);
      if (seconds <= 0) return null;
      return NosmaiZegoToken(expiresAt: DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true));
    } catch (_) {
      return null;
    }
  }

  /// A human-readable problem with [token], or null.
  static String? problemFor(String token, {DateTime? now}) {
    final info = tryParse(token);
    if (info == null) return 'The token is not a ZEGOCLOUD Token04 (it should start with "04").';
    if (!info.expiresAt.isAfter(now ?? DateTime.now())) {
      return 'The token expired at ${info.expiresAt.toLocal()}. Issue a new one.';
    }
    return null;
  }
}
