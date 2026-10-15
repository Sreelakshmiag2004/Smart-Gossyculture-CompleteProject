/// Input rules taken from the backend contract (backend/docs/openapi.json). The backend remains
/// the authority; these only avoid sending requests that it would certainly reject.
library;

final RegExp _e164 = RegExp(r'^\+[1-9][0-9]{7,14}$');
final RegExp _otpCode = RegExp(r'^[0-9]{6}$');
final RegExp _deviceId = RegExp(r'^[a-z0-9][a-z0-9-]{2,63}$');

/// Returns the phone number in E.164 form, or null if it is not a complete international number.
/// Spaces, dashes, dots and brackets are ignored. The country code (leading +) is required.
String? normalizePhone(String input) {
  final compact = input.replaceAll(RegExp(r'[\s\-().]'), '');
  return _e164.hasMatch(compact) ? compact : null;
}

bool isValidOtpCode(String input) => _otpCode.hasMatch(input.trim());

/// Device ids are lower-case in the contract; input is trimmed and lower-cased.
String? normalizeDeviceId(String input) {
  final value = input.trim().toLowerCase();
  return _deviceId.hasMatch(value) ? value : null;
}

/// Claim codes: 6 to 32 characters.
String? normalizeClaimCode(String input) {
  final value = input.trim();
  return value.length >= 6 && value.length <= 32 ? value : null;
}

/// Farm names: 1 to 80 characters.
String? normalizeFarmName(String input) {
  final value = input.trim();
  return value.isNotEmpty && value.length <= 80 ? value : null;
}

/// "+91 98765 43210" -> "+91 ••••••••10": enough for the user to recognise their number.
String maskPhone(String e164) {
  if (e164.length <= 5) return e164;
  return '${e164.substring(0, 3)} ${'•' * (e164.length - 5)}${e164.substring(e164.length - 2)}';
}
