import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:smart_gossy_culture_app/core/realtime/live_socket.dart';

import 'fake_backend.dart';

/// A "random" source with a chosen value, so that retry delays are exact.
class FixedRandom implements Random {
  FixedRandom(this.value);
  double value;

  @override
  double nextDouble() => value;
  @override
  bool nextBool() => value >= 0.5;
  @override
  int nextInt(int max) => (value * max).floor().clamp(0, max - 1);
}

/// One connection attempt as the server saw it.
class LiveAttempt {
  LiveAttempt(this.url, this.headers, this.at);
  final Uri url;
  final Map<String, String> headers;
  final DateTime at;
}

enum LiveOutage {
  none,

  /// No connection can be made.
  offline,

  /// The upgrade never answers.
  hang,
}

/// A stand-in for the backend's live channel that follows backend/docs/websocket-contract.md:
/// bearer token on the upgrade (refused with 403 when not valid), `hello`, `start` / `resume`
/// with replay, `resumed`, `event`, `heartbeat`, `error` and the close codes. Test code only.
class FakeLiveServer {
  FakeLiveServer(this._backend);

  final FakeBackend _backend;

  final List<LiveAttempt> attempts = [];
  final List<FakeLiveSocket> sockets = [];

  /// Every event ever ingested, in cursor order (what `resume` replays from).
  final List<Map<String, Object?>> log = [];

  LiveOutage outage = LiveOutage.none;

  /// `resume` with more missed events than this answers `resync_required`.
  int replayLimit = 1000;

  String protocol = 'gossy.ws.v1';
  num heartbeatIntervalS = 25;

  /// When false the server stays silent after the upgrade (no `hello`, no heartbeats).
  bool talkative = true;

  /// Every upgrade is refused with 403, whatever the token.
  bool refuseUpgrades = false;

  /// The server's clock (Phase 5A): when set, `hello`, `heartbeat` and `pong` carry its time
  /// as `serverTime`. Without it they carry one fixed instant, as before.
  DateTime Function()? clock;

  String get serverTime => clock == null ? '2026-10-02T06:00:00+00:00' : clock!().toUtc().toIso8601String();

  int _cursor = 100;

  int get latestCursor => _cursor;

  List<FakeLiveSocket> get openSockets => sockets.where((s) => s.isOpen).toList();

  /// Every text frame any client sent, decoded.
  List<Object?> get clientFrames => [for (final s in sockets) ...s.received];

  Future<LiveSocket> connect(Uri url, Map<String, String> headers) async {
    attempts.add(LiveAttempt(url, Map.of(headers), DateTime.now()));
    if (outage == LiveOutage.offline) throw const LiveConnectFailed();
    if (outage == LiveOutage.hang) return Completer<LiveSocket>().future;
    if (refuseUpgrades || !_backend.acceptsAuthorization(headers['Authorization'])) throw const LiveHandshakeRejected();
    final socket = FakeLiveSocket(this);
    sockets.add(socket);
    if (talkative) socket._hello();
    return socket;
  }

  /// The backend ingested a device message: stored, then sent to every started connection.
  /// [alerts] (Phase 5B) are the alerts the backend created from the message; they travel
  /// inside the event, as in the contract.
  Map<String, Object?> ingest({required String kind, required String deviceId, required String ts, Map<String, Object?>? data, String? msgId, String? receivedAt, List<Map<String, Object?>> alerts = const []}) {
    _cursor++;
    final event = <String, Object?>{
      'type': 'event', 'cursor': _cursor, 'kind': kind, 'deviceId': deviceId,
      'msgId': msgId ?? '01K6CQ4W0D8V9J4Q9W2Y${_cursor.toString().padLeft(6, '0')}',
      'ts': ts, 'receivedAt': receivedAt ?? ts, 'data': data, 'alerts': <Object?>[...alerts],
    };
    log.add(event);
    for (final socket in openSockets) {
      if (socket.started) socket.push(event);
    }
    return event;
  }

  /// Sends a raw frame to every open connection (malformed and unknown messages).
  void pushRaw(String frame) {
    for (final socket in openSockets) {
      socket.pushRaw(frame);
    }
  }

  /// Closes every open connection from the server side.
  void dropAll({int? code}) {
    for (final socket in openSockets) {
      socket.serverClose(code);
    }
  }

