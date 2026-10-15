// Integration test against the LOCAL DEVELOPMENT backend (backend/deploy/dev/compose.yaml).
//
// It drives the app's real services (Dio, AuthInterceptor, repositories) over real HTTP. Only the
// token store is in memory, because platform secure storage does not exist on the test host.
//
// It is skipped unless both variables are set. The sign-in code is the development stack's test
// code, read from its secrets volume by whoever runs the test - it is not in the app or this file:
//
//   GOSSY_IT_BASE_URL=http://127.0.0.1:8000
//   GOSSY_IT_OTP_CODE=$(docker run --rm -v gossy-dev_gossy-secrets:/s alpine cat /s/auth/test-otp.code)
//   flutter test test/integration/dev_backend_test.dart
//
// Preparation (operator CLI; there is no API to grant the admin role):
//   docker compose -f backend/deploy/dev/compose.yaml exec api \
//     python -m gossy.manage set-role --phone +99900000009 --role admin
//
// Uses only the allow-listed +999 test numbers. No SMS is involved. Not a production test.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/api/api_failure.dart';
import 'package:smart_gossy_culture_app/core/app_config.dart';
import 'package:smart_gossy_culture_app/core/app_services.dart';
import 'package:smart_gossy_culture_app/core/auth/session_controller.dart';
import 'package:smart_gossy_culture_app/core/auth/token_store.dart';
import 'package:smart_gossy_culture_app/core/onboarding/onboarding_repository.dart';

import '../support/fake_backend.dart' show MemoryTokenStore;

const String farmerFresh = '+99900000003';
const String farmerWithFarms = '+99900000002';
const String farmerComplete = '+99900000001';
const String adminPhone = '+99900000009';

final String? baseUrl = Platform.environment['GOSSY_IT_BASE_URL'];
final String? otpCode = Platform.environment['GOSSY_IT_OTP_CODE'];

Matcher failsWith(ApiFailureKind kind, {String? code}) =>
    throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', kind).having((f) => f.code, 'code', code ?? anything));

class Client {
  Client() : tokens = MemoryTokenStore() {
    services = AppServices.create(config: AppConfig.resolve(baseUrl!, debugBuild: true), tokens: tokens);
    services.session.onForcedSignOut = () => forcedSignOuts++;
  }

  final MemoryTokenStore tokens;
  late final AppServices services;
  int forcedSignOuts = 0;

  Future<void> signIn(String phone) async {
    await services.session.requestCode(phone);
    await services.session.verifyCode(phone, otpCode!);
  }
}

/// The same session with an access token the backend will not accept.
class StoredSessionTamper {
  static StoredSession withAccessToken(StoredSession session, String accessToken) => StoredSession(
        accessToken: accessToken,
        accessTokenExpiresAt: session.accessTokenExpiresAt,
        refreshToken: session.refreshToken,
        refreshTokenExpiresAt: session.refreshTokenExpiresAt,
      );
}

/// Test harness only (not app code): an administrator provisions a device and gets its claim code.
Future<({String deviceId, String claimCode})> provisionDevice() async {
  final dio = Dio(BaseOptions(baseUrl: baseUrl!, contentType: Headers.jsonContentType));
  await dio.post<dynamic>('/api/v1/auth/otp/request', data: {'phone': adminPhone});
  final login = await dio.post<dynamic>('/api/v1/auth/otp/verify', data: {'phone': adminPhone, 'code': otpCode});
  final deviceId = 'it-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
  final response = await dio.post<dynamic>(
    '/api/v1/admin/devices',
    data: {'deviceId': deviceId, 'displayName': 'Integration test device'},
    options: Options(headers: {'Authorization': 'Bearer ${(login.data as Map)['accessToken']}'}),
  );
  return (deviceId: deviceId, claimCode: (response.data as Map)['claimCode'] as String);
}

