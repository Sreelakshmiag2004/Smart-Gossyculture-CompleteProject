import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:smart_gossy_culture_app/core/app_config.dart';
import 'package:smart_gossy_culture_app/core/app_services.dart';
import 'package:smart_gossy_culture_app/core/auth/token_store.dart';

import 'fake_live.dart';

/// In-memory [TokenStore] for tests (the real one needs the platform plugin).
class MemoryTokenStore implements TokenStore {
  StoredSession? session;
  int writes = 0;
  int clears = 0;

  @override
  Future<StoredSession?> read() async => session;

  @override
  Future<void> write(StoredSession value) async {
    session = value;
    writes++;
  }

  @override
  Future<void> clear() async {
    session = null;
    clears++;
  }
}

class RecordedCall {
  RecordedCall(this.method, this.path, this.body, this.authorization, [this.query = const {}]);
  final String method;
  final String path;
  final Object? body;
  final String? authorization;
  final Map<String, String> query;

  @override
  String toString() => '$method $path';
}

class FakeReply {
  const FakeReply(this.status, [this.json, this.headers = const {}]);
  final int status;
  final Object? json;
  final Map<String, String> headers;

  static FakeReply error(int status, String code, {Map<String, String> headers = const {}}) =>
      FakeReply(status, {'error': {'code': code, 'message': 'backend message that must never be shown', 'requestId': 'req-test'}}, headers);
}

enum Outage { none, offline, timeout }

/// A stand-in for the Phase 2 backend that follows its documented contract for the endpoints the
/// app uses in Phase 3A (sign-in, refresh with rotation and reuse detection, logout, profile,
/// farms, devices, claim). It is test code only: the sign-in code below belongs to this fake.
class FakeBackend implements HttpClientAdapter {
  static const String allowedPhone = '+99900000001';

  /// The code this FAKE accepts. The app under test never contains it; tests type it in.
  String currentCode = '424242';

  final List<RecordedCall> calls = [];
  Outage outage = Outage.none;

  /// path -> reply, consulted before the normal behaviour (to force errors).
  final Map<String, FakeReply> overrides = {};

  /// Artificial latency of the refresh endpoint (to observe concurrent callers).
  Duration refreshDelay = Duration.zero;

  /// Artificial latency of every reply (to observe loading states).
  Duration latency = Duration.zero;

  // ---- state
  bool challengeIssued = false;
  bool sessionRevoked = false;
  int _serial = 0;
  String? _validAccess;
  String? _validRefresh;
  final Set<String> _usedRefresh = {};
  final List<Map<String, Object?>> farms = [];
  final List<Map<String, Object?>> devices = [];

  /// deviceId -> claim code of provisioned (claimable) devices.
  final Map<String, String> claimable = {};

  /// deviceId -> telemetry rows, newest first (GET /devices/{id}/telemetry).
  final Map<String, List<Map<String, Object?>>> telemetry = {};

  /// deviceId -> detections, newest first (GET /detections?deviceId=).
  final Map<String, List<Map<String, Object?>>> detections = {};

  /// A device row as the backend returns it.
  /// [telemetryIntervalS] / [telemetryStaleAfterS] (Phase 5A) are sent only when given: a
  /// device row without them is what a backend from before Phase 5A returns.
  static Map<String, Object?> device(String deviceId, {String farmId = 'farm-1', String? displayName, String? state, String? lastSeenAt, String claimedAt = '2026-10-01T00:00:00Z', int? telemetryIntervalS, int? telemetryStaleAfterS}) => {
        'deviceId': deviceId, 'displayName': displayName, 'farmId': farmId, 'registrationState': 'active',
        'registeredAt': '2026-09-30T00:00:00Z', 'claimedAt': claimedAt,
        'status': {'state': state, 'stateAt': lastSeenAt, 'lastSeenAt': lastSeenAt},
        if (telemetryIntervalS != null) 'telemetryIntervalS': telemetryIntervalS,
        if (telemetryStaleAfterS != null) 'telemetryStaleAfterS': telemetryStaleAfterS,
      };

