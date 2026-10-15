import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

/// One open connection to the live channel, reduced to what the app uses: text frames in, text
/// frames out, close. Tests supply their own implementation.
abstract class LiveSocket {
  /// Text frames from the server. Ends when the connection is closed by either side.
  Stream<String> get frames;

  /// The WebSocket close code, known once [frames] has ended (null if there was no close frame).
  int? get closeCode;

  void send(String text);

  Future<void> close();
}

typedef LiveConnector = Future<LiveSocket> Function(Uri url, Map<String, String> headers);

/// The backend refused the upgrade because of the access token (HTTP 401/403 on the handshake).
class LiveHandshakeRejected implements Exception {
  const LiveHandshakeRejected();

  @override
  String toString() => 'LiveHandshakeRejected';
}

/// No connection could be made (offline, refused, TLS, unexpected reply). Carries no detail on
/// purpose: nothing from the request - address, headers, token - can end up in a message.
class LiveConnectFailed implements Exception {
  const LiveConnectFailed();

  @override
  String toString() => 'LiveConnectFailed';
}

/// The live channel of the backend at [apiBaseUrl]: same host, `/api/v1/ws`, `wss` for an https
/// backend. Plain `ws` therefore only occurs for the local development backend, which is the
/// only place AppConfig accepts plain http.
Uri liveUrlFor(Uri apiBaseUrl) {
  final prefix = apiBaseUrl.path.endsWith('/') ? apiBaseUrl.path.substring(0, apiBaseUrl.path.length - 1) : apiBaseUrl.path;
  return Uri(
    scheme: apiBaseUrl.scheme == 'https' ? 'wss' : 'ws',
    host: apiBaseUrl.host,
    port: apiBaseUrl.hasPort ? apiBaseUrl.port : null,
    path: '$prefix/api/v1/ws',
  );
}

/// Opens the connection with `dart:io` and wraps it in a `web_socket_channel` channel.
Future<LiveSocket> connectLiveSocket(Uri url, Map<String, String> headers) async {
  try {
    return _ChannelLiveSocket(IOWebSocketChannel(await WebSocket.connect(url.toString(), headers: headers)));
  } on WebSocketException catch (error) {
    if (error.httpStatusCode == 401 || error.httpStatusCode == 403) throw const LiveHandshakeRejected();
    throw const LiveConnectFailed();
  } on Object {
    throw const LiveConnectFailed();
  }
}

class _ChannelLiveSocket implements LiveSocket {
  _ChannelLiveSocket(this._channel);

  final IOWebSocketChannel _channel;

  @override
  Stream<String> get frames => _channel.stream.where((frame) => frame is String).cast<String>();

  @override
  int? get closeCode => _channel.closeCode;

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  Future<void> close() async {
    await _channel.sink.close();
  }
}