void main() {
  final skip = (baseUrl == null || otpCode == null) ? 'set GOSSY_IT_BASE_URL and GOSSY_IT_OTP_CODE to run against the development backend' : null;

  test('phone -> code request -> verification -> token storage -> authenticated request', () async {
    final client = Client();
    await client.services.session.requestCode(farmerFresh);
    expect(client.tokens.session, isNull);
    await expectLater(client.services.session.verifyCode(farmerFresh, otpCode == '000000' ? '111111' : '000000'), failsWith(ApiFailureKind.unauthorized, code: 'invalid_credentials'));
    expect(client.tokens.session, isNull);
    await client.services.session.verifyCode(farmerFresh, otpCode!);
    expect(client.tokens.session, isNotNull);
    expect(client.tokens.session!.accessTokenExpiresAt.isAfter(DateTime.now().toUtc()), isTrue);
    expect(client.services.session.status, SessionStatus.signedIn);
    final me = await client.services.auth.currentUser();
    expect(me.phone, farmerFresh);
    expect(me.role, 'farmer');
    // a used code does not work a second time
    await expectLater(Client().services.session.verifyCode(farmerFresh, otpCode!), failsWith(ApiFailureKind.unauthorized));
    // a number that is not allow-listed gets the uniform answer and can never sign in
    final stranger = Client();
    await stranger.services.session.requestCode('+99900000777');
    await expectLater(stranger.services.session.verifyCode('+99900000777', otpCode!), failsWith(ApiFailureKind.unauthorized));
  }, skip: skip);

  test('farm onboarding -> device claim -> dashboard decision', () async {
    final device = await provisionDevice();
    final client = Client();
    await client.signIn(farmerFresh);
    final before = await client.services.onboarding.currentState();
    // ignore: avoid_print
    print('IT: $farmerFresh initial onboarding state: ${before.runtimeType}');

    final farm = await client.services.onboarding.createFarm('IT farm ${device.deviceId}');
    expect(farm.id, isNotEmpty);
    expect((await client.services.onboarding.listFarms()).map((f) => f.id), contains(farm.id));
    if (before is NeedsFarm) {
      expect(await client.services.onboarding.currentState(), isA<NeedsDevice>());
    }

    // claim failures: wrong code, a farm that is not the caller's, an unknown device
    await expectLater(client.services.onboarding.claimDevice(deviceId: device.deviceId, claimCode: 'WRONG-CODE-0000', farmId: farm.id), failsWith(ApiFailureKind.notFound, code: 'claim_failed'));
    await expectLater(client.services.onboarding.claimDevice(deviceId: device.deviceId, claimCode: device.claimCode, farmId: '00000000-0000-4000-8000-000000000000'), failsWith(ApiFailureKind.notFound, code: 'not_found'));
    await expectLater(client.services.onboarding.claimDevice(deviceId: 'it-does-not-exist', claimCode: device.claimCode, farmId: farm.id), failsWith(ApiFailureKind.notFound, code: 'claim_failed'));

    final claimed = await client.services.onboarding.claimDevice(deviceId: device.deviceId, claimCode: device.claimCode, farmId: farm.id);
    expect(claimed.deviceId, device.deviceId);
    expect(claimed.registrationState, 'active');
    expect(claimed.farmId, farm.id);
    expect((await client.services.onboarding.listDevices()).map((d) => d.deviceId), contains(device.deviceId));
    expect(await client.services.onboarding.currentState(), isA<OnboardingComplete>());

    // the claim code is one-time: another farmer cannot take the device with it
    final other = Client();
    await other.signIn(farmerWithFarms);
    final otherFarms = await other.services.onboarding.listFarms();
    final otherFarm = otherFarms.isNotEmpty ? otherFarms.first : await other.services.onboarding.createFarm('IT other farm');
    await expectLater(other.services.onboarding.claimDevice(deviceId: device.deviceId, claimCode: device.claimCode, farmId: otherFarm.id), failsWith(ApiFailureKind.notFound, code: 'claim_failed'));
    // ... nor use the first farmer's farm
    await expectLater(other.services.onboarding.claimDevice(deviceId: device.deviceId, claimCode: device.claimCode, farmId: farm.id), failsWith(ApiFailureKind.notFound));
    expect((await other.services.onboarding.listDevices()).map((d) => d.deviceId), isNot(contains(device.deviceId)));
    // ignore: avoid_print
    print('IT: $farmerWithFarms onboarding state: ${(await other.services.onboarding.currentState()).runtimeType}');
  }, skip: skip);

  test('existing farmers are routed by what the backend reports', () async {
    final complete = Client();
    await complete.signIn(farmerComplete);
    final state = await complete.services.onboarding.currentState();
    // ignore: avoid_print
    print('IT: $farmerComplete onboarding state: ${state.runtimeType}');
    expect(state, anyOf(isA<OnboardingComplete>(), isA<NeedsDevice>(), isA<NeedsFarm>()));
  }, skip: skip);

  test('rejected access token: exactly one refresh for concurrent requests; rotation keeps the session', () async {
    final client = Client();
    await client.signIn(farmerFresh);
    final good = client.tokens.session!;
    // The backend no longer accepts the access token (stands in for the 15-minute expiry).
    client.tokens.session = StoredSessionTamper.withAccessToken(good, '${good.accessToken}x');
    final results = await Future.wait([
      client.services.auth.currentUser(),
      client.services.onboarding.listFarms(),
      client.services.onboarding.listDevices(),
      client.services.auth.currentUser(),
      client.services.onboarding.listFarms(),
    ]);
    expect(results, hasLength(5));
    expect(client.services.api.interceptor.refreshRequests, 1);
    expect(client.tokens.session!.refreshToken, isNot(good.refreshToken));
    expect(client.forcedSignOuts, 0);
    // the session is still valid: the backend saw each refresh token once
    expect((await client.services.auth.currentUser()).phone, farmerFresh);
  }, skip: skip);

  test('refresh-token reuse is detected by the backend; the app clears the session and requires sign-in', () async {
    final client = Client();
    await client.signIn(farmerFresh);
    final first = client.tokens.session!;
    client.tokens.session = StoredSessionTamper.withAccessToken(first, '${first.accessToken}x');
    await client.services.auth.currentUser(); // one refresh: first.refreshToken is now used
    final second = client.tokens.session!;
    expect(second.refreshToken, isNot(first.refreshToken));

    // The old pair comes back (e.g. restored device backup) and its access token is not accepted.
    client.tokens.session = StoredSessionTamper.withAccessToken(first, '${first.accessToken}x');
    await expectLater(client.services.auth.currentUser(), failsWith(ApiFailureKind.sessionExpired));
    expect(client.tokens.session, isNull);
    expect(client.services.session.status, SessionStatus.signedOut);
    expect(client.forcedSignOuts, 1);
    expect(client.services.api.interceptor.refreshRequests, 2); // no further attempts

    // The backend revoked the whole session: the newer pair is dead too.
    client.tokens.session = second;
    await expectLater(client.services.auth.currentUser(), failsWith(ApiFailureKind.sessionExpired));
    expect(client.tokens.session, isNull);
  }, skip: skip);

  test('logout revokes the session on the backend and deletes the local tokens', () async {
    final client = Client();
    await client.signIn(farmerFresh);
    final session = client.tokens.session!;
    await client.services.session.logout();
    expect(client.tokens.session, isNull);
    expect(client.services.session.status, SessionStatus.signedOut);
    // the old tokens are no longer accepted by the backend
    client.tokens.session = session;
    await expectLater(client.services.auth.currentUser(), failsWith(ApiFailureKind.sessionExpired));
    // without a session nothing is sent and the caller is told to sign in
    await expectLater(Client().services.onboarding.listFarms(), failsWith(ApiFailureKind.sessionExpired));
  }, skip: skip);

  test('backend not reachable: reported as a network failure, stored session kept', () async {
    final tokens = MemoryTokenStore();
    final good = Client();
    await good.signIn(farmerFresh);
    tokens.session = good.tokens.session;
    final services = AppServices.create(config: AppConfig.resolve('http://127.0.0.1:59999', debugBuild: true), tokens: tokens);
    await expectLater(services.onboarding.listFarms(), failsWith(ApiFailureKind.network));
    expect(await services.session.restore(), SessionRestore.unreachable);
    expect(tokens.session, isNotNull);
    await expectLater(services.session.requestCode(farmerFresh), failsWith(ApiFailureKind.network));
  }, skip: skip);
}
