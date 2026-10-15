import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models.dart';

/// The token pair of the signed-in session. Always replaced as a whole: the backend rotates the
/// refresh token on every refresh, and an old one must never be presented again.
class StoredSession {
  const StoredSession({
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
  });

  factory StoredSession.fromPair(TokenPair pair) => StoredSession(
        accessToken: pair.accessToken,
        accessTokenExpiresAt: pair.accessTokenExpiresAt,
        refreshToken: pair.refreshToken,
        refreshTokenExpiresAt: pair.refreshTokenExpiresAt,
      );

  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String refreshToken;
  final DateTime refreshTokenExpiresAt;

  bool accessTokenExpired(DateTime now, {Duration skew = const Duration(seconds: 30)}) => !now.isBefore(accessTokenExpiresAt.subtract(skew));

  Map<String, dynamic> _toJson() => {
        'accessToken': accessToken,
        'accessTokenExpiresAt': accessTokenExpiresAt.toUtc().toIso8601String(),
        'refreshToken': refreshToken,
        'refreshTokenExpiresAt': refreshTokenExpiresAt.toUtc().toIso8601String(),
      };

  static StoredSession? _fromJson(Object? json) {
    if (json is! Map) return null;
    final access = json['accessToken'];
    final refresh = json['refreshToken'];
    final accessExpiry = DateTime.tryParse('${json['accessTokenExpiresAt']}');
    final refreshExpiry = DateTime.tryParse('${json['refreshTokenExpiresAt']}');
    if (access is! String || refresh is! String || access.isEmpty || refresh.isEmpty || accessExpiry == null || refreshExpiry == null) {
      return null;
    }
    return StoredSession(accessToken: access, accessTokenExpiresAt: accessExpiry.toUtc(), refreshToken: refresh, refreshTokenExpiresAt: refreshExpiry.toUtc());
  }

  // Tokens must never appear in logs or error text.
  @override
  String toString() => 'StoredSession(accessTokenExpiresAt: $accessTokenExpiresAt)';
}

abstract class TokenStore {
  Future<StoredSession?> read();

  Future<void> write(StoredSession session);

  Future<void> clear();
}

/// Tokens are kept ONLY here: platform secure storage (Android Keystore-backed), one entry that
/// holds the whole pair so that a rotation replaces both tokens in a single write.
class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  static const String storageKey = 'gossy.session.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<StoredSession?> read() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final session = StoredSession._fromJson(jsonDecode(raw));
      if (session == null) await clear();
      return session;
    } on FormatException {
      await clear(); // unreadable entry: treat as signed out
      return null;
    }
  }

  @override
  Future<void> write(StoredSession session) => _storage.write(key: storageKey, value: jsonEncode(session._toJson()));

  @override
  Future<void> clear() => _storage.delete(key: storageKey);
}
