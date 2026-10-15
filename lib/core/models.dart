/// Models for the backend contract (backend/docs/openapi.json). Only what authentication and
/// onboarding need. Parsing is strict: a response that does not match the contract throws a
/// [FormatException], which callers turn into an "unexpected response" failure.
library;

T _require<T>(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException('Unexpected response: "$key" is missing or has the wrong type.');
}

DateTime _time(Map<String, dynamic> json, String key) {
  final parsed = DateTime.tryParse(_require<String>(json, key));
  if (parsed == null) throw FormatException('Unexpected response: "$key" is not a timestamp.');
  return parsed.toUtc();
}

Map<String, dynamic> asJsonObject(Object? data) {
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return data.map((key, value) => MapEntry(key.toString(), value));
  throw const FormatException('Unexpected response: not a JSON object.');
}

List<Map<String, dynamic>> asJsonList(Object? data) {
  if (data is List) return data.map(asJsonObject).toList();
  throw const FormatException('Unexpected response: not a JSON list.');
}

class UserProfile {
  const UserProfile({required this.id, required this.phone, required this.role, this.displayName});

  final String id;
  final String phone;
  final String role;
  final String? displayName;

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: _require<String>(json, 'id'),
        phone: _require<String>(json, 'phone'),
        role: _require<String>(json, 'role'),
        displayName: json['displayName'] as String?,
      );
}

/// Response of POST /api/v1/auth/otp/verify and POST /api/v1/auth/refresh.
class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
    required this.user,
  });

  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String refreshToken;
  final DateTime refreshTokenExpiresAt;
  final UserProfile user;

  factory TokenPair.fromJson(Map<String, dynamic> json) {
    final pair = TokenPair(
      accessToken: _require<String>(json, 'accessToken'),
      accessTokenExpiresAt: _time(json, 'accessTokenExpiresAt'),
      refreshToken: _require<String>(json, 'refreshToken'),
      refreshTokenExpiresAt: _time(json, 'refreshTokenExpiresAt'),
      user: UserProfile.fromJson(asJsonObject(json['user'])),
    );
    if (pair.accessToken.isEmpty || pair.refreshToken.isEmpty) {
      throw const FormatException('Unexpected response: empty token.');
    }
    return pair;
  }

  // Tokens must never appear in logs or error text.
  @override
  String toString() => 'TokenPair(user: ${user.id})';
}

class Farm {
  const Farm({required this.id, required this.name});

  final String id;
  final String name;

  factory Farm.fromJson(Map<String, dynamic> json) => Farm(id: _require<String>(json, 'id'), name: _require<String>(json, 'name'));
}

/// A nullable contract field: absent or null is fine, a wrong type is a contract violation.
T? _optional<T>(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is T) return value;
  throw FormatException('Unexpected response: "$key" has the wrong type.');
}

DateTime? _optionalTime(Map<String, dynamic> json, String key) {
  final raw = _optional<String>(json, key);
  if (raw == null) return null;
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) throw FormatException('Unexpected response: "$key" is not a timestamp.');
  return parsed.toUtc();
}

/// JSON numbers may arrive as int or double; both are accepted where the contract says "number".
double? _optionalNumber(Map<String, dynamic> json, String key) => _optional<num>(json, key)?.toDouble();

/// `Device.status` in the contract: the device's last reported connection state.
class DeviceStatus {
  const DeviceStatus({this.state, this.stateAt, this.lastSeenAt});

  /// `online`, `offline`, or null when the device has never reported a status.
  final String? state;

  /// When the backend received that status.
  final DateTime? stateAt;

  /// When the backend last received any message from the device.
  final DateTime? lastSeenAt;

  factory DeviceStatus.fromJson(Map<String, dynamic> json) => DeviceStatus(
        state: _optional<String>(json, 'state'),
        stateAt: _optionalTime(json, 'stateAt'),
        lastSeenAt: _optionalTime(json, 'lastSeenAt'),
      );
}

class Device {
  const Device({
    required this.deviceId,
    required this.registrationState,
    this.displayName,
    this.farmId,
    this.claimedAt,
    this.status = const DeviceStatus(),
    this.telemetryInterval,
    this.telemetryStaleAfter,
  });

