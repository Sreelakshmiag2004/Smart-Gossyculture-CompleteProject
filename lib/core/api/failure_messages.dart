import 'api_failure.dart';

/// What the user was doing when the failure happened. Selects the wording.
enum FailureContext { general, requestCode, verifyCode, createFarm, claimDevice }

/// Text shown to farmers. Chosen by failure kind and backend error code only - server messages,
/// status lines and exception text are never shown. (English only until U-13 is decided.)
String messageForFailure(ApiFailure failure, {FailureContext context = FailureContext.general}) {
  switch (failure.kind) {
    case ApiFailureKind.network:
      return 'No connection. Check your internet connection and try again.';
    case ApiFailureKind.timeout:
      return 'The server is taking too long to respond. Please try again.';
    case ApiFailureKind.sessionExpired:
      return sessionExpiredMessage;
    case ApiFailureKind.rateLimited:
      return 'Too many attempts. ${_waitText(failure.retryAfter)}';
    case ApiFailureKind.unavailable:
      if (failure.code == 'otp_delivery_unavailable') {
        return 'Sign-in codes cannot be sent at the moment. Please try again later.';
      }
      return 'The service is temporarily unavailable. Please try again in a few minutes.';
    case ApiFailureKind.server:
      return 'Something went wrong on our side. Please try again in a few minutes.';
    case ApiFailureKind.invalidResponse:
      return 'The server sent an unexpected reply. Please try again later.';
    case ApiFailureKind.forbidden:
      return 'You are not allowed to do this.';
    case ApiFailureKind.conflict:
      return 'This was already done. Refresh and try again.';
    case ApiFailureKind.unauthorized:
      if (context == FailureContext.verifyCode) {
        // The backend answers identically for a wrong, an expired and an already used code.
        return 'That code is incorrect or has expired. Check it, or request a new code.';
      }
      return sessionExpiredMessage;
    case ApiFailureKind.notFound:
      if (context == FailureContext.claimDevice) {
        if (failure.code == 'claim_failed') {
          return 'This device could not be added. Check the device ID and claim code - the code may be wrong, already used or expired.';
        }
        return 'The selected farm was not found. Go back and try again.';
      }
      return 'This could not be found.';
    case ApiFailureKind.badRequest:
      switch (context) {
        case FailureContext.requestCode:
          return 'Enter your full phone number with the country code, for example +91 98765 43210.';
        case FailureContext.verifyCode:
          return 'Enter the 6-digit code.';
        case FailureContext.createFarm:
          return 'Enter a farm name of up to 80 characters.';
        case FailureContext.claimDevice:
          return 'Check the device ID and the claim code and try again.';
        case FailureContext.general:
          return 'The request could not be processed. Please check what you entered.';
      }
  }
}

const String sessionExpiredMessage = 'Your session has ended. Please sign in again.';

String _waitText(Duration? retryAfter) {
  if (retryAfter == null || retryAfter.inSeconds <= 0) return 'Please wait a few minutes and try again.';
  if (retryAfter.inSeconds < 60) return 'Please try again in ${retryAfter.inSeconds} seconds.';
  final minutes = (retryAfter.inSeconds / 60).ceil();
  return 'Please try again in $minutes ${minutes == 1 ? 'minute' : 'minutes'}.';
}
