import 'package:dio/dio.dart';

import '../app_config.dart';
import '../auth/token_store.dart';
import 'api_failure.dart';
import 'auth_interceptor.dart';

/// The two HTTP clients of the app. Both talk ONLY to the backend REST API.
///
/// * [public]  - sign-in calls (no session).
/// * [authed]  - everything else; [AuthInterceptor] adds the access token and renews it.
///
/// No request/response logging is installed: bodies and headers contain tokens and phone numbers.
class ApiClient {
  ApiClient({
    required AppConfig config,
    required TokenStore tokens,
    required void Function() onSessionInvalidated,
    HttpClientAdapter? adapter,
    DateTime Function()? clock,
  }) {
    BaseOptions options() => BaseOptions(
          baseUrl: config.apiBaseUrl.toString(),
          connectTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
          contentType: Headers.jsonContentType,
          responseType: ResponseType.json,
          headers: {'Accept': 'application/json'},
        );
    public = Dio(options());
    authed = Dio(options());
    if (adapter != null) {
      public.httpClientAdapter = adapter;
      authed.httpClientAdapter = adapter;
    }
    interceptor = AuthInterceptor(tokens: tokens, refreshClient: public, onSessionInvalidated: onSessionInvalidated, clock: clock)..client = authed;
    authed.interceptors.add(interceptor);
  }

  late final Dio public;
  late final Dio authed;
  late final AuthInterceptor interceptor;

  static Options get publicOptions => Options(extra: {AuthInterceptor.publicRequest: true});
}

/// Runs a backend call and converts every failure into an [ApiFailure].
Future<T> guardApi<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on DioException catch (e) {
    throw ApiFailure.fromDio(e);
  } on FormatException {
    throw const ApiFailure.invalidResponse();
  }
}