  final String deviceId;
  final String registrationState;
  final String? displayName;
  final String? farmId;
  final DateTime? claimedAt;
  final DeviceStatus status;

  /// How often the device reports telemetry (`telemetryIntervalS`). Null when the backend does
  /// not say.
  final Duration? telemetryInterval;

  /// A reading is no longer current when the backend has received no telemetry for this long
  /// (`telemetryStaleAfterS`). The value is the backend's: nothing in the app defines it. Null
  /// when the backend does not say - then no time rule is applied.
  final Duration? telemetryStaleAfter;

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        deviceId: _require<String>(json, 'deviceId'),
        registrationState: _require<String>(json, 'registrationState'),
        displayName: _optional<String>(json, 'displayName'),
        farmId: _optional<String>(json, 'farmId'),
        claimedAt: _optionalTime(json, 'claimedAt'),
        status: DeviceStatus.fromJson(asJsonObject(json['status'])),
        telemetryInterval: _optionalSeconds(json, 'telemetryIntervalS'),
        telemetryStaleAfter: _optionalSeconds(json, 'telemetryStaleAfterS'),
      );
}

/// A positive whole number of seconds, or null when absent.
Duration? _optionalSeconds(Map<String, dynamic> json, String key) {
  final seconds = _optional<int>(json, key);
  if (seconds == null) return null;
  if (seconds <= 0) throw FormatException('Unexpected response: "$key" is not a positive number of seconds.');
  return Duration(seconds: seconds);
}

/// One row of GET /api/v1/devices/{id}/telemetry. Only `batteryPct` is always present; every
/// other reading is nullable in the contract and null means "no reading", never zero.
class TelemetryPoint {
  const TelemetryPoint({
    required this.time,
    required this.msgId,
    this.batteryPct,
    this.moistureRhPct,
    this.airTempC,
    this.bollsHarvestedTotal,
    this.solarActive,
    this.receivedAt,
  });

  /// Device timestamp of the reading.
  final DateTime time;

  /// When the BACKEND received the reading (`receivedAt`, the same value in the REST row and in
  /// the live event). Freshness is measured from this, never from [time]: a device clock can be
  /// wrong. Null only for a backend that does not send it.
  final DateTime? receivedAt;
  final String msgId;

  /// Battery level in %. Null when the device has no battery monitor (contract: a reading the
  /// device cannot make is omitted, never faked), e.g. a Phase II cart without one.
  final double? batteryPct;

  /// Relative humidity reading in %RH. A reading only: the backend gives no verdict (U-1).
  final double? moistureRhPct;
  final double? airTempC;

  /// Cumulative number of bolls the device reports as harvested.
  final int? bollsHarvestedTotal;
  final bool? solarActive;

  factory TelemetryPoint.fromJson(Map<String, dynamic> json) => TelemetryPoint(
        time: _time(json, 'time'),
        msgId: _require<String>(json, 'msgId'),
        batteryPct: _optionalNumber(json, 'batteryPct'),
        moistureRhPct: _optionalNumber(json, 'moistureRhPct'),
        airTempC: _optionalNumber(json, 'airTempC'),
        bollsHarvestedTotal: _optional<int>(json, 'bollsHarvestedTotal'),
        solarActive: _optional<bool>(json, 'solarActive'),
        receivedAt: _optionalTime(json, 'receivedAt'),
      );
}

/// One row of GET /api/v1/detections: a pest/disease detection REPORTED BY THE DEVICE. The
/// backend performs no inference and applies no threshold.
class Detection {
  const Detection({required this.id, required this.deviceId, required this.detectedAt, required this.label, required this.confidence});

  final String id;
  final String deviceId;
  final DateTime detectedAt;

  /// Class name as reported, e.g. `bollworm`.
  final String label;

  /// 0..1.
  final double confidence;

  factory Detection.fromJson(Map<String, dynamic> json) => Detection(
        id: _require<String>(json, 'id'),
        deviceId: _require<String>(json, 'deviceId'),
        detectedAt: _time(json, 'detectedAt'),
        label: _require<String>(json, 'label'),
        confidence: _require<num>(json, 'confidence').toDouble(),
      );
}

