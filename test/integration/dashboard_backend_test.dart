// Dashboard against the LOCAL DEVELOPMENT backend with real simulator data
// (backend/deploy/dev/compose.yaml, started with `--profile simulator`).
//
//   simulator -> MQTT/TLS -> ingest -> PostgreSQL/TimescaleDB -> REST API -> app services -> Dashboard
//
// Skipped unless GOSSY_IT_BASE_URL and GOSSY_IT_OTP_CODE are set (see dev_backend_test.dart for
// how to obtain the development test code; it is not stored in the app or in this file).
// The simulator's device id defaults to sim-0001 (GOSSY_IT_SIM_DEVICE overrides it).
//
// Only allow-listed +999 test numbers are used. Not a production test.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/api/api_failure.dart';
import 'package:smart_gossy_culture_app/core/dashboard/dashboard_controller.dart';
import 'package:smart_gossy_culture_app/core/dashboard/dashboard_repository.dart';

import 'it_support.dart';

void main() {
  final skip = skipReason;

  test('authenticated farmer -> claimed device -> real telemetry over REST -> correct mapping', () async {
    final services = await signedIn(farmer);
    await ensureSimulatorDeviceClaimed(services);
    final dashboard = services.dashboard;
    await dashboard.load();
    await dashboard.selectDevice(simDevice);
    expect(dashboard.phase, DashboardPhase.ready);
    final data = dashboard.data!;
    expect(data.device!.deviceId, simDevice);
    expect(data.telemetry, isNotNull, reason: 'the simulator must be running (docker compose --profile simulator up -d simulator)');

    // Independent check: the same row fetched without the app's models.
    final raw = await rawClient(farmer);
    final page = (await raw.get<dynamic>('/api/v1/devices/$simDevice/telemetry', queryParameters: {'limit': 50})).data as Map;
    final row = (page['items'] as List).cast<Map>().firstWhere((r) => r['msgId'] == data.telemetry!.msgId);
    expect(data.telemetry!.batteryPct, (row['batteryPct'] as num).toDouble());
    expect(data.telemetry!.moistureRhPct, (row['moistureRhPct'] as num?)?.toDouble());
    expect(data.telemetry!.airTempC, (row['airTempC'] as num?)?.toDouble());
    expect(data.telemetry!.bollsHarvestedTotal, row['bollsHarvestedTotal']);
    expect(data.telemetry!.solarActive, row['solarActive']);
    expect(data.telemetry!.time, DateTime.parse(row['time'] as String).toUtc());
    final device = (await raw.get<dynamic>('/api/v1/devices/$simDevice')).data as Map;
    expect(data.device!.status.state, (device['status'] as Map)['state']);

    // The reading is recent: it really comes from the running simulator.
    final age = DateTime.now().toUtc().difference(data.telemetry!.time);
    expect(age.inSeconds.abs() < 120, isTrue, reason: 'newest telemetry is $age old');
    // ignore: avoid_print
    print('IT-DASH service: device=$simDevice status=${data.device!.status.state} msgId=${data.telemetry!.msgId} time=${data.telemetry!.time.toIso8601String()} '
        'battery=${data.telemetry!.batteryPct} moisture=${data.telemetry!.moistureRhPct} airTemp=${data.telemetry!.airTempC} bolls=${data.telemetry!.bollsHarvestedTotal} solar=${data.telemetry!.solarActive} '
        'latestDetection=${data.latestDetection?.label}/${data.latestDetection?.confidence}');

    // A refresh picks up newer data from the simulator (it publishes every 5 s).
    final firstMsg = data.telemetry!.msgId;
    await Future<void>.delayed(const Duration(seconds: 7));
    await dashboard.load();
    expect(dashboard.data!.telemetry!.msgId, isNot(firstMsg));
    expect(dashboard.data!.telemetry!.time.isAfter(data.telemetry!.time), isTrue);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('device authorization is the backend\'s: another farmer cannot read the device', () async {
    final owner = await signedIn(farmer);
    await ensureSimulatorDeviceClaimed(owner);
    final other = await signedIn(otherFarmer);
    final repository = DashboardRepository(api: other.api);
    expect((await repository.devices()).map((d) => d.deviceId), isNot(contains(simDevice)));
    await expectLater(repository.latestTelemetry(simDevice), throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', ApiFailureKind.notFound)));
    await expectLater(repository.latestDetection(simDevice), throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', ApiFailureKind.notFound)));
    // the other farmer's dashboard shows only their own devices
    await other.dashboard.load();
    expect(other.dashboard.data!.devices.map((d) => d.deviceId), isNot(contains(simDevice)));
  }, skip: skip);

  test('a claimed device without telemetry gives the empty state, not an error', () async {
    final services = await signedIn(farmer);
    final devices = await services.onboarding.listDevices();
    final silent = devices.where((d) => d.deviceId.startsWith('it-')).firstOrNull;
    if (silent == null) {
      // ignore: avoid_print
      print('IT-DASH: no silent test device owned by $farmer; skipping the empty-state check');
      return;
    }
    await services.dashboard.load();
    await services.dashboard.selectDevice(silent.deviceId);
    expect(services.dashboard.phase, DashboardPhase.ready);
    expect(services.dashboard.data!.device!.deviceId, silent.deviceId);
    expect(services.dashboard.data!.telemetry, isNull);
    expect(services.dashboard.data!.latestDetection, isNull);
    expect(services.dashboard.data!.device!.status.state, isNull);
  }, skip: skip);

  test('session invalidated on the backend: dashboard load ends the session, no data kept', () async {
    final services = await signedIn(farmer);
    await services.dashboard.load();
    expect(services.dashboard.data, isNotNull);
    var forced = 0;
    services.session.onForcedSignOut = () => forced++;
    // The session is revoked on the backend (here: logout sent with the same session by another
    // client; the harness reads the token from the in-memory test store and never prints it).
    final raw = Dio(BaseOptions(baseUrl: baseUrl!, validateStatus: (_) => true));
    final revoked = await raw.post<dynamic>('/api/v1/auth/logout', options: Options(headers: {'Authorization': 'Bearer ${stores[services]!.session!.accessToken}'}));
    expect(revoked.statusCode, 204);
    await services.dashboard.load();
    expect(forced, 1);
    expect(services.dashboard.data, isNull);
    expect(services.dashboard.phase, DashboardPhase.idle);
  }, skip: skip);
}
