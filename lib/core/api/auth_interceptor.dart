import 'package:dio/dio.dart';

import '../auth/token_store.dart';
import '../models.dart';
import 'api_failure.dart';

/// Attaches the access token to authenticated requests and renews it when it has expired.
///
/// The backend rotates the refresh token on every refresh and treats a second use of the same
/// refresh token as theft: it revokes the whole session. Therefore:
///
/// * exactly ONE refresh request can be in flight; every request that needs a new token waits
///   for that same request ([_refreshInFlight]);
/// * a request that failed with an access token that has meanwhile been replaced is simply
///   repeated with the current token - no second refresh;
/// * a failed refresh is never repeated automatically: a rejected refresh token ends the session
///   (tokens deleted, user must sign in again); a network failure is reported to the caller and
///   the tokens are kept;
/// * a request is repeated at most once.
///
/// Tokens are never logged: this class has no logging, and failures carry no token material.
class AuthInterceptor extends Interceptor {
  AuthInterceptor({
    required TokenStore tokens,
    required Dio refreshClient,
    required void Function() onSessionInvalidated,
    DateTime Function()? clock,
  })  : _tokens = tokens,
        _refreshClient = refreshClient,
        _onSessionInvalidated = onSessionInvalidated,
        _clock = clock ?? DateTime.now;

  /// Marks a request that carries no session (sign-in and refresh calls).
  static const String publicRequest = 'gossy.public';
  static const String _repeated = 'gossy.repeated';
  static const String refreshPath = '/api/v1/auth/refresh';

  final TokenStore _tokens;
  final Dio _refreshClient;
  final void Function() _onSessionInvalidated;
  final DateTime Function() _clock;

  /// The client this interceptor is installed on; used to repeat a request once.
  late final Dio client;

  Future<StoredSession>? _refreshInFlight;

  /// Number of refresh requests actually sent (observability for tests).
  int refreshRequests = 0;

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (options.extra[publicRequest] == true) return handler.next(options);
    try {
      var session = await _tokens.read();
      if (session == null) throw const ApiFailure.sessionExpired();
      if (session.accessTokenExpired(_clock().toUtc())) session = await _refresh(session);
      options.headers['Authorization'] = 'Bearer ${session.accessToken}';
      handler.next(options);
    } on ApiFailure catch (failure) {
      handler.reject(DioException(requestOptions: options, error: failure));
    }
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    if (options.extra[publicRequest] == true || err.response?.statusCode != 401) return handler.next(err);
    try {
      if (options.extra[_repeated] == true) {
        // Rejected again with a token that was just renewed: the session itself is gone.
        await _invalidate();
        throw const ApiFailure.sessionExpired();
      }
      var session = await _tokens.read();
      if (session == null) throw const ApiFailure.sessionExpired();
      final rejectedToken = options.headers['Authorization'];
      if (rejectedToken == 'Bearer ${session.accessToken}') session = await _refresh(session);
      final repeat = options.copyWith(extra: {...options.extra, _repeated: true});
      handler.resolve(await client.fetch<dynamic>(repeat));
    } on ApiFailure catch (failure) {
      handler.reject(DioException(requestOptions: options, error: failure));
    } on DioException catch (repeatError) {
      handler.reject(repeatError);
    }
  }

  /// The access token for a connection that is not an HTTP request (the live channel).
  ///
  /// Renews it first if it has expired, or if it is still the token the backend just refused
  /// ([rejected]). The renewal is the same single-flight [_refresh] the HTTP requests use, so the
  /// live channel can never start a second, competing refresh. Throws [ApiFailure]: with
  /// `sessionExpired` the session has been ended exactly as for a rejected HTTP request.
  Future<String> accessToken({String? rejected}) async {
    var session = await _tokens.read();
    if (session == null) throw const ApiFailure.sessionExpired();
    if (session.accessTokenExpired(_clock().toUtc()) || session.accessToken == rejected) session = await _refresh(session);
    return session.accessToken;
  }

  /// Single flight: concurrent callers share one refresh request and its result.
  Future<StoredSession> _refresh(StoredSession current) {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final started = _doRefresh(current);
    _refreshInFlight = started;
    return started.whenComplete(() => _refreshInFlight = null);
  }

  Future<StoredSession> _doRefresh(StoredSession current) async {
    refreshRequests++;
    try {
      final response = await _refreshClient.post<dynamic>(
        refreshPath,
        data: {'refreshToken': current.refreshToken},
        options: Options(extra: {publicRequest: true}),
      );
      final renewed = StoredSession.fromPair(TokenPair.fromJson(asJsonObject(response.data)));
      await _tokens.write(renewed); // both tokens replaced in one write
      return renewed;
    } on DioException catch (e) {
      final failure = ApiFailure.fromDio(e);
      if (failure.kind == ApiFailureKind.unauthorized || failure.kind == ApiFailureKind.badRequest || failure.kind == ApiFailureKind.forbidden) {
        // The refresh token is not accepted (expired, revoked, already used). Never retry.
        await _invalidate();
        throw const ApiFailure.sessionExpired();
      }
      throw failure; // network / server problem: keep the session, let the caller decide
    } on FormatException {
      throw const ApiFailure.invalidResponse();
    }
  }

  Future<void> _invalidate() async {
    await _tokens.clear();
    _onSessionInvalidated();
  }
}
