import 'package:flutter/foundation.dart';

/// Thrown when the build has no usable API address. Shown as a plain message; never a crash.
class ConfigurationError implements Exception {
  const ConfigurationError(this.message);
  final String message;

  @override
  String toString() => 'ConfigurationError: $message';
}

/// Where the backend is. The address is injected at build time:
///
///     flutter run --dart-define=GOSSY_API_BASE_URL=http://10.0.2.2:8000
///
/// * Debug builds fall back to the LOCAL DEVELOPMENT backend as seen from the Android emulator.
/// * Plain http is accepted only for that local development backend (loopback addresses), which
///   matches the debug-only Android network security configuration.
/// * Non-debug builds have no default and must be given an https address. No staging or
///   production address exists in this code base (U-5 / U-6 are undecided).
class AppConfig {
  const AppConfig({required this.apiBaseUrl});

  final Uri apiBaseUrl;

  static const String defineKey = 'GOSSY_API_BASE_URL';

  /// 10.0.2.2 is the Android emulator's alias for the development machine's loopback interface.
  static const String developmentDefault = 'http://10.0.2.2:8000';

  static const Set<String> _localDevelopmentHosts = {'10.0.2.2', '127.0.0.1', 'localhost'};

  static AppConfig fromEnvironment() => resolve(const String.fromEnvironment(defineKey), debugBuild: kDebugMode);

  static AppConfig resolve(String configured, {required bool debugBuild}) {
    final raw = configured.trim().isNotEmpty ? configured.trim() : (debugBuild ? developmentDefault : '');
    if (raw.isEmpty) {
      throw const ConfigurationError('This build has no server address ($defineKey).');
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const ConfigurationError('The server address ($defineKey) is not a valid URL.');
    }
    final isHttps = uri.scheme == 'https';
    final isLocalHttp = uri.scheme == 'http' && _localDevelopmentHosts.contains(uri.host);
    if (!debugBuild && !isHttps) {
      throw const ConfigurationError('Only https server addresses are allowed in this build.');
    }
    if (!isHttps && !isLocalHttp) {
      throw const ConfigurationError('Plain http is allowed only for the local development backend.');
    }
    return AppConfig(apiBaseUrl: uri);
  }
}