  /// The access token of the open connections expired: `error/token_expired`, then close 4401.
  void expireTokens() {
    for (final socket in openSockets) {
      socket.push({'type': 'error', 'code': 'token_expired', 'message': 'Access token expired. Refresh it and reconnect with resume.'});
      socket.serverClose(4401);
    }
  }

  /// The session was revoked: `error/session_revoked`, then close 4401.
  void revokeSessions() {
    for (final socket in openSockets) {
      socket.push({'type': 'error', 'code': 'session_revoked', 'message': 'Session is no longer valid.'});
      socket.serverClose(4401);
    }
  }
}

class FakeLiveSocket implements LiveSocket {
  FakeLiveSocket(this._server);

  final FakeLiveServer _server;
  final StreamController<String> _toClient = StreamController<String>();
  Timer? _heartbeat;

  /// Frames the client sent, decoded (a non-JSON frame is kept as its text).
  final List<Object?> received = [];
  bool started = false;
  bool isOpen = true;
  bool closedByClient = false;
  int _lastSent = 0;
  int? _closeCode;

  @override
  Stream<String> get frames => _toClient.stream;

  @override
  int? get closeCode => _closeCode;

  void push(Map<String, Object?> message) => pushRaw(jsonEncode(message));

  void pushRaw(String frame) {
    if (isOpen) _toClient.add(frame);
  }

  void _hello() {
    push({
      'type': 'hello', 'protocol': _server.protocol, 'serverTime': _server.serverTime, 'latestCursor': _server.latestCursor,
      'tokenExpiresAt': '2099-01-01T00:15:00+00:00', 'heartbeatIntervalS': _server.heartbeatIntervalS, 'allowedOps': ['start', 'resume', 'ping'],
    });
    _heartbeat = Timer.periodic(Duration(milliseconds: (_server.heartbeatIntervalS * 1000).round()), (_) {
      push({'type': 'heartbeat', 'serverTime': _server.serverTime, 'cursor': _lastSent});
    });
  }

  @override
  void send(String text) {
    if (!isOpen) return;
    Object? message;
    try {
      message = jsonDecode(text);
    } on FormatException {
      received.add(text);
      push({'type': 'error', 'code': 'invalid_message', 'message': 'Messages must be JSON objects.'});
      return;
    }
    received.add(message);
    final op = message is Map ? message['op'] : null;
    if (op == 'ping') {
      push({'type': 'pong', 'serverTime': _server.serverTime});
    } else if (op == 'start') {
      if (started) return;
      _lastSent = _server.latestCursor;
      push({'type': 'resumed', 'cursor': _lastSent, 'replayed': 0});
      started = true;
    } else if (op == 'resume') {
      final cursor = (message as Map)['cursor'];
      if (cursor is! int || cursor < 0) {
        push({'type': 'error', 'code': 'invalid_cursor', 'message': 'cursor must be a non-negative integer.'});
      } else if (started) {
        push({'type': 'error', 'code': 'already_started', 'message': 'resume is only allowed before the stream starts.'});
      } else {
        final missed = _server.log.where((e) => (e['cursor']! as int) > cursor).toList();
        if (missed.length > _server.replayLimit) {
          push({'type': 'resync_required', 'latestCursor': _server.latestCursor, 'message': 'Too many missed events; reload state via REST, then send start.'});
          return;
        }
        _lastSent = cursor;
        for (final event in missed) {
          push(event);
          _lastSent = event['cursor']! as int;
        }
        push({'type': 'resumed', 'cursor': _lastSent, 'replayed': missed.length});
        started = true;
      }
    } else {
      push({'type': 'error', 'code': 'unsupported_op', 'message': "Only 'start', 'resume' and 'ping' are supported. This channel is read-only and cannot send commands to devices."});
    }
  }

  /// The connection stays open but the server stops sending anything (a dead peer).
  void serverGoesSilent() => _heartbeat?.cancel();

  void serverClose(int? code) {
    if (!isOpen) return;
    _closeCode = code;
    _end();
  }

  @override
  Future<void> close() async {
    if (!isOpen) return;
    closedByClient = true;
    _closeCode = 1000;
    _end();
  }

  void _end() {
    isOpen = false;
    _heartbeat?.cancel();
    unawaited(_toClient.close());
  }
}
