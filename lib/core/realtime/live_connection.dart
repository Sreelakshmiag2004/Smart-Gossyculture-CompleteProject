import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/api_failure.dart';
import 'live_messages.dart';
import 'live_socket.dart';

enum LiveState {
  /// Not open: never opened, or closed by the app (page left, device changed, signed out).
  disconnected,

  /// First connection attempt in progress.
  connecting,

  /// The stream is live.
  connected,

  /// The connection was lost or could not be made; another attempt is scheduled or in progress.
  reconnecting,

  /// The session is not accepted. No further attempts are made.
  authFailed,

  /// The server does not speak the protocol this app implements. No further attempts are made.
  unavailable,
}

/// The only messages this app can put on the live channel. Both are protocol messages that begin
/// event delivery; the channel carries nothing else from the app to the backend.
enum _ClientOp { start, resume }

/// One connection to the backend's live channel (`gossy.ws.v1`), kept alive until [close].
///
/// * Authentication is the access token of the existing session, sent as `Authorization: Bearer`
///   on the upgrade request. It is obtained through `accessToken`, which is the Phase 3A
///   single-flight refresh: this class never refreshes on its own and never stores a token.
/// * Monitoring only: the app sends `start` or `resume` once per connection and nothing else.
/// * After a lost connection it reconnects with exponential backoff and jitter, bounded by
///   [maxDelay], and resumes from the last cursor it processed so that no event is missed.
/// * At most one socket and one retry timer exist at any time; [close] cancels both.
///
/// Nothing is logged here: frames and headers never leave this class as text.
class LiveConnection extends ChangeNotifier {
  LiveConnection({
    required this.url,
    required Future<String> Function({String? rejected}) accessToken,
    LiveConnector? connector,
    Random? random,
    DateTime Function()? clock,
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 10),
    this.helloTimeout = const Duration(seconds: 10),
    this.stableAfter = const Duration(seconds: 10),
  })  : _accessToken = accessToken,
        _connector = connector ?? connectLiveSocket,
        _random = random ?? Random(),
        _clock = clock ?? DateTime.now;

  final Uri url;

  /// First retry delay ceiling; doubled after every further failure.
  final Duration baseDelay;

  /// No retry ever waits longer than this.
  final Duration maxDelay;
  final Duration connectTimeout;

  /// How long to wait for `hello` after the upgrade.
  final Duration helloTimeout;

  /// A connection that stayed live this long is considered healthy: the backoff starts over.
  final Duration stableAfter;

  final Future<String> Function({String? rejected}) _accessToken;
  final LiveConnector _connector;
  final Random _random;
  final DateTime Function() _clock;

  /// Server clock minus phone clock, from the `serverTime` of the newest `hello`, `heartbeat`
  /// or `pong`. Null until the server has said what time it is. With it, "now on the server"
  /// is known whatever the phone's clock is set to.
  Duration? serverClockOffset;

  LiveState _state = LiveState.disconnected;
  bool _open = false;

  /// Incremented by [open] and [close]; asynchronous work started earlier compares and gives up.
  int _epoch = 0;
  bool _connecting = false;
  LiveSocket? _socket;
  StreamSubscription<String>? _frames;
  Timer? _retryTimer;
  Timer? _watchdog;
  Timer? _stableTimer;

  int? _cursor;
  int _failures = 0;
  int _authRejections = 0;
  String? _rejectedToken;
  String? _tokenInUse;
  bool _everLive = false;
  bool _helloSeen = false;
  bool _freshStart = false;
  bool _authClosing = false;
  Duration? _silenceLimit;

  void Function(LiveEvent event)? _onEvent;
  void Function({required bool fresh})? _onStreamReady;

  LiveState get state => _state;

  /// Opened and still trying or connected.
  bool get isOpen => _open;

  /// Connection attempts made since [open] (observability for tests).
  int connectAttempts = 0;

  /// The delay chosen for the most recent retry.
  Duration? lastRetryDelay;

  /// Frames dropped because they were not contract messages.
  int malformedFrames = 0;

  /// Starts the connection. Does nothing while it is already open.
  ///
  /// [onEvent] receives every event once, in cursor order. [onStreamReady] is called each time
  /// the stream becomes live; `fresh` is true when delivery started "from now" (first connection
  /// or after `resync_required`) rather than from a cursor, so the caller must re-read its state.
  void open({required void Function(LiveEvent event) onEvent, required void Function({required bool fresh}) onStreamReady}) {
    if (_open) return;
    _open = true;
    _epoch++;
    _onEvent = onEvent;
    _onStreamReady = onStreamReady;
    _cursor = null;
    _failures = 0;
    _authRejections = 0;
    _rejectedToken = null;
    _everLive = false;
    connectAttempts = 0;
    lastRetryDelay = null;
    _connect();
  }

  /// Closes the socket and cancels every timer. [notify] is false when called while the widget
  /// tree is being torn down.
  void close({bool notify = true}) {
    _open = false;
    _epoch++;
    _release();
    _onEvent = null;
    _onStreamReady = null;
    _cursor = null;
    _setState(LiveState.disconnected, notify: notify);
  }

  @override
  void dispose() {
    close(notify: false);
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_open || _connecting || _socket != null) return; // never a second socket
    final epoch = _epoch;
    _connecting = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _setState(_everLive || _failures > 0 || _authRejections > 0 ? LiveState.reconnecting : LiveState.connecting);
    connectAttempts++;
    try {
      final String token;
      try {
        token = await _accessToken(rejected: _rejectedToken);
      } on ApiFailure catch (failure) {
        if (epoch != _epoch) return;
        if (failure.kind == ApiFailureKind.sessionExpired) {
          // Phase 3A has already deleted the tokens and is returning the user to sign-in.
          _stop(LiveState.authFailed);
        } else {
          _scheduleRetry();
        }
        return;
      }
      if (epoch != _epoch) return;

      final LiveSocket socket;
      try {
        socket = await _connectWithTimeout({'Authorization': 'Bearer $token'});
      } on LiveHandshakeRejected {
        if (epoch == _epoch) _onAuthRejected(token);
        return;
      } on Object {
        if (epoch == _epoch) _scheduleRetry();
        return;
      }
      if (epoch != _epoch) {
        _discard(socket);
        return;
      }

      _socket = socket;
      _tokenInUse = token;
      _helloSeen = false;
      _authClosing = false;
      _silenceLimit = null;
      _armWatchdog(helloTimeout);
      _frames = socket.frames.listen(
        (frame) => _onFrame(socket, frame),
        onError: (Object _) => _onSocketClosed(socket),
        onDone: () => _onSocketClosed(socket),
        cancelOnError: true,
      );
    } finally {
      _connecting = false;
    }
  }

  Future<LiveSocket> _connectWithTimeout(Map<String, String> headers) {
    final pending = _connector(url, headers);
    return pending.timeout(connectTimeout, onTimeout: () {
      // If it connects after all, do not leave the socket open.
      unawaited(pending.then(_discard, onError: (Object _) {}));
      throw const LiveConnectFailed();
    });
  }

  void _onFrame(LiveSocket socket, String frame) {
    if (!identical(socket, _socket)) return;
    _armWatchdog(_silenceLimit ?? helloTimeout);
    final LiveMessage message;
    try {
      message = LiveMessage.parse(frame);
    } on FormatException {
      malformedFrames++;
      return;
    }
    switch (message) {
      case LiveHello(:final protocol, :final heartbeatInterval, :final serverTime):
        if (_helloSeen) return;
        if (protocol != liveProtocol) {
          _stop(LiveState.unavailable);
          return;
        }
        _helloSeen = true;
        _noteServerTime(serverTime);
        // Two missed heartbeats (plus slack) mean the connection is dead even if TCP has not noticed.
        _silenceLimit = heartbeatInterval * 2 + const Duration(seconds: 5);
        _armWatchdog(_silenceLimit!);
        _begin();
      case LiveResumed(:final cursor):
        if (!_helloSeen) return;
        if (_cursor == null || cursor > _cursor!) _cursor = cursor;
        _everLive = true;
        _stableTimer?.cancel();
        _stableTimer = Timer(stableAfter, () {
          _failures = 0;
          _authRejections = 0;
          _rejectedToken = null;
        });
        _setState(LiveState.connected);
        _onStreamReady?.call(fresh: _freshStart);
      case LiveEvent(:final cursor):
        if (!_helloSeen) return;
        if (_cursor != null && cursor <= _cursor!) return; // already processed
        _cursor = cursor;
        _onEvent?.call(message);
      case LiveResyncRequired():
        if (!_helloSeen) return;
        _cursor = null;
        _begin();
      case LiveError(:final code):
        if (code == LiveError.tokenExpired || code == LiveError.sessionRevoked) {
          _authClosing = true; // the server closes with 4401 next
        } else if (code == LiveError.invalidCursor && _state != LiveState.connected) {
          _cursor = null;
          _begin();
        }
      case LiveHeartbeat(:final serverTime):
        if (_helloSeen) _noteServerTime(serverTime);
      case LivePong(:final serverTime):
        if (_helloSeen) _noteServerTime(serverTime);
      case LiveUnknown():
        break;
    }
  }

  void _noteServerTime(DateTime? serverTime) {
    if (serverTime != null) serverClockOffset = serverTime.difference(_clock());
  }

  /// Asks the server to begin delivery: from the last processed cursor, or from now.
  void _begin() {
    final cursor = _cursor;
    _freshStart = cursor == null;
    _send(cursor == null ? _ClientOp.start : _ClientOp.resume, cursor: cursor);
  }

  /// The single place where the app writes to the live channel.
  void _send(_ClientOp op, {int? cursor}) {
    _socket?.send(jsonEncode(switch (op) {
      _ClientOp.start => {'op': 'start'},
      _ClientOp.resume => {'op': 'resume', 'cursor': cursor},
    }));
  }

  void _onSocketClosed(LiveSocket socket) {
    if (!identical(socket, _socket)) return;
    final authClose = _authClosing || socket.closeCode == 4401;
    final token = _tokenInUse;
    _release();
    if (!_open) return;
    if (authClose && token != null) {
      _onAuthRejected(token);
    } else {
      _scheduleRetry();
    }
  }

  /// The backend did not accept [token] (handshake refused, or closed with 4401). One attempt
  /// follows at once; it asks Phase 3A for a token other than this one, which renews it at most
  /// once however many callers ask. A second rejection before the connection has proven stable
  /// ends the attempts: an unaccepted session is never retried in a loop.
  void _onAuthRejected(String token) {
    _authRejections++;
    _rejectedToken = token;
    if (_authRejections > 1) {
      _stop(LiveState.authFailed);
      return;
    }
    _setState(LiveState.reconnecting);
    final epoch = _epoch;
    scheduleMicrotask(() {
      if (epoch == _epoch) unawaited(_connect());
    });
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final ceilingMs = min(maxDelay.inMilliseconds, baseDelay.inMilliseconds * (1 << min(_failures, 20)));
    _failures++;
    // "Equal jitter": half of the ceiling is fixed, the other half random.
    final delay = Duration(milliseconds: ceilingMs ~/ 2 + (_random.nextDouble() * (ceilingMs / 2)).round());
    lastRetryDelay = delay;
    _setState(LiveState.reconnecting);
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_connect());
    });
  }

  void _armWatchdog(Duration limit) {
    _watchdog?.cancel();
    final socket = _socket;
    _watchdog = Timer(limit, () {
      if (!identical(socket, _socket)) return;
      _release();
      if (_open) _scheduleRetry();
    });
  }

  void _stop(LiveState state) {
    _open = false;
    _epoch++;
    _release();
    _setState(state);
  }

  /// Cancels the timers and closes the socket, if any.
  void _release() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    _stableTimer?.cancel();
    _stableTimer = null;
    unawaited(_frames?.cancel());
    _frames = null;
    final socket = _socket;
    _socket = null;
    _tokenInUse = null;
    if (socket != null) _discard(socket);
  }

  void _discard(LiveSocket socket) {
    unawaited(socket.close().catchError((Object _) {}));
  }

  void _setState(LiveState state, {bool notify = true}) {
    if (_state == state) return;
    _state = state;
    if (notify) notifyListeners();
  }
}
