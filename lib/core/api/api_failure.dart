import 'dart:io';

import 'package:dio/dio.dart';

enum ApiFailureKind {
  /// No connection could be made (offline, DNS, refused, TLS).
  network,
  timeout,

  /// 400 / 422: the backend rejected the request content.
  badRequest,

  /// 401 on a call that carries no session (wrong or expired sign-in code).
  unauthorized,

  /// The stored session is no longer accepted (refresh rejected, token reuse, logout elsewhere).
  sessionExpired,
  forbidden,
  notFound,
  conflict,
  rateLimited,

  /// 503: the backend (or a dependency such as code delivery) is temporarily unavailable.
  unavailable,

  /// Other 5xx.
  server,

  /// The response did not match the contract.
  invalidResponse,
}

/// The only error type the UI sees. It carries nothing sensitive: no response body, no headers,
/// no tokens - only the status, the backend's stable error code and the request id for support.
class ApiFailure implements Exception {
  const ApiFailure(this.kind, {this.statusCode, this.code, this.requestId, this.retryAfter});

  const ApiFailure.sessionExpired() : this(ApiFailureKind.sessionExpired);
  const ApiFailure.invalidResponse() : this(ApiFailureKind.invalidResponse);

  final ApiFailureKind kind;
  final int? statusCode;

  /// `error.code` from the backend's error envelope, e.g. `invalid_credentials`.
  final String? code;
  final String? requestId;

  /// From the `Retry-After` header of a 429.
  final Duration? retryAfter;

  factory ApiFailure.fromDio(DioException e) {
    final inner = e.error;
    if (inner is ApiFailure) return inner;
    if (inner is FormatException) return const ApiFailure.invalidResponse();
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return const ApiFailure(ApiFailureKind.timeout);
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
        return const ApiFailure(ApiFailureKind.network);
      case DioExceptionType.unknown:
        if (inner is SocketException || inner is HandshakeException || inner is HttpException) {
          return const ApiFailure(ApiFailureKind.network);
        }
        if (e.response == null) return const ApiFailure(ApiFailureKind.network);
        return _fromResponse(e.response!);
      case DioExceptionType.badResponse:
        final response = e.response;
        if (response == null) return const ApiFailure(ApiFailureKind.server);
        return _fromResponse(response);
    }
  }

  static ApiFailure _fromResponse(Response<dynamic> response) {
    final status = response.statusCode ?? 0;
    String? code;
    String? requestId;
    final data = response.data;
    if (data is Map && data['error'] is Map) {
      final error = data['error'] as Map;
      if (error['code'] is String) code = error['code'] as String;
      if (error['requestId'] is String) requestId = error['requestId'] as String;
    }
    Duration? retryAfter;
    final header = int.tryParse(response.headers.value('retry-after') ?? '');
    if (header != null && header >= 0) retryAfter = Duration(seconds: header);
    return ApiFailure(_kindFor(status), statusCode: status, code: code, requestId: requestId, retryAfter: retryAfter);
  }

  static ApiFailureKind _kindFor(int status) {
    switch (status) {
      case 400:
      case 413:
      case 422:
        return ApiFailureKind.badRequest;
      case 401:
        return ApiFailureKind.unauthorized;
      case 403:
        return ApiFailureKind.forbidden;
      case 404:
        return ApiFailureKind.notFound;
      case 409:
        return ApiFailureKind.conflict;
      case 429:
        return ApiFailureKind.rateLimited;
      case 503:
        return ApiFailureKind.unavailable;
    }
    if (status >= 500) return ApiFailureKind.server;
    return ApiFailureKind.invalidResponse;
  }

  @override
  String toString() => 'ApiFailure(${kind.name}, status: $statusCode, code: $code, requestId: $requestId)';
}
