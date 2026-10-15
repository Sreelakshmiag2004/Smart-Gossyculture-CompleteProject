import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/api/api_failure.dart';
import 'package:smart_gossy_culture_app/core/auth/session_controller.dart';
import 'package:smart_gossy_culture_app/core/auth/token_store.dart';

import '../support/fake_backend.dart';

Matcher failsWith(ApiFailureKind kind) => throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', kind));

void main() {
  group('sign-in and token storage', () {
    test('successful verification stores both tokens; nothing is stored before', () async {
      final app = TestApp();
      await app.services.session.requestCode(FakeBackend.allowedPhone);
      expect(app.tokens.session, isNull);
      await app.services.session.verifyCode(FakeBackend.allowedPhone, app.backend.currentCode);
      expect(app.tokens.session!.accessToken, 'access-1');
      expect(app.tokens.session!.refreshToken, 'refresh-token-number-1');
      expect(app.tokens.writes, 1);
      expect(app.services.session.status, SessionStatus.signedIn);
      expect(app.services.session.user!.phone, FakeBackend.allowedPhone);
    });

    test('a wrong code stores nothing and reports invalid credentials', () async {
      final app = TestApp();
      await app.services.session.requestCode(FakeBackend.allowedPhone);
      await expectLater(app.services.session.verifyCode(FakeBackend.allowedPhone, '000000'), failsWith(ApiFailureKind.unauthorized));
      expect(app.tokens.session, isNull);
      expect(app.services.session.status, SessionStatus.unknown);
    });

    test('sign-in calls carry no Authorization header', () async {
      final app = TestApp()..signIn();
      await app.services.session.requestCode(FakeBackend.allowedPhone);
      expect(app.backend.calls.single.authorization, isNull);
    });

    test('SecureTokenStore keeps the pair in secure storage and deletes it on clear', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({});
      final store = SecureTokenStore();
      expect(await store.read(), isNull);
      await store.write(StoredSession(accessToken: 'a-1', accessTokenExpiresAt: DateTime.utc(2030), refreshToken: 'r-1', refreshTokenExpiresAt: DateTime.utc(2031)));
      final loaded = await store.read();
      expect(loaded!.accessToken, 'a-1');
      expect(loaded.refreshToken, 'r-1');
      expect(loaded.accessTokenExpiresAt, DateTime.utc(2030));
      expect(await const FlutterSecureStorage().readAll(), hasLength(1)); // one entry: the pair is replaced as a whole
      await store.clear();
      expect(await store.read(), isNull);
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
    });

    test('an unreadable stored entry is treated as signed out and removed', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      FlutterSecureStorage.setMockInitialValues({SecureTokenStore.storageKey: 'not json'});
      final store = SecureTokenStore();
      expect(await store.read(), isNull);
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
    });

    test('token objects do not reveal tokens when printed', () {
      final session = StoredSession(accessToken: 'SECRET-A', accessTokenExpiresAt: DateTime.utc(2030), refreshToken: 'SECRET-R', refreshTokenExpiresAt: DateTime.utc(2031));
      expect('$session', isNot(contains('SECRET')));
      expect('${const ApiFailure(ApiFailureKind.unauthorized, statusCode: 401, code: 'x')}', isNot(contains('Bearer')));
    });
  });

  group('logout', () {
    test('revokes the session on the backend and deletes the tokens', () async {
      final app = TestApp()..signIn();
      await app.services.session.logout();
      expect(app.backend.count('POST', '/api/v1/auth/logout'), 1);
      expect(app.backend.calls.last.authorization, 'Bearer access-1');
      expect(app.backend.sessionRevoked, isTrue);
      expect(app.tokens.session, isNull);
      expect(app.services.session.status, SessionStatus.signedOut);
    });

    test('deletes the tokens even when the backend cannot be reached', () async {
      final app = TestApp()..signIn();
      app.backend.outage = Outage.offline;
      await app.services.session.logout();
      expect(app.tokens.session, isNull);
      expect(app.services.session.status, SessionStatus.signedOut);
    });
  });

  group('expired access token', () {
    test('rejected by the backend (401): refreshed once, request repeated once, new pair stored', () async {
      final app = TestApp()..signIn();
      app.backend.expireAccessToken();
      final user = await app.services.auth.currentUser();
      expect(user.phone, FakeBackend.allowedPhone);
      expect(app.backend.calls.map((c) => '$c').toList(), ['GET /api/v1/me', 'POST /api/v1/auth/refresh', 'GET /api/v1/me']);
      expect(app.backend.calls.last.authorization, 'Bearer access-2');
      expect(app.tokens.session!.accessToken, 'access-2');
      expect(app.tokens.session!.refreshToken, 'refresh-token-number-2');
    });

    test('known to be expired locally: refreshed BEFORE the request is sent', () async {
      final now = DateTime.utc(2026, 10, 1, 12);
      final app = TestApp(clock: () => now)..signIn(accessTokenExpiresAt: now.subtract(const Duration(minutes: 1)));
      await app.services.auth.currentUser();
      expect(app.backend.calls.map((c) => '$c').toList(), ['POST /api/v1/auth/refresh', 'GET /api/v1/me']);
    });

    test('the refresh call itself carries the refresh token and no Authorization header', () async {
      final app = TestApp()..signIn();
      app.backend.expireAccessToken();
      await app.services.auth.currentUser();
      final refresh = app.backend.calls.firstWhere((c) => c.path == '/api/v1/auth/refresh');
      expect(refresh.authorization, isNull);
      expect(refresh.body, {'refreshToken': 'refresh-token-number-1'});
    });
  });

  group('single refresh operation', () {
    test('five concurrent requests with an expired token cause exactly one refresh', () async {
      final app = TestApp()..signIn();
      app.backend.expireAccessToken();
      app.backend.refreshDelay = const Duration(milliseconds: 50);
      final results = await Future.wait([
        app.services.auth.currentUser(),
        app.services.onboarding.listFarms(),
        app.services.onboarding.listDevices(),
        app.services.auth.currentUser(),
        app.services.onboarding.listFarms(),
      ]);
      expect(results, hasLength(5));
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.services.api.interceptor.refreshRequests, 1);
      expect(app.backend.sessionRevoked, isFalse, reason: 'a second refresh with the same token would have revoked the session');
      expect(app.tokens.session!.refreshToken, 'refresh-token-number-2');
    });

    test('five concurrent requests with a locally expired token also cause exactly one refresh', () async {
      final now = DateTime.utc(2026, 10, 1, 12);
      final app = TestApp(clock: () => now)..signIn(accessTokenExpiresAt: now.subtract(const Duration(seconds: 1)));
      app.backend.refreshDelay = const Duration(milliseconds: 50);
      await Future.wait([for (var i = 0; i < 5; i++) app.services.auth.currentUser()]);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.backend.sessionRevoked, isFalse);
    });

    test('a later expiry triggers a new, again single, refresh with the NEW refresh token', () async {
      final app = TestApp()..signIn();
      app.backend.expireAccessToken();
      await app.services.auth.currentUser();
      app.backend.expireAccessToken();
      await Future.wait([app.services.auth.currentUser(), app.services.onboarding.listFarms()]);
      final refreshes = app.backend.calls.where((c) => c.path == '/api/v1/auth/refresh').map((c) => (c.body! as Map)['refreshToken']).toList();
      expect(refreshes, ['refresh-token-number-1', 'refresh-token-number-2']);
      expect(app.backend.sessionRevoked, isFalse);
    });
  });

  group('refresh failure', () {
    test('backend unavailable during refresh: reported, tokens kept, not retried', () async {
      final app = TestApp()..signIn();
      app.backend.expireAccessToken();
      app.backend.overrides['/api/v1/auth/refresh'] = FakeReply.error(503, 'service_unavailable');
      await expectLater(app.services.auth.currentUser(), failsWith(ApiFailureKind.unavailable));
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.tokens.session, isNotNull, reason: 'a temporary failure must not sign the user out');
      expect(app.tokens.clears, 0);
    });

    test('network failure during refresh: reported, tokens kept, not retried', () async {
      final now = DateTime.utc(2026, 10, 1, 12);
      final app = TestApp(clock: () => now)..signIn(accessTokenExpiresAt: now.subtract(const Duration(minutes: 1)));
      app.backend.outage = Outage.offline;
      await expectLater(app.services.auth.currentUser(), failsWith(ApiFailureKind.network));
      expect(app.backend.calls.map((c) => '$c').toList(), ['POST /api/v1/auth/refresh']);
      expect(app.tokens.session, isNotNull);
      // Once the network is back the same (unused) refresh token still works.
      app.backend.outage = Outage.none;
      await app.services.auth.currentUser();
      expect(app.backend.sessionRevoked, isFalse);
    });

    test('an unexpected refresh reply is reported and tokens are kept', () async {
      final app = TestApp()..signIn();
      app.backend.expireAccessToken();
      app.backend.overrides['/api/v1/auth/refresh'] = const FakeReply(200, {'unexpected': true});
      await expectLater(app.services.auth.currentUser(), failsWith(ApiFailureKind.invalidResponse));
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.tokens.session, isNotNull);
    });
  });

  group('session invalidation', () {
    test('refresh token rejected: tokens deleted, session ended, no further refresh attempts', () async {
      final app = TestApp()..signIn();
      var forcedSignOuts = 0;
      app.services.session.onForcedSignOut = () => forcedSignOuts++;
      await app.services.session.restore(); // signed in
      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      await expectLater(app.services.onboarding.listFarms(), failsWith(ApiFailureKind.sessionExpired));
      expect(app.tokens.session, isNull);
      expect(app.services.session.status, SessionStatus.signedOut);
      expect(forcedSignOuts, 1);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      // With no stored session nothing more is sent.
      final sent = app.backend.calls.length;
      await expectLater(app.services.onboarding.listFarms(), failsWith(ApiFailureKind.sessionExpired));
      expect(app.backend.calls.length, sent);
    });

    test('refresh-token reuse (stale token presented): backend revokes, app clears the session', () async {
      final app = TestApp()..signIn();
      final stale = app.tokens.session!;
      app.backend.expireAccessToken();
      await app.services.auth.currentUser(); // rotates to pair 2
      app.tokens.session = stale; // e.g. a restored backup holding the old pair
      await expectLater(app.services.auth.currentUser(), failsWith(ApiFailureKind.sessionExpired));
      expect(app.backend.sessionRevoked, isTrue);
      expect(app.tokens.session, isNull);
    });

    test('still 401 after a successful refresh: treated as an ended session, request not repeated again', () async {
      final app = TestApp()..signIn();
      app.backend.expireAccessToken();
      app.backend.overrides['/api/v1/farms'] = FakeReply.error(401, 'unauthenticated');
      await expectLater(app.services.onboarding.listFarms(), failsWith(ApiFailureKind.sessionExpired));
      expect(app.backend.count('GET', '/api/v1/farms'), 2);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.tokens.session, isNull);
    });

    test('restore at start-up: rejected stored session -> expired; unreachable backend -> tokens kept', () async {
      final expired = TestApp()..signIn();
      expired.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      expect(await expired.services.session.restore(), SessionRestore.expired);
      expect(expired.tokens.session, isNull);

      final offline = TestApp()..signIn();
      offline.backend.outage = Outage.offline;
      expect(await offline.services.session.restore(), SessionRestore.unreachable);
      expect(offline.tokens.session, isNotNull);

      expect(await TestApp().services.session.restore(), SessionRestore.none);
    });
  });

  group('HTTP status handling', () {
    final cases = <int, ApiFailureKind>{
      400: ApiFailureKind.badRequest,
      403: ApiFailureKind.forbidden,
      404: ApiFailureKind.notFound,
      409: ApiFailureKind.conflict,
      422: ApiFailureKind.badRequest,
      429: ApiFailureKind.rateLimited,
      500: ApiFailureKind.server,
      503: ApiFailureKind.unavailable,
    };
    for (final entry in cases.entries) {
      test('HTTP ${entry.key} -> ${entry.value.name}', () async {
        final app = TestApp()..signIn();
        app.backend.overrides['/api/v1/farms'] = FakeReply.error(entry.key, 'some_code', headers: {'retry-after': '120'});
        try {
          await app.services.onboarding.listFarms();
          fail('expected a failure');
        } on ApiFailure catch (failure) {
          expect(failure.kind, entry.value);
          expect(failure.statusCode, entry.key);
          expect(failure.code, 'some_code');
          expect(failure.requestId, 'req-test');
          if (entry.key == 429) expect(failure.retryAfter, const Duration(seconds: 120));
        }
        expect(app.tokens.session, isNotNull);
      });
    }

    test('HTTP 401 on a sign-in call is "unauthorized", not a session problem', () async {
      final app = TestApp();
      await expectLater(app.services.session.verifyCode(FakeBackend.allowedPhone, '123456'), failsWith(ApiFailureKind.unauthorized));
    });

    test('connection failure -> network; timeout -> timeout', () async {
      final app = TestApp()..signIn();
      app.backend.outage = Outage.offline;
      await expectLater(app.services.onboarding.listFarms(), failsWith(ApiFailureKind.network));
      app.backend.outage = Outage.timeout;
      await expectLater(app.services.onboarding.listFarms(), failsWith(ApiFailureKind.timeout));
      await expectLater(app.services.session.requestCode(FakeBackend.allowedPhone), failsWith(ApiFailureKind.timeout));
    });

    test('a reply that does not match the contract -> invalidResponse', () async {
      final app = TestApp()..signIn();
      app.backend.overrides['/api/v1/farms'] = const FakeReply(200, {'not': 'a list'});
      await expectLater(app.services.onboarding.listFarms(), failsWith(ApiFailureKind.invalidResponse));
    });
  });
}