  /// [receivedAt] (Phase 5A) is sent only when given.
  static Map<String, Object?> telemetryRow({required String time, required num batteryPct, num? moistureRhPct, num? airTempC, int? bollsHarvestedTotal, bool? solarActive, String msgId = '01K6CQ4W0D8V9J4Q9W2Y1S7ZPX', String? receivedAt}) => {
        'time': time, 'msgId': msgId, 'batteryPct': batteryPct, 'moistureRhPct': moistureRhPct,
        'airTempC': airTempC, 'bollsHarvestedTotal': bollsHarvestedTotal, 'solarActive': solarActive,
        if (receivedAt != null) 'receivedAt': receivedAt,
      };

  static Map<String, Object?> detectionRow({required String deviceId, required String detectedAt, required String label, required num confidence, String id = '01K6CQ4W0D8V9J4Q9W2Y1S7ZPY'}) => {
        'id': id, 'deviceId': deviceId, 'detectedAt': detectedAt, 'label': label,
        'confidence': confidence, 'bbox': null, 'source': 'upstream_device_detector',
      };

  /// deviceId -> pest, spray and harvest events, newest first (GET /devices/{id}/events). Phase 5C.
  final Map<String, List<Map<String, Object?>>> events = {};

  /// A spray event as the backend returns it (`DeviceEvent`, backend/src/gossy/telemetry/schemas.py).
  static Map<String, Object?> sprayRow({required String deviceId, required String time, required String msgId, Object? durationMs = 1500, String? relatedMsgId}) => {
        'time': time, 'msgId': msgId, 'deviceId': deviceId, 'type': 'spray',
        'data': {'durationMs': durationMs, if (relatedMsgId != null) 'relatedMsgId': relatedMsgId},
      };

  /// Alerts of the caller's devices, newest first (GET /alerts). Phase 5B.
  final List<Map<String, Object?>> alerts = [];

  /// When the fake acknowledges an alert (POST /alerts/{id}/acknowledge).
  String acknowledgeTime = '2026-10-01T16:00:00Z';

  /// An alert as the backend returns it (backend/src/gossy/alerts/schemas.py).
  static Map<String, Object?> alertRow({
    required String id,
    required String type,
    required String deviceId,
    required String occurredAt,
    String severity = 'warning',
    String status = 'open',
    String? createdAt,
    Map<String, Object?> details = const {},
    String? acknowledgedAt,
  }) => {
        'id': id, 'type': type, 'severity': severity, 'status': status, 'deviceId': deviceId,
        'occurredAt': occurredAt, 'createdAt': createdAt ?? occurredAt, 'sourceMsgId': '01K6CQ4W0D8V9J4Q9W2YSRC${id.hashCode.abs() % 1000}',
        'details': details, 'acknowledgedAt': acknowledgedAt,
      };

  int count(String method, String path) => calls.where((c) => c.method == method && c.path == path).length;

  /// The backend stops accepting the current access token (as if its 15 minutes had passed).
  void expireAccessToken() => _validAccess = null;

  /// Whether an `Authorization` header carries the access token of a session that is still valid
  /// (the check every authenticated endpoint - and the live channel's upgrade - performs).
  bool acceptsAuthorization(String? authorization) => !sessionRevoked && authorization != null && authorization == 'Bearer $_validAccess';

  Map<String, Object?> get _user => {'id': '11111111-1111-1111-1111-111111111111', 'phone': allowedPhone, 'displayName': null, 'role': 'farmer', 'createdAt': '2026-10-01T00:00:00Z', 'lastLoginAt': null};

  Map<String, Object?> _newPair() {
    _serial++;
    _validAccess = 'access-$_serial';
    _validRefresh = 'refresh-token-number-$_serial';
    return {
      'accessToken': _validAccess,
      'accessTokenExpiresAt': '2099-01-01T00:15:00Z',
      'refreshToken': _validRefresh,
      'refreshTokenExpiresAt': '2099-02-01T00:00:00Z',
      'tokenType': 'Bearer',
      'user': _user,
    };
  }

