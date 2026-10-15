// Phase 5B: alerts against the LOCAL DEVELOPMENT backend with the running simulator
// (backend/deploy/dev/compose.yaml, started with `--profile simulator`).
//
//   simulator -> MQTT/TLS -> ingest (creates the alert with the message) -> PostgreSQL
//             -> REST /api/v1/alerts            -> app alerts controller
//             -> NOTIFY -> WebSocket alerts[]   -> app live connection -> app alerts controller
//
// Skipped unless GOSSY_IT_BASE_URL and GOSSY_IT_OTP_CODE are set (see it_support.dart).
// Only allow-listed +999 test numbers are used. Not a production test.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/alerts/alerts_controller.dart';
import 'package:smart_gossy_culture_app/core/alerts/alerts_repository.dart';
import 'package:smart_gossy_culture_app/core/api/api_failure.dart';
import 'package:smart_gossy_culture_app/core/app_services.dart';
import 'package:smart_gossy_culture_app/core/auth/session_controller.dart';
import 'package:smart_gossy_culture_app/core/models.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';

import 'it_support.dart';

Future<void> until(bool Function() condition, {required Duration timeout, required String what}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out after $timeout waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Counts the REST requests the app sends (to tell a live alert from a reload).
int Function() countRequests(AppServices services) {
  var sent = 0;
  services.api.authed.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    sent++;
    handler.next(options);
  }));
  return () => sent;
}

/// What the Dashboard page does when it opens: live wanted, snapshot and alerts loaded.
Future<AppServices> dashboardOnSimulator() async {
  final services = await signedIn(farmer);
  await ensureSimulatorDeviceClaimed(services);
  final dashboard = services.dashboard..attachLive();
  await Future.wait([dashboard.load(), services.alerts.load()]);
  if (dashboard.data!.device!.deviceId != simDevice) await dashboard.selectDevice(simDevice);
  addTearDown(dashboard.detachLive);
  await until(() => dashboard.liveState == LiveState.connected, timeout: const Duration(seconds: 20), what: 'the live connection');
  // the re-read that follows the start of the stream
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  await until(() => !services.alerts.busy && !dashboard.busy, timeout: const Duration(seconds: 20), what: 'the re-read after the stream started');
  return services;
}

void expectSameAsBackend(Alert alert, Map<dynamic, dynamic> row) {
  expect(alert.id, row['id']);
  expect(alert.type, row['type']);
  expect(alert.severity, row['severity']);
  expect(alert.status, row['status']);
  expect(alert.deviceId, row['deviceId']);
  expect(alert.occurredAt, DateTime.parse(row['occurredAt'] as String).toUtc());
  expect(alert.createdAt, DateTime.parse(row['createdAt'] as String).toUtc());
  expect(alert.sourceMsgId, row['sourceMsgId']);
  expect(alert.details, row['details']);
  expect(alert.acknowledgedAt, row['acknowledgedAt'] == null ? null : DateTime.parse(row['acknowledgedAt'] as String).toUtc());
}

