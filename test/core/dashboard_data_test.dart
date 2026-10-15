import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/api/api_failure.dart';
import 'package:smart_gossy_culture_app/core/dashboard/dashboard_controller.dart';
import 'package:smart_gossy_culture_app/core/dashboard/dashboard_repository.dart';
import 'package:smart_gossy_culture_app/core/formatting.dart';
import 'package:smart_gossy_culture_app/core/models.dart';

import '../support/fake_backend.dart';

Matcher failsWith(ApiFailureKind kind) => throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', kind));

TestApp appWithDevice({String deviceId = 'bb-0001'}) {
  final app = TestApp()..signIn();
  app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
  app.backend.devices.add(FakeBackend.device(deviceId, displayName: 'Field unit', state: 'online', lastSeenAt: '2026-10-01T15:59:58Z'));
  return app;
}

void main() {
  group('response mapping (contract -> Flutter models)', () {
    test('device: identity, claim time and status', () async {
      final app = appWithDevice();
      final device = (await DashboardRepository(api: app.services.api).devices()).single;
      expect(device.deviceId, 'bb-0001');
      expect(device.displayName, 'Field unit');
      expect(device.farmId, 'farm-1');
      expect(device.registrationState, 'active');
      expect(device.claimedAt, DateTime.utc(2026, 10, 1));
      expect(device.status.state, 'online');
      expect(device.status.lastSeenAt, DateTime.utc(2026, 10, 1, 15, 59, 58));
    });

    test('a device that has never reported has a null status, not a default', () async {
      final app = TestApp()..signIn();
      app.backend.devices.add(FakeBackend.device('bb-0009'));
      final device = (await DashboardRepository(api: app.services.api).devices()).single;
      expect(device.status.state, isNull);
      expect(device.status.lastSeenAt, isNull);
    });

    test('telemetry: every field is taken as sent; integers are accepted for numbers', () async {
      final app = appWithDevice();
      app.backend.telemetry['bb-0001'] = [
        FakeBackend.telemetryRow(time: '2026-10-01T15:59:55.250+00:00', batteryPct: 91, moistureRhPct: 54.3, airTempC: 31.5, bollsHarvestedTotal: 1287, solarActive: true),
        FakeBackend.telemetryRow(time: '2026-10-01T15:59:50Z', batteryPct: 91.4, bollsHarvestedTotal: 1286),
      ];
      final point = (await DashboardRepository(api: app.services.api).latestTelemetry('bb-0001'))!;
      expect(point.time, DateTime.utc(2026, 10, 1, 15, 59, 55, 250));
      expect(point.batteryPct, 91.0);
      expect(point.moistureRhPct, 54.3);
      expect(point.airTempC, 31.5);
      expect(point.bollsHarvestedTotal, 1287);
      expect(point.solarActive, isTrue);
      final call = app.backend.calls.last;
      expect(call.path, '/api/v1/devices/bb-0001/telemetry');
      expect(call.query, {'limit': '1'});
    });

    test('telemetry: readings the device did not send stay null (never zero)', () async {
      final app = appWithDevice();
      app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:59:55Z', batteryPct: 12.5)];
      final point = (await DashboardRepository(api: app.services.api).latestTelemetry('bb-0001'))!;
      expect(point.batteryPct, 12.5);
      expect(point.moistureRhPct, isNull);
      expect(point.airTempC, isNull);
      expect(point.bollsHarvestedTotal, isNull);
      expect(point.solarActive, isNull);
    });

    test('telemetry: a device without a battery monitor (Phase II cart) still has its other readings', () async {
      final app = appWithDevice();
      app.backend.overrides['/api/v1/devices/bb-0001/telemetry'] = const FakeReply(200, {
        'items': [
          {'time': '2026-10-01T15:59:55Z', 'msgId': 'm', 'airTempC': 30.5}
        ]
      });
      final point = (await DashboardRepository(api: app.services.api).latestTelemetry('bb-0001'))!;
      expect(point.batteryPct, isNull);
      expect(point.airTempC, 30.5);
    });

    test('detection: label and confidence as reported by the device', () async {
      final app = appWithDevice();
      app.backend.detections['bb-0001'] = [FakeBackend.detectionRow(deviceId: 'bb-0001', detectedAt: '2026-10-01T15:40:00Z', label: 'leaf_curl_virus', confidence: 0.87)];
      final detection = (await DashboardRepository(api: app.services.api).latestDetection('bb-0001'))!;
      expect(detection.label, 'leaf_curl_virus');
      expect(detection.confidence, 0.87);
      expect(detection.detectedAt, DateTime.utc(2026, 10, 1, 15, 40));
      expect(app.backend.calls.last.query, {'deviceId': 'bb-0001', 'limit': '1'});
    });

    test('empty pages map to null', () async {
      final app = appWithDevice();
      final repository = DashboardRepository(api: app.services.api);
      expect(await repository.latestTelemetry('bb-0001'), isNull);
      expect(await repository.latestDetection('bb-0001'), isNull);
    });

    test('malformed replies are refused, not guessed', () async {
      final app = appWithDevice();
      final repository = DashboardRepository(api: app.services.api);
      final bad = <String, FakeReply>{
        'not a page': const FakeReply(200, [1, 2, 3]),
        'items not a list': const FakeReply(200, {'items': 'x'}),
        'missing msgId': const FakeReply(200, {'items': [{'time': '2026-10-01T15:59:55Z', 'batteryPct': 91}]}),
        'battery as text': const FakeReply(200, {'items': [{'time': '2026-10-01T15:59:55Z', 'msgId': 'm', 'batteryPct': '91'}]}),
        'bad timestamp': const FakeReply(200, {'items': [{'time': 'yesterday', 'msgId': 'm', 'batteryPct': 91}]}),
        'boll count as text': const FakeReply(200, {'items': [{'time': '2026-10-01T15:59:55Z', 'msgId': 'm', 'batteryPct': 91, 'bollsHarvestedTotal': 'many'}]}),
        'solar as number': const FakeReply(200, {'items': [{'time': '2026-10-01T15:59:55Z', 'msgId': 'm', 'batteryPct': 91, 'solarActive': 1}]}),
      };
      for (final entry in bad.entries) {
        app.backend.overrides['/api/v1/devices/bb-0001/telemetry'] = entry.value;
        await expectLater(repository.latestTelemetry('bb-0001'), failsWith(ApiFailureKind.invalidResponse), reason: entry.key);
      }
      app.backend.overrides['/api/v1/devices'] = const FakeReply(200, [{'deviceId': 'bb-0001', 'registrationState': 'active'}]); // no status object
      await expectLater(repository.devices(), failsWith(ApiFailureKind.invalidResponse));
      app.backend.overrides['/api/v1/detections'] = const FakeReply(200, {'items': [{'id': 'd', 'deviceId': 'bb-0001', 'detectedAt': '2026-10-01T15:40:00Z', 'label': 'bollworm'}]});
      await expectLater(repository.latestDetection('bb-0001'), failsWith(ApiFailureKind.invalidResponse));
    });
  });

  group('authenticated, device-specific requests', () {
    test('every dashboard call carries the bearer token and addresses the selected device', () async {
      final app = appWithDevice();
      await app.services.dashboard.load();
      expect(app.backend.calls.map((c) => '$c').toSet(), {'GET /api/v1/devices', 'GET /api/v1/devices/bb-0001/telemetry', 'GET /api/v1/detections'});
      for (final call in app.backend.calls) {
        expect(call.authorization, 'Bearer access-1', reason: '$call');
        expect(call.method, 'GET');
      }
      expect(app.backend.calls.firstWhere((c) => c.path == '/api/v1/detections').query['deviceId'], 'bb-0001');
    });

    test('without a session nothing is sent', () async {
      final app = TestApp();
      await app.services.dashboard.load();
      expect(app.backend.calls, isEmpty);
    });

    test('the device shown is the most recently claimed one; another can be selected', () async {
      final app = TestApp()..signIn();
      app.backend.devices
        ..add(FakeBackend.device('bb-old', claimedAt: '2026-09-01T00:00:00Z'))
        ..add(FakeBackend.device('bb-new', claimedAt: '2026-10-01T00:00:00Z'))
        ..add(FakeBackend.device('bb-mid', claimedAt: '2026-09-15T00:00:00Z'));
      app.backend.telemetry['bb-new'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 80)];
      app.backend.telemetry['bb-old'] = [FakeBackend.telemetryRow(time: '2026-10-01T14:00:00Z', batteryPct: 20)];
      final dashboard = app.services.dashboard;
      await dashboard.load();
      expect(dashboard.data!.device!.deviceId, 'bb-new');
      expect(dashboard.data!.telemetry!.batteryPct, 80);

      await dashboard.selectDevice('bb-old');
      expect(dashboard.data!.device!.deviceId, 'bb-old');
      expect(dashboard.data!.telemetry!.batteryPct, 20);
      // the selection is kept across refreshes
      await dashboard.load();
      expect(dashboard.data!.device!.deviceId, 'bb-old');
      expect(app.backend.calls.where((c) => c.path.contains('bb-mid')), isEmpty);
    });

    test('a device the backend no longer lists is not requested', () async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await dashboard.load();
      app.backend.devices.clear(); // detached / transferred on the backend
      await dashboard.load();
      expect(dashboard.phase, DashboardPhase.ready);
      expect(dashboard.data!.devices, isEmpty);
      expect(dashboard.data!.device, isNull);
      expect(dashboard.data!.telemetry, isNull);
      expect(app.backend.calls.last.path, '/api/v1/devices');
    });
  });

  group('controller states', () {
    test('first load: loading -> error on failure; retry -> ready', () async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      final phases = <DashboardPhase>[];
      dashboard.addListener(() => phases.add(dashboard.phase));
      app.backend.outage = Outage.offline;
      await dashboard.load();
      expect(phases, [DashboardPhase.loading, DashboardPhase.error]);
      expect(dashboard.failure!.kind, ApiFailureKind.network);
      expect(dashboard.data, isNull);
      app.backend.outage = Outage.none;
      await dashboard.load();
      expect(dashboard.phase, DashboardPhase.ready);
      expect(dashboard.failure, isNull);
    });

    test('a failed refresh keeps the last loaded data and records the failure', () async {
      final now = DateTime(2026, 10, 1, 21, 30);
      final app = TestApp(clock: () => now)..signIn(accessTokenExpiresAt: DateTime.utc(2099));
      app.backend.devices.add(FakeBackend.device('bb-0001'));
      app.backend.telemetry['bb-0001'] = [FakeBackend.telemetryRow(time: '2026-10-01T15:59:55Z', batteryPct: 77)];
      final dashboard = app.services.dashboard;
      await dashboard.load();
      app.backend.overrides['/api/v1/devices/bb-0001/telemetry'] = FakeReply.error(503, 'service_unavailable');
      await dashboard.load();
      expect(dashboard.phase, DashboardPhase.ready);
      expect(dashboard.failure!.kind, ApiFailureKind.unavailable);
      expect(dashboard.data!.telemetry!.batteryPct, 77);
      expect(dashboard.data!.loadedAt, now);
    });

    test('overlapping loads are ignored: one set of requests', () async {
      final app = appWithDevice();
      final dashboard = app.services.dashboard;
      await Future.wait([dashboard.load(), dashboard.load(), dashboard.load()]);
      expect(app.backend.count('GET', '/api/v1/devices'), 1);
    });

    test('there is no polling: nothing is requested unless load is called', () async {
      final app = appWithDevice();
      await app.services.dashboard.load();
      final sent = app.backend.calls.length;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(app.backend.calls.length, sent);
    });

    test('session expiry while loading: session cleared by the existing mechanism, no error state', () async {
      final app = appWithDevice();
      await app.services.session.restore();
      var forced = 0;
      app.services.session.onForcedSignOut = () => forced++;
      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      await app.services.dashboard.load();
      expect(forced, 1);
      expect(app.tokens.session, isNull);
      expect(app.services.dashboard.phase, DashboardPhase.idle); // reset on sign-out
      expect(app.services.dashboard.data, isNull);
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
    });

    test('sign-out forgets the previous user\'s dashboard data', () async {
      final app = appWithDevice();
      await app.services.session.restore();
      await app.services.dashboard.load();
      expect(app.services.dashboard.data, isNotNull);
      await app.services.session.logout();
      expect(app.services.dashboard.data, isNull);
      expect(app.services.dashboard.phase, DashboardPhase.idle);
    });

    test('HTTP errors map to failures the UI can explain', () async {
      for (final entry in {403: ApiFailureKind.forbidden, 404: ApiFailureKind.notFound, 429: ApiFailureKind.rateLimited, 500: ApiFailureKind.server, 503: ApiFailureKind.unavailable}.entries) {
        final app = appWithDevice();
        app.backend.overrides['/api/v1/devices'] = FakeReply.error(entry.key, 'some_code');
        await app.services.dashboard.load();
        expect(app.services.dashboard.phase, DashboardPhase.error, reason: '${entry.key}');
        expect(app.services.dashboard.failure!.kind, entry.value);
      }
    });
  });

  group('formatting shows values without altering them', () {
    test('percent, count, label, confidence', () {
      expect(formatPercent(95), '95%');
      expect(formatPercent(68.4), '68.4%');
      expect(formatPercent(0), '0%');
      expect(formatPercent(100), '100%');
      expect(formatCount(0), '0');
      expect(formatCount(999), '999');
      expect(formatCount(1250), '1,250');
      expect(formatCount(1234567), '1,234,567');
      expect(formatDetectionLabel('bollworm'), 'Bollworm');
      expect(formatDetectionLabel('leaf_curl_virus'), 'Leaf curl virus');
      expect(formatConfidence(0.87), '87%');
      expect(formatConfidence(1), '100%');
    });

    test('dates', () {
      expect(formatDateHeader(DateTime(2026, 10, 1)), 'THURSDAY, OCTOBER 1, 2026');
      expect(formatDateHeader(DateTime(2025, 9, 7)), 'SUNDAY, SEPTEMBER 7, 2025');
      expect(formatDateTime(DateTime(2026, 10, 1, 21, 5)), '1 Oct 2026, 21:05');
    });
  });

  test('Device model keeps working for onboarding replies', () {
    final device = Device.fromJson(FakeBackend.device('bb-0001').cast<String, dynamic>());
    expect(device.deviceId, 'bb-0001');
  });
}
