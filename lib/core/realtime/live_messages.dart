/// Server -> app messages of the live channel `gossy.ws.v1`
/// (backend/docs/websocket-contract.md, backend/src/gossy/realtime).
///
/// Parsing is strict, like the REST models: a frame that does not match the contract throws a
/// [FormatException] and is dropped by the caller. Nothing is defaulted or guessed.
library;

import 'dart:convert';

import '../models.dart';

const String liveProtocol = 'gossy.ws.v1';

T _require<T>(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException('Unexpected live message: "$key" is missing or has the wrong type.');
}

T? _optional<T>(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is T) return value;
  throw FormatException('Unexpected live message: "$key" has the wrong type.');
}

DateTime _time(Map<String, dynamic> json, String key) {
  final parsed = DateTime.tryParse(_require<String>(json, key));
  if (parsed == null) throw FormatException('Unexpected live message: "$key" is not a timestamp.');
  return parsed.toUtc();
}

/// The server's clock as sent in `hello`, `heartbeat` and `pong`. It is only used to compare the
/// phone's clock with the server's, so an absent or unreadable value is "not known" (null), not
/// a reason to drop the message.
DateTime? _serverTime(Map<String, dynamic> json) {
  final raw = json['serverTime'];
  return raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
}

/// JSON `true`/`false` are not accepted where the contract says "integer".
int _cursor(Map<String, dynamic> json, String key) {
  final value = _require<int>(json, key);
  if (value < 0) throw FormatException('Unexpected live message: "$key" is negative.');
  return value;
}

/// `alerts[]` of an event: the alerts the backend created from that message (usually none).
/// An entry that is not a contract alert is left out; it does not make the event unusable -
/// the event's reading is still the device's reading.
List<Alert> _alerts(Object? raw) {
  if (raw is! List) return const [];
  final alerts = <Alert>[];
  for (final entry in raw) {
    try {
      alerts.add(Alert.fromJson(asJsonObject(entry)));
    } on FormatException {
      // not a contract alert: nothing is shown from it
    }
  }
  return alerts;
}

sealed class LiveMessage {
  const LiveMessage();

  /// One text frame. Throws [FormatException] for anything that is not a contract message.
  /// A JSON object with a `type` this app does not know becomes [LiveUnknown].
  static LiveMessage parse(String frame) {
    final json = asJsonObject(jsonDecode(frame));
    final type = _require<String>(json, 'type');
    switch (type) {
      case 'hello':
        final heartbeat = _require<num>(json, 'heartbeatIntervalS');
        if (heartbeat <= 0) throw const FormatException('Unexpected live message: heartbeat interval is not positive.');
        return LiveHello(
          protocol: _require<String>(json, 'protocol'),
          latestCursor: _cursor(json, 'latestCursor'),
          heartbeatInterval: Duration(milliseconds: (heartbeat * 1000).round()),
          serverTime: _serverTime(json),
        );
      case 'event':
        final data = json['data'];
        return LiveEvent(
          cursor: _cursor(json, 'cursor'),
          kind: _require<String>(json, 'kind'),
          deviceId: _require<String>(json, 'deviceId'),
          msgId: _require<String>(json, 'msgId'),
          ts: _time(json, 'ts'),
          receivedAt: _time(json, 'receivedAt'),
          data: data == null ? const {} : asJsonObject(data),
          alerts: _alerts(json['alerts']),
        );
      case 'resumed':
        return LiveResumed(cursor: _cursor(json, 'cursor'), replayed: _cursor(json, 'replayed'));
      case 'resync_required':
        return const LiveResyncRequired();
      case 'heartbeat':
        return LiveHeartbeat(serverTime: _serverTime(json));
      case 'pong':
        return LivePong(serverTime: _serverTime(json));
      case 'error':
        return LiveError(code: _require<String>(json, 'code'));
      default:
        return LiveUnknown(type);
    }
  }
}

class LiveHello extends LiveMessage {
  const LiveHello({required this.protocol, required this.latestCursor, required this.heartbeatInterval, this.serverTime});

  final String protocol;
  final int latestCursor;

  /// The server sends a `heartbeat` this often on an otherwise quiet connection.
  final Duration heartbeatInterval;

  /// The server's clock when it sent this message.
  final DateTime? serverTime;
}