void main() {
  final skip = skipReason;

  test('REST: the app\'s alerts are the backend\'s alerts, field by field; open = the backend\'s status', () async {
    final services = await signedIn(farmer);
    await ensureSimulatorDeviceClaimed(services);
    final alerts = services.alerts;
    await alerts.load();
    expect(alerts.phase, AlertsPhase.ready);
    expect(alerts.failure, isNull);
    expect(alerts.alerts, isNotEmpty, reason: 'the simulator reports detections; the backend turns each into an alert');

    // Independent check: the same page fetched without the app's models.
    final raw = await rawClient(farmer);
    final page = (await raw.get<dynamic>('/api/v1/alerts', queryParameters: {'limit': AlertsController.pageSize})).data as Map;
    final rows = {for (final row in (page['items'] as List).cast<Map>()) row['id']: row};
    var compared = 0;
    for (final alert in alerts.alerts) {
      final row = rows[alert.id];
      if (row == null) continue; // created between the two requests
      // an alert acknowledged between the two requests by another test run is not expected here
      expectSameAsBackend(alert, row);
      compared++;
    }
    expect(compared, greaterThan(0));
    expect(alerts.alerts.every((a) => {Alert.pestDetected, Alert.sprayPerformed, Alert.deviceOffline}.contains(a.type)), isTrue, reason: 'the backend has exactly these three types');
    final devices = (await services.onboarding.listDevices()).map((d) => d.deviceId).toSet();
    expect(alerts.alerts.every((a) => devices.contains(a.deviceId)), isTrue, reason: 'only the caller\'s devices');

    final open = (await raw.get<dynamic>('/api/v1/alerts', queryParameters: {'status': 'open', 'limit': AlertsController.openQueryLimit})).data as Map;
    expect(alerts.openCountIsMinimum, open['nextCursor'] != null);
    if (!alerts.openCountIsMinimum) expect((alerts.openCount - (open['items'] as List).length).abs() <= 2, isTrue, reason: 'alerts created between the two reads');
    // ignore: avoid_print
    print('IT-ALERT rest: alerts=${alerts.alerts.length} hasMore=${alerts.hasMore} comparedWithBackend=$compared openCount=${alerts.openCount}${alerts.openCountIsMinimum ? '+' : ''} '
        'newest=${alerts.alerts.first.id} type=${alerts.alerts.first.type} status=${alerts.alerts.first.status} device=${alerts.alerts.first.deviceId}');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('live: an alert created from a simulator detection arrives in alerts[] and is listed once; acknowledging it updates the backend', () async {
    final services = await dashboardOnSimulator();
    final alerts = services.alerts;
    final sent = countRequests(services);
    final known = {for (final alert in alerts.alerts) alert.id};
    final attempts = services.live.connectAttempts;
    final requestsBefore = sent();

    // The simulator reports a detection with probability 0.1 per 5 s tick; the backend creates
    // a pest_detected alert in the same transaction and sends it inside the live event.
    await until(() => alerts.alerts.any((a) => !known.contains(a.id)), timeout: const Duration(minutes: 5), what: 'a live alert (simulator pest probability 0.1 per tick)');
    final live = alerts.alerts.firstWhere((a) => !known.contains(a.id));
    expect(sent(), requestsBefore, reason: 'the alert arrived over the live channel, not through a REST request');
    expect(services.live.connectAttempts, attempts, reason: 'on the dashboard\'s existing connection');
    expect(alerts.alerts.where((a) => a.id == live.id), hasLength(1));
    expect(live.isOpen, isTrue);
    expect(live.deviceId, simDevice);

    // The same alert as the backend serves it over REST (independent of the app's models).
    final raw = await rawClient(farmer);
    final row = (await raw.get<dynamic>('/api/v1/alerts/${live.id}')).data as Map;
    expectSameAsBackend(live, row);
    // ignore: avoid_print
    print('IT-ALERT live: id=${live.id} type=${live.type} severity=${live.severity} status=${live.status} device=${live.deviceId} sourceMsgId=${live.sourceMsgId} details=${live.details} '
        'occurredAt=${live.occurredAt.toIso8601String()} restRequestsWhileWaiting=${sent() - requestsBefore} connectionAttempts=${services.live.connectAttempts - attempts}');

    // A REST refresh now returns the same alert: still one entry.
    await alerts.load();
    expect(alerts.alerts.where((a) => a.id == live.id), hasLength(1));

    // Acknowledge it: REST only.
    final openBefore = alerts.openCount;
    final requestsBeforeAck = sent();
    expect(await alerts.acknowledge(live.id), isNull);
    expect(sent(), requestsBeforeAck + 1, reason: 'one request: the acknowledgement');
    final shown = alerts.alerts.firstWhere((a) => a.id == live.id);
    expect(shown.isAcknowledged, isTrue);
    expect(shown.acknowledgedAt, isNotNull);
    if (!alerts.openCountIsMinimum) expect(alerts.openCount, lessThan(openBefore + 1));
    final after = (await raw.get<dynamic>('/api/v1/alerts/${live.id}')).data as Map;
    expect(after['status'], 'acknowledged');
    expectSameAsBackend(shown, after);

    // Idempotent on the backend: the first acknowledgement time is kept.
    expect(await alerts.acknowledge(live.id), isNull);
    expect(alerts.alerts.firstWhere((a) => a.id == live.id).acknowledgedAt, shown.acknowledgedAt);
    // A refresh does not make it unread again.
    await alerts.load();
    expect(alerts.alerts.firstWhere((a) => a.id == live.id).isAcknowledged, isTrue);
    expect(services.live.connectAttempts, attempts, reason: 'no new connection for any of this');
    // ignore: avoid_print
    print('IT-ALERT acknowledge: id=${live.id} backendStatus=${after['status']} acknowledgedAt=${after['acknowledgedAt']} requestsForAcknowledge=1 secondAcknowledgeKeptTime=true liveState=${services.dashboard.liveState.name}');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 7)));

  test('authorization is the backend\'s: another farmer neither sees nor can acknowledge the alert', () async {
    final owner = await signedIn(farmer);
    await ensureSimulatorDeviceClaimed(owner);
    await owner.alerts.load();
    final target = owner.alerts.alerts.firstWhere((a) => a.deviceId == simDevice);

    final other = await signedIn(otherFarmer);
    await other.alerts.load();
    expect(other.alerts.phase, AlertsPhase.ready);
    expect(other.alerts.alerts.where((a) => a.deviceId == simDevice), isEmpty);
    final failure = await other.alerts.acknowledge(target.id);
    expect(failure!.kind, ApiFailureKind.notFound);
    await expectLater(AlertsRepository(api: other.api).acknowledge(target.id), throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', ApiFailureKind.notFound)));

    final raw = await rawClient(farmer);
    final row = (await raw.get<dynamic>('/api/v1/alerts/${target.id}')).data as Map;
    expect(row['status'], target.status, reason: 'unchanged by the other farmer\'s attempt');
    // ignore: avoid_print
    print('IT-ALERT authorization: $otherFarmer lists ${other.alerts.alerts.length} alert(s), none for $simDevice; acknowledging ${target.id} -> not found; status on the backend still ${row['status']}');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('session invalidated on the backend: loading alerts ends the session, nothing is kept', () async {
    final services = await signedIn(farmer);
    await ensureSimulatorDeviceClaimed(services);
    await services.alerts.load();
    expect(services.alerts.alerts, isNotEmpty);
    var forced = 0;
    services.session.onForcedSignOut = () => forced++;
    final raw = Dio(BaseOptions(baseUrl: baseUrl!, validateStatus: (_) => true));
    final revoked = await raw.post<dynamic>('/api/v1/auth/logout', options: Options(headers: {'Authorization': 'Bearer ${stores[services]!.session!.accessToken}'}));
    expect(revoked.statusCode, 204);
    final refreshes = services.api.interceptor.refreshRequests;
    await services.alerts.load();
    expect(services.session.status, SessionStatus.signedOut);
    expect(forced, 1);
    expect(stores[services]!.session, isNull);
    expect(services.alerts.phase, AlertsPhase.idle);
    expect(services.alerts.alerts, isEmpty);
    expect(services.api.interceptor.refreshRequests, refreshes + 1, reason: 'the two alert requests share one refresh attempt');
    // ignore: avoid_print
    print('IT-ALERT session: logout on the backend -> alerts load ended the session; refresh attempts=1; forcedSignOut=$forced; alerts kept=${services.alerts.alerts.length}');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