  /// Seeds a signed-in session without going through the UI.
  StoredSession seedSession({DateTime? accessTokenExpiresAt}) {
    final pair = _newPair();
    return StoredSession(
      accessToken: pair['accessToken']! as String,
      accessTokenExpiresAt: accessTokenExpiresAt ?? DateTime.utc(2099, 1, 1, 0, 15),
      refreshToken: pair['refreshToken']! as String,
      refreshTokenExpiresAt: DateTime.utc(2099, 2, 1),
    );
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final path = options.uri.path;
    final call = RecordedCall(options.method, path, options.data, options.headers['Authorization'] as String?, options.uri.queryParameters);
    calls.add(call);
    if (outage == Outage.offline) throw DioException.connectionError(requestOptions: options, reason: 'no route to host');
    if (outage == Outage.timeout) throw DioException.connectionTimeout(timeout: const Duration(seconds: 10), requestOptions: options);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final reply = overrides[path] ?? await _route(call);
    return ResponseBody.fromString(
      reply.json == null ? '' : jsonEncode(reply.json),
      reply.status,
      headers: {
        'content-type': ['application/json'],
        for (final entry in reply.headers.entries) entry.key: [entry.value],
      },
    );
  }

  Future<FakeReply> _route(RecordedCall call) async {
    final body = call.body is Map ? call.body! as Map : const {};
    switch ('${call.method} ${call.path}') {
      case 'POST /api/v1/auth/otp/request':
        // Uniform 202; a challenge exists only for the allow-listed number.
        challengeIssued = body['phone'] == allowedPhone;
        return const FakeReply(202, {'status': 'accepted', 'message': 'If this number can receive codes, a code has been issued.'});
      case 'POST /api/v1/auth/otp/verify':
        if (!challengeIssued || body['phone'] != allowedPhone || body['code'] != currentCode) {
          return FakeReply.error(401, 'invalid_credentials');
        }
        challengeIssued = false; // a code works once
        sessionRevoked = false;
        return FakeReply(200, _newPair());
      case 'POST /api/v1/auth/refresh':
        if (refreshDelay > Duration.zero) await Future<void>.delayed(refreshDelay);
        final token = body['refreshToken'];
        if (_usedRefresh.contains(token)) {
          sessionRevoked = true; // reuse of a rotated token: the whole session is revoked
          _validAccess = null;
          _validRefresh = null;
          return FakeReply.error(401, 'invalid_refresh_token');
        }
        if (sessionRevoked || token != _validRefresh) return FakeReply.error(401, 'invalid_refresh_token');
        _usedRefresh.add(token! as String);
        return FakeReply(200, _newPair());
    }
    // ---- everything below needs a valid access token
    if (!acceptsAuthorization(call.authorization)) {
      return FakeReply.error(401, 'unauthenticated');
    }
    switch ('${call.method} ${call.path}') {
      case 'POST /api/v1/auth/logout':
        sessionRevoked = true;
        return const FakeReply(204);
      case 'GET /api/v1/me':
        return FakeReply(200, _user);
      case 'GET /api/v1/farms':
        return FakeReply(200, farms);
      case 'POST /api/v1/farms':
        final farm = {'id': 'farm-${farms.length + 1}', 'name': body['name'], 'createdAt': '2026-10-01T00:00:00Z'};
        farms.add(farm);
        return FakeReply(201, farm);
      case 'GET /api/v1/devices':
        return FakeReply(200, devices);
      case 'POST /api/v1/devices/claim':
        if (!farms.any((f) => f['id'] == body['farmId'])) return FakeReply.error(404, 'not_found');
        final deviceId = body['deviceId'];
        if (claimable[deviceId] == null || claimable[deviceId] != body['claimCode']) return FakeReply.error(404, 'claim_failed');
        claimable.remove(deviceId);
        final device = {
          'deviceId': deviceId, 'displayName': null, 'farmId': body['farmId'], 'registrationState': 'active',
          'registeredAt': '2026-10-01T00:00:00Z', 'claimedAt': '2026-10-01T00:00:00Z',
          'status': {'state': null, 'stateAt': null, 'lastSeenAt': null},
        };
        devices.add(device);
        return FakeReply(200, device);
      case 'GET /api/v1/detections':
        // Only the caller's devices are readable; anything else is "not found".
        final deviceId = call.query['deviceId'];
        if (!devices.any((d) => d['deviceId'] == deviceId)) return FakeReply.error(404, 'not_found');
        return FakeReply(200, _page(detections[deviceId] ?? const [], call.query));
    }
    // Alerts: only those of the caller's devices; filters and keyset paging as in the contract
    // (the fake's cursor is simply the offset of the next row).
    if (call.method == 'GET' && call.path == '/api/v1/alerts') {
      final rows = alerts.where((a) => devices.any((d) => d['deviceId'] == a['deviceId'])).where((a) => call.query['status'] == null || a['status'] == call.query['status']).where((a) => call.query['deviceId'] == null || a['deviceId'] == call.query['deviceId']).toList();
      final limit = int.tryParse(call.query['limit'] ?? '') ?? 100;
      final offset = int.tryParse(call.query['cursor'] ?? '') ?? 0;
      final end = offset + limit;
      return FakeReply(200, {'items': rows.skip(offset).take(limit).toList(), 'nextCursor': rows.length > end ? '$end' : null});
    }
    final acknowledgePath = RegExp(r'^/api/v1/alerts/([^/]+)/acknowledge$').firstMatch(call.path);
    if (call.method == 'POST' && acknowledgePath != null) {
      final id = Uri.decodeComponent(acknowledgePath.group(1)!);
      final index = alerts.indexWhere((a) => a['id'] == id && devices.any((d) => d['deviceId'] == a['deviceId']));
      if (index < 0) return FakeReply.error(404, 'not_found');
      // Idempotent: an alert that is already acknowledged is returned unchanged.
      if (alerts[index]['status'] == 'open') alerts[index] = {...alerts[index], 'status': 'acknowledged', 'acknowledgedAt': acknowledgeTime};
      return FakeReply(200, alerts[index]);
    }
    final eventsPath = RegExp(r'^/api/v1/devices/([^/]+)/events$').firstMatch(call.path);
    if (call.method == 'GET' && eventsPath != null) {
      final deviceId = Uri.decodeComponent(eventsPath.group(1)!);
      if (!devices.any((d) => d['deviceId'] == deviceId)) return FakeReply.error(404, 'not_found');
      final type = call.query['type'];
      return FakeReply(200, _page((events[deviceId] ?? const []).where((e) => type == null || e['type'] == type).toList(), call.query));
    }
    final telemetryPath = RegExp(r'^/api/v1/devices/([^/]+)/telemetry$').firstMatch(call.path);
    if (call.method == 'GET' && telemetryPath != null) {
      final deviceId = Uri.decodeComponent(telemetryPath.group(1)!);
      if (!devices.any((d) => d['deviceId'] == deviceId)) return FakeReply.error(404, 'not_found');
      return FakeReply(200, _page(telemetry[deviceId] ?? const [], call.query));
    }
    return FakeReply.error(404, 'not_found');
  }