/// One ingested device message. [cursor] is the server-assigned, strictly increasing sequence.
class LiveEvent extends LiveMessage {
  const LiveEvent({required this.cursor, required this.kind, required this.deviceId, required this.msgId, required this.ts, required this.receivedAt, required this.data, this.alerts = const []});

  static const String telemetry = 'telemetry';
  static const String pest = 'event/pest';
  static const String spray = 'event/spray';
  static const String status = 'status';

  final int cursor;

  /// `telemetry`, `event/pest`, `event/spray`, `event/harvest` or `status`.
  final String kind;
  final String deviceId;
  final String msgId;

  /// Device timestamp.
  final DateTime ts;

  /// When the backend received the message.
  final DateTime receivedAt;

  /// The validated MQTT `data` object. Fields the device did not send are absent.
  final Map<String, dynamic> data;

  /// Alerts the backend created from this message, with the same fields as GET /alerts.
  final List<Alert> alerts;

  /// Telemetry fields of the MQTT contract (bollbot.telemetry/1). The backend rejects a
  /// telemetry message that has none of them, so an event without any is not a real reading.
  static const telemetryFields = {
    'batteryPct', 'moistureRhPct', 'airTempC', 'bollsHarvestedTotal', 'solarActive',
    'airRhPct', 'dewpointC', 'fps', 'outboxPending',
  };

  /// The same row GET /devices/{id}/telemetry returns for this message.
  TelemetryPoint toTelemetry() {
    if (!telemetryFields.any((k) => data[k] != null)) {
      throw const FormatException('Unexpected live message: telemetry without any reading.');
    }
    _optional<num>(data, 'fps');
    _optional<int>(data, 'outboxPending');
    return TelemetryPoint(
      time: ts,
      msgId: msgId,
      batteryPct: _optional<num>(data, 'batteryPct')?.toDouble(),
      moistureRhPct: _optional<num>(data, 'moistureRhPct')?.toDouble(),
      airTempC: _optional<num>(data, 'airTempC')?.toDouble(),
      bollsHarvestedTotal: _optional<int>(data, 'bollsHarvestedTotal'),
      solarActive: _optional<bool>(data, 'solarActive'),
      airRhPct: _optional<num>(data, 'airRhPct')?.toDouble(),
      dewpointC: _optional<num>(data, 'dewpointC')?.toDouble(),
      receivedAt: receivedAt,
    );
  }

  /// The same row GET /detections returns for this message.
  Detection toDetection() => Detection(
        id: msgId,
        deviceId: deviceId,
        detectedAt: ts,
        label: _require<String>(data, 'label'),
        confidence: _require<num>(data, 'confidence').toDouble(),
      );

  /// The same row GET /devices/{id}/events?type=spray returns for this message.
  SprayRecord toSpray() => SprayRecord(msgId: msgId, deviceId: deviceId, time: ts, durationMs: sprayDurationMs(data));

  /// `online` or `offline`, as the device (or the broker's Last Will) reported it.
  String toConnectionState() {
    final state = _require<String>(data, 'state');
    if (state != 'online' && state != 'offline') throw const FormatException('Unexpected live message: unknown connection state.');
    return state;
  }
}

/// The stream is live: after `start` ([replayed] is 0) or after a `resume` replay.
class LiveResumed extends LiveMessage {
  const LiveResumed({required this.cursor, required this.replayed});
  final int cursor;
  final int replayed;
}

/// Too many events were missed to replay them: state must be reloaded over REST.
class LiveResyncRequired extends LiveMessage {
  const LiveResyncRequired();
}

class LiveHeartbeat extends LiveMessage {
  const LiveHeartbeat({this.serverTime});

  /// The server's clock when it sent this message.
  final DateTime? serverTime;
}

class LivePong extends LiveMessage {
  const LivePong({this.serverTime});
  final DateTime? serverTime;
}

class LiveError extends LiveMessage {
  const LiveError({required this.code});

  static const String tokenExpired = 'token_expired';
  static const String sessionRevoked = 'session_revoked';
  static const String invalidCursor = 'invalid_cursor';

  final String code;
}

class LiveUnknown extends LiveMessage {
  const LiveUnknown(this.type);
  final String type;
}
