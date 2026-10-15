import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/api/api_failure.dart';
import 'package:smart_gossy_culture_app/core/api/failure_messages.dart';
import 'package:smart_gossy_culture_app/core/app_config.dart';
import 'package:smart_gossy_culture_app/core/validators.dart';

void main() {
  group('phone input validation (E.164, backend contract)', () {
    test('accepts a full international number and removes formatting', () {
      expect(normalizePhone('+91 98765 43210'), '+919876543210');
      expect(normalizePhone('+999-0000-0001'), '+99900000001');
      expect(normalizePhone(' +1 (555) 123.4567 '), '+15551234567');
    });

    test('rejects numbers without a country code, too short, too long or with letters', () {
      for (final bad in ['9876543210', '', '+', '+0123456789', '+91 12345', '+1234567890123456', '+91abc9876543', '0091 9876543210', 'farmer@example.com']) {
        expect(normalizePhone(bad), isNull, reason: bad);
      }
    });

    test('masking keeps only the prefix and the last two digits', () {
      expect(maskPhone('+919876543210'), '+91 ••••••••10');
    });
  });

  group('code, device and farm input validation', () {
    test('sign-in code is exactly six digits', () {
      expect(isValidOtpCode('123456'), isTrue);
      for (final bad in ['', '12345', '1234567', '12a456', '12 456']) {
        expect(isValidOtpCode(bad), isFalse, reason: bad);
      }
    });

    test('device id follows the contract pattern (lower-cased, trimmed)', () {
      expect(normalizeDeviceId('  BB-0001 '), 'bb-0001');
      for (final bad in ['', 'ab', '-abc', 'has space', 'under_score', 'x' * 65]) {
        expect(normalizeDeviceId(bad), isNull, reason: bad);
      }
    });

    test('claim code is 6 to 32 characters, farm name 1 to 80', () {
      expect(normalizeClaimCode(' ABCD-1234 '), 'ABCD-1234');
      expect(normalizeClaimCode('12345'), isNull);
      expect(normalizeClaimCode('x' * 33), isNull);
      expect(normalizeFarmName('  North field '), 'North field');
      expect(normalizeFarmName('   '), isNull);
      expect(normalizeFarmName('x' * 81), isNull);
    });
  });

  group('development API configuration', () {
    test('debug build without a define uses the local development backend', () {
      expect(AppConfig.resolve('', debugBuild: true).apiBaseUrl.toString(), 'http://10.0.2.2:8000');
    });

    test('non-debug build has no default and refuses plain http', () {
      expect(() => AppConfig.resolve('', debugBuild: false), throwsA(isA<ConfigurationError>()));
      expect(() => AppConfig.resolve('http://10.0.2.2:8000', debugBuild: false), throwsA(isA<ConfigurationError>()));
      expect(AppConfig.resolve('https://backend.test', debugBuild: false).apiBaseUrl.scheme, 'https');
    });

    test('plain http is refused for anything but the local development backend, even in debug', () {
      expect(() => AppConfig.resolve('http://192.168.1.20:8000', debugBuild: true), throwsA(isA<ConfigurationError>()));
      expect(() => AppConfig.resolve('http://backend.test', debugBuild: true), throwsA(isA<ConfigurationError>()));
      expect(AppConfig.resolve('http://127.0.0.1:8000', debugBuild: true).apiBaseUrl.host, '127.0.0.1');
      expect(() => AppConfig.resolve('not a url', debugBuild: true), throwsA(isA<ConfigurationError>()));
    });
  });

  group('user-facing messages never contain backend text', () {
    test('every failure kind has a message in every context', () {
      for (final kind in ApiFailureKind.values) {
        for (final context in FailureContext.values) {
          final message = messageForFailure(ApiFailure(kind, statusCode: 500, code: 'some_code', requestId: 'req-1'), context: context);
          expect(message, isNotEmpty);
          expect(message, isNot(contains('some_code')));
          expect(message, isNot(contains('req-1')));
          expect(message.toLowerCase(), isNot(contains('exception')));
        }
      }
    });

    test('rate limit message uses Retry-After', () {
      expect(messageForFailure(const ApiFailure(ApiFailureKind.rateLimited, retryAfter: Duration(seconds: 540))), contains('9 minutes'));
      expect(messageForFailure(const ApiFailure(ApiFailureKind.rateLimited, retryAfter: Duration(seconds: 30))), contains('30 seconds'));
      expect(messageForFailure(const ApiFailure(ApiFailureKind.rateLimited)), contains('few minutes'));
    });
  });
}