/// One row of GET /api/v1/devices/{id}/events?type=spray: a spray action REPORTED BY THE DEVICE
/// (`DeviceEvent` in the contract, with the `event/spray` payload in `data`). A log entry only:
/// the app cannot start, stop or change a spray.
class SprayRecord {
  const SprayRecord({required this.msgId, required this.deviceId, required this.time, required this.durationMs});

  static const String eventType = 'spray';

  /// Id of the device message - the row's identity, the same in REST and in the live event.
  final String msgId;
  final String deviceId;

  /// Device timestamp of the spray.
  final DateTime time;

  /// How long the device reports it sprayed, in milliseconds (`data.durationMs`).
  final int durationMs;

  factory SprayRecord.fromJson(Map<String, dynamic> json) {
    if (_require<String>(json, 'type') != eventType) throw const FormatException('Unexpected response: not a spray event.');
    return SprayRecord(
      msgId: _require<String>(json, 'msgId'),
      deviceId: _require<String>(json, 'deviceId'),
      time: _time(json, 'time'),
      durationMs: sprayDurationMs(asJsonObject(json['data'])),
    );
  }
}

/// `durationMs` of an `event/spray` payload: a positive whole number of milliseconds.
int sprayDurationMs(Map<String, dynamic> data) {
  final durationMs = _require<int>(data, 'durationMs');
  if (durationMs <= 0) throw const FormatException('Unexpected response: "durationMs" is not positive.');
  return durationMs;
}

/// `Alert` in the contract: one row of GET /api/v1/alerts, the reply of
/// POST /api/v1/alerts/{id}/acknowledge, and one entry of `alerts[]` in a live event - the same
/// object in all three. The backend creates alerts; the app never does.
class Alert {
  const Alert({
    required this.id,
    required this.type,
    required this.severity,
    required this.status,
    required this.deviceId,
    required this.occurredAt,
    required this.createdAt,
    required this.sourceMsgId,
    required this.details,
    this.acknowledgedAt,
  });

  static const String open = 'open';
  static const String acknowledged = 'acknowledged';

  static const String pestDetected = 'pest_detected';
  static const String sprayPerformed = 'spray_performed';
  static const String deviceOffline = 'device_offline';

  final String id;

  /// `pest_detected`, `spray_performed` or `device_offline` today. Kept as sent: a type this
  /// app does not know is shown without an interpretation, not dropped and not guessed.
  final String type;

  /// `info` or `warning`, as the backend set it.
  final String severity;

  /// [open] or [acknowledged]. The backend only ever moves an alert from open to acknowledged.
  final String status;
  final String deviceId;

  /// Device timestamp of the message that produced the alert.
  final DateTime occurredAt;

  /// When the backend created the alert.
  final DateTime createdAt;
  final String sourceMsgId;

  /// What the backend stored with the alert: `label` and `confidence` for a detection,
  /// `durationMs` for a spray, nothing for an offline alert.
  final Map<String, dynamic> details;
  final DateTime? acknowledgedAt;

  bool get isOpen => status == open;
  bool get isAcknowledged => status == acknowledged;

  factory Alert.fromJson(Map<String, dynamic> json) {
    final status = _require<String>(json, 'status');
    if (status != open && status != acknowledged) throw const FormatException('Unexpected response: unknown alert status.');
    return Alert(
      id: _require<String>(json, 'id'),
      type: _require<String>(json, 'type'),
      severity: _require<String>(json, 'severity'),
      status: status,
      deviceId: _require<String>(json, 'deviceId'),
      occurredAt: _time(json, 'occurredAt'),
      createdAt: _time(json, 'createdAt'),
      sourceMsgId: _require<String>(json, 'sourceMsgId'),
      details: asJsonObject(json['details']),
      acknowledgedAt: _optionalTime(json, 'acknowledgedAt'),
    );
  }
}

/// `Page<T>` in the contract: newest first, with an opaque cursor for the next page.
class Page<T> {
  const Page({required this.items, this.nextCursor});

  final List<T> items;
  final String? nextCursor;

  static Page<T> fromJson<T>(Object? data, T Function(Map<String, dynamic>) item) {
    final json = asJsonObject(data);
    return Page<T>(items: asJsonList(json['items']).map(item).toList(), nextCursor: _optional<String>(json, 'nextCursor'));
  }
}