  /// Newest-first paging as in the contract. The fake's opaque cursor is "after-<offset>".
  Map<String, Object?> _page(List<Map<String, Object?>> rows, Map<String, String> query) {
    final limit = int.tryParse(query['limit'] ?? '') ?? 100;
    final offset = int.tryParse((query['cursor'] ?? '').replaceFirst('after-', '')) ?? 0;
    final end = offset + limit;
    return {'items': rows.skip(offset).take(limit).toList(), 'nextCursor': rows.length > end ? 'after-$end' : null};
  }

  @override
  void close({bool force = false}) {}
}

class TestApp {
  TestApp({DateTime Function()? clock, Random? random}) {
    live = FakeLiveServer(backend);
    services = AppServices.create(config: AppConfig(apiBaseUrl: Uri.parse('https://backend.test')), tokens: tokens, adapter: backend, clock: clock, liveConnector: live.connect, random: random);
  }

  final FakeBackend backend = FakeBackend();
  final MemoryTokenStore tokens = MemoryTokenStore();

  /// The live channel of [backend] (see fake_live.dart).
  late final FakeLiveServer live;
  late final AppServices services;

  /// Puts a valid signed-in session into the store.
  void signIn({DateTime? accessTokenExpiresAt}) => tokens.session = backend.seedSession(accessTokenExpiresAt: accessTokenExpiresAt);
}
