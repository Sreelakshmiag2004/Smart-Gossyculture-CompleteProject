// Phase 5B: the Notifications page and the dashboard bell - the real app (launch page included)
// with the fake REST backend and the fake live channel that follow the backend contracts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/formatting.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';
import 'package:smart_gossy_culture_app/ui/notifications_page.dart';
import 'package:smart_gossy_culture_app/ui/sign_in_page.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';
import '../support/fake_live.dart';

const device = 'unit-a';
const otherDevice = 'unit-b';

/// What the old sample page showed and the backend has no source for. None of it may appear.
const fabricated = ['Low Battery', 'Moisture Alert', 'Harvest Ready', 'System Update', 'Gateway Error', 'Pest Detected!', 'High Urgency', 'Medium Urgency', 'Low Urgency'];

/// Wording no alert of the backend supports.
const unsupported = ['recommended', 'Recommended', 'Aphids', 'Zone', 'Sector', 'tons', 'yield', 'dose', 'pesticide', 'Treat', 'Ready', 'battery', 'Battery', 'moisture', 'Moisture'];

String alertId(int n) => 'a0000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

TestApp farmer() {
  final app = TestApp(random: FixedRandom(1.0))..signIn();
  app.backend.farms.add({'id': 'farm-1', 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z'});
  for (final (index, id) in [device, otherDevice].indexed) {
    app.backend.devices.add(FakeBackend.device(id, displayName: index == 0 ? 'Field unit' : null, state: 'online', lastSeenAt: '2026-10-01T15:00:00Z', claimedAt: '2026-10-0${9 - index}T00:00:00Z'));
  }
  app.backend.telemetry[device] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 91.4, moistureRhPct: 54.3, bollsHarvestedTotal: 1287, solarActive: true, msgId: '01K6CQ4W0D8V9J4Q9W2Y000001')];
  return app;
}

Map<String, Object?> pest(int n, {String at = '2026-10-01T15:03:00Z', String label = 'leaf_curl_virus', num confidence = 0.87}) =>
    FakeBackend.alertRow(id: alertId(n), type: 'pest_detected', deviceId: device, occurredAt: at, details: {'label': label, 'confidence': confidence});

Map<String, Object?> spray(int n, {String at = '2026-10-01T15:02:00Z', String status = 'open', String? acknowledgedAt}) =>
    FakeBackend.alertRow(id: alertId(n), type: 'spray_performed', severity: 'info', deviceId: otherDevice, occurredAt: at, details: {'durationMs': 1500, 'relatedMsgId': '01K6CQ4W0D8V9J4Q9W2Y000777'}, status: status, acknowledgedAt: acknowledgedAt);

Map<String, Object?> offline(int n, {String at = '2026-10-01T09:00:00Z', String createdAt = '2026-10-01T15:01:00Z'}) =>
    FakeBackend.alertRow(id: alertId(n), type: 'device_offline', deviceId: device, occurredAt: at, createdAt: createdAt);

Future<void> openNotifications(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('dashboardBell')));
  await tester.pumpAndSettle();
  expect(find.byType(NotificationsPage), findsOneWidget);
}

void expectNothingFabricated() {
  for (final text in fabricated) {
    expect(find.text(text), findsNothing, reason: '"$text" is displayed');
  }
  for (final text in unsupported) {
    expect(find.textContaining(text), findsNothing, reason: '"$text" is displayed');
  }
  expect(find.byType(Image), findsNothing, reason: 'the backend has no alert photos');
}

Iterable<RecordedCall> alertCalls(TestApp app) => app.backend.calls.where((c) => c.path.startsWith('/api/v1/alerts'));

void main() {
  group('dashboard bell', () {
    testWidgets('shows the number of open alerts the backend holds; no number when there are none', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      expect(find.byType(Dashboard), findsOneWidget);
      expect(find.byKey(const Key('dashboardBell')), findsOneWidget);
      expect(find.byKey(const Key('alertBadge')), findsNothing);

      app.backend.alerts.addAll([pest(3), spray(2, status: 'acknowledged', acknowledgedAt: '2026-10-01T15:30:00Z'), offline(1)]);
      await tester.tap(find.byKey(const Key('dashboardRefresh')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'alertBadge'), '2', reason: 'two open, one acknowledged');
    });

    testWidgets('no number is invented when the alerts could not be read; the dashboard itself is unaffected', (tester) async {
      final app = farmer();
      app.backend.alerts.add(pest(1));
      app.backend.overrides['/api/v1/alerts'] = FakeReply.error(503, 'service_unavailable');
      await startApp(tester, app);
      expect(find.byKey(const Key('alertBadge')), findsNothing);
      expect(textOf(tester, 'powerValue'), '91.4%');
      expect(find.byKey(const Key('dashboardError')), findsNothing);
      expect(find.byKey(const Key('dashboardRefreshError')), findsNothing);
      expect(textOf(tester, 'liveStatus'), 'Live updates on');
    });

    testWidgets('more open alerts than were read: "99+", never an exact number that is not known', (tester) async {
      final app = farmer();
      for (var n = 130; n >= 1; n--) {
        app.backend.alerts.add(pest(n, at: '2026-10-01T${(n ~/ 60).toString().padLeft(2, '0')}:${(n % 60).toString().padLeft(2, '0')}:00Z'));
      }
      await startApp(tester, app);
      expect(textOf(tester, 'alertBadge'), '99+');
    });

    testWidgets('a live alert raises the number; acknowledging lowers it', (tester) async {
      final app = farmer();
      app.backend.alerts.add(pest(1));
      await startApp(tester, app);
      expect(textOf(tester, 'alertBadge'), '1');

      final row = pest(2, at: '2026-10-01T15:10:00Z', label: 'bollworm', confidence: 0.6);
      app.backend.alerts.insert(0, row);
      app.live.ingest(kind: 'event/pest', deviceId: device, ts: '2026-10-01T15:10:00Z', data: {'label': 'bollworm', 'confidence': 0.6}, alerts: [row]);
      await tester.pumpAndSettle();
      expect(textOf(tester, 'alertBadge'), '2');
      // the dashboard's own detection card follows the same event, and stays a detection
      expect(find.text('Latest detection'), findsOneWidget);
      expect(textOf(tester, 'detectionText'), contains('Bollworm · confidence 60%'));

      await openNotifications(tester);
      await tester.tap(find.byKey(Key('acknowledge-${alertId(2)}')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(NotificationsPage))).pop();
      await tester.pumpAndSettle();
      expect(textOf(tester, 'alertBadge'), '1');
    });
  });

  group('notifications page', () {
    testWidgets('lists the backend\'s alerts, newest first, each as the backend stored it', (tester) async {
      final app = farmer();
      app.backend.alerts.addAll([pest(3), spray(2, status: 'acknowledged', acknowledgedAt: '2026-10-01T15:30:00Z'), offline(1)]);
      await startApp(tester, app);
      await openNotifications(tester);

      // pest_detected
      expect(textOf(tester, 'alertTitle-${alertId(3)}'), 'Detection reported');
      expect(textOf(tester, 'alertMessage-${alertId(3)}'), 'Leaf curl virus · confidence 87%\nDevice $device');
      expect(textOf(tester, 'alertTime-${alertId(3)}'), 'Reported ${formatDateTime(DateTime.utc(2026, 10, 1, 15, 3))}');
      expect(find.byKey(Key('alertOpen-${alertId(3)}')), findsOneWidget);
      expect(find.byKey(Key('acknowledge-${alertId(3)}')), findsOneWidget);

      // spray_performed, already acknowledged on the backend
      expect(textOf(tester, 'alertTitle-${alertId(2)}'), 'Spray performed');
      expect(textOf(tester, 'alertMessage-${alertId(2)}'), 'Spray duration 1.5 s\nDevice $otherDevice');
      expect(textOf(tester, 'alertAcknowledged-${alertId(2)}'), 'Acknowledged ${formatDateTime(DateTime.utc(2026, 10, 1, 15, 30))}');
      expect(find.byKey(Key('alertOpen-${alertId(2)}')), findsNothing);
      expect(find.byKey(Key('acknowledge-${alertId(2)}')), findsNothing);

      // device_offline: the device's time and, because it differs, the backend's
      expect(textOf(tester, 'alertTitle-${alertId(1)}'), 'Device offline');
      expect(textOf(tester, 'alertMessage-${alertId(1)}'), 'Device $device was reported offline.');
      expect(textOf(tester, 'alertTime-${alertId(1)}'), 'Reported ${formatDateTime(DateTime.utc(2026, 10, 1, 9))} · received ${formatDateTime(DateTime.utc(2026, 10, 1, 15, 1))}');

      // in the backend's order
      final tops = [for (final n in [3, 2, 1]) tester.getTopLeft(find.byKey(Key('alert-${alertId(n)}'))).dy];
      expect(tops[0] < tops[1] && tops[1] < tops[2], isTrue);

      expectNothingFabricated();
      expect(find.byKey(const Key('alertsEmpty')), findsNothing);
      expect(find.byKey(const Key('alertsError')), findsNothing);
    });

    testWidgets('no sample notifications, and no "mark all as read"', (tester) async {
      final app = farmer();
      app.backend.alerts.add(pest(1));
      await startApp(tester, app);
      await openNotifications(tester);
      expectNothingFabricated();
      expect(find.byTooltip('Mark all as read'), findsNothing);
      expect(find.byIcon(Icons.done_all), findsNothing);
      expect(find.textContaining('Mark all'), findsNothing);
      expect(find.textContaining('marked as read'), findsNothing);
      // the only writes the app has sent to the backend so far: none
      expect(app.backend.calls.where((c) => c.method != 'GET'), isEmpty);
    });

    testWidgets('empty state', (tester) async {
      final app = farmer();
      await startApp(tester, app);
      await openNotifications(tester);
      expect(find.byKey(const Key('alertsEmpty')), findsOneWidget);
      expect(find.text('No alerts'), findsOneWidget);
      expect(find.byKey(const Key('alertsLoading')), findsNothing);
      expectNothingFabricated();
    });

    testWidgets('loading state, then the alerts', (tester) async {
      final app = farmer();
      app.backend.alerts.add(pest(1));
      app.backend.overrides['/api/v1/alerts'] = FakeReply.error(503, 'service_unavailable');
      await startApp(tester, app); // the alerts are not known yet
      app.backend
        ..overrides.clear()
        ..latency = const Duration(seconds: 2);
      await tester.tap(find.byKey(const Key('dashboardBell')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('alertsLoading')), findsOneWidget);
      expect(find.text('Loading your alerts...'), findsOneWidget);
      expect(find.byKey(Key('alert-${alertId(1)}')), findsNothing);
      expectNothingFabricated();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('alertsLoading')), findsNothing);
      expect(find.byKey(Key('alert-${alertId(1)}')), findsOneWidget);
    });

    testWidgets('error state with a safe message and a retry; a failed refresh keeps the alerts shown', (tester) async {
      final app = farmer();
      app.backend.alerts.add(pest(1));
      app.backend.overrides['/api/v1/alerts'] = FakeReply.error(503, 'service_unavailable');
      await startApp(tester, app);
      await openNotifications(tester);
      expect(find.byKey(const Key('alertsError')), findsOneWidget);
      expect(find.text('Your alerts could not be loaded'), findsOneWidget);
      expect(find.textContaining('temporarily unavailable'), findsOneWidget);
      expect(find.textContaining('backend message that must never be shown'), findsNothing);
      expect(find.byKey(Key('alert-${alertId(1)}')), findsNothing);
      expectNothingFabricated();

      app.backend.overrides.clear();
      await tester.tap(find.byKey(const Key('alertsRetry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('alertsError')), findsNothing);
      expect(find.byKey(Key('alert-${alertId(1)}')), findsOneWidget);

      app.backend.outage = Outage.offline;
      await tester.tap(find.byKey(const Key('alertsRefresh')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('alertsRefreshError')), findsOneWidget);
      expect(find.textContaining('Showing the alerts loaded earlier'), findsOneWidget);
      expect(find.byKey(Key('alert-${alertId(1)}')), findsOneWidget);
    });

    testWidgets('an alert of an unknown type, with unknown severity and details, is shown without an interpretation', (tester) async {
      final app = farmer();
      app.backend.alerts.addAll([
        FakeBackend.alertRow(id: alertId(2), type: 'firmware_notice', severity: 'critical', deviceId: device, occurredAt: '2026-10-01T15:05:00Z', details: {'version': '2.1', 'action': 'Update now'}),
        // known types whose details are not what the contract describes
        FakeBackend.alertRow(id: alertId(1), type: 'pest_detected', deviceId: device, occurredAt: '2026-10-01T15:04:00Z', details: {'label': 7}),
        FakeBackend.alertRow(id: alertId(0), type: 'spray_performed', severity: 'info', deviceId: device, occurredAt: '2026-10-01T15:03:00Z'),
      ]);
      await startApp(tester, app);
      await openNotifications(tester);
      expect(tester.takeException(), isNull);
      expect(textOf(tester, 'alertTitle-${alertId(2)}'), 'Alert');
      expect(textOf(tester, 'alertMessage-${alertId(2)}'), 'Type: firmware_notice\nDevice $device');
      expect(find.textContaining('Update now'), findsNothing, reason: 'details of an unknown type are not shown as text');
      expect(textOf(tester, 'alertMessage-${alertId(1)}'), 'Device $device reported a detection.');
      expect(textOf(tester, 'alertMessage-${alertId(0)}'), 'Device $device reported a spray.');
      expect(find.byKey(Key('acknowledge-${alertId(2)}')), findsOneWidget, reason: 'it is an open alert of the backend like any other');
    });

    testWidgets('a live alert appears on the open page by itself, once', (tester) async {
      final app = farmer();
      final first = pest(1, at: '2026-10-01T15:00:00Z');
      app.backend.alerts.add(first);
      await startApp(tester, app);
      await openNotifications(tester);
      final before = alertCalls(app).length;

      final row = FakeBackend.alertRow(id: alertId(2), type: 'device_offline', deviceId: device, occurredAt: '2026-10-01T15:20:00Z');
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T15:20:00Z', data: {'state': 'offline'}, alerts: [row]);
      // the same alert again, and the already listed one again
      app.live.ingest(kind: 'status', deviceId: device, ts: '2026-10-01T15:20:01Z', data: {'state': 'offline'}, alerts: [row, first]);
      await tester.pumpAndSettle();

      expect(find.byKey(Key('alert-${alertId(2)}')), findsOneWidget);
      expect(find.byKey(Key('alert-${alertId(1)}')), findsOneWidget);
      expect(textOf(tester, 'alertTitle-${alertId(2)}'), 'Device offline');
      expect(tester.getTopLeft(find.byKey(Key('alert-${alertId(2)}'))).dy < tester.getTopLeft(find.byKey(Key('alert-${alertId(1)}'))).dy, isTrue);
      expect(alertCalls(app).length, before, reason: 'no REST request: the alert came with the live event');
      expect(app.live.openSockets, hasLength(1), reason: 'the dashboard\'s connection, no second one');
      expect(app.live.clientFrames, [{'op': 'start'}]);
    });

    testWidgets('older alerts are fetched on request', (tester) async {
      final app = farmer();
      for (var n = 60; n >= 1; n--) {
        app.backend.alerts.add(pest(n, at: '2026-10-01T10:${(n - 1).toString().padLeft(2, '0')}:00Z'));
      }
      await startApp(tester, app);
      await openNotifications(tester);
      expect(app.services.alerts.alerts, hasLength(50));
      await tester.scrollUntilVisible(find.byKey(const Key('alertsLoadMore')), 800, scrollable: find.byType(Scrollable).last);
      await tester.tap(find.byKey(const Key('alertsLoadMore')));
      await tester.pumpAndSettle();
      expect(app.services.alerts.alerts, hasLength(60));
      expect(find.byKey(const Key('alertsLoadMore')), findsNothing);
    });
  });

  group('acknowledgement', () {
    testWidgets('Acknowledge calls the backend for that alert; the page shows the backend\'s result', (tester) async {
      final app = farmer();
      app.backend.alerts.addAll([pest(2), offline(1)]);
      await startApp(tester, app);
      await openNotifications(tester);

      await tester.tap(find.byKey(Key('acknowledge-${alertId(2)}')));
      await tester.pumpAndSettle();

      final writes = app.backend.calls.where((c) => c.method != 'GET').toList();
      expect(writes.map((c) => '$c'), ['POST /api/v1/alerts/${alertId(2)}/acknowledge']);
      expect(writes.single.body, isNull);
      expect(app.backend.alerts.first['status'], 'acknowledged');

      expect(textOf(tester, 'alertAcknowledged-${alertId(2)}'), 'Acknowledged ${formatDateTime(DateTime.utc(2026, 10, 1, 16))}');
      expect(find.byKey(Key('acknowledge-${alertId(2)}')), findsNothing);
      expect(find.byKey(Key('alertOpen-${alertId(2)}')), findsNothing);
      // the other alert is untouched
      expect(find.byKey(Key('acknowledge-${alertId(1)}')), findsOneWidget);
      expect(app.backend.alerts[1]['status'], 'open');

      // a refresh does not bring "unread" back
      await tester.tap(find.byKey(const Key('alertsRefresh')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('alertAcknowledged-${alertId(2)}')), findsOneWidget);
      // nothing was sent over the live channel, and no other write exists
      expect(app.live.clientFrames, [{'op': 'start'}]);
      expect(app.backend.calls.where((c) => c.method != 'GET'), hasLength(1));
    });

    testWidgets('while the backend has not answered, the alert is not shown as acknowledged', (tester) async {
      final app = farmer();
      app.backend.alerts.add(pest(1));
      await startApp(tester, app);
      await openNotifications(tester);
      app.backend.latency = const Duration(seconds: 2);
      await tester.tap(find.byKey(Key('acknowledge-${alertId(1)}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Acknowledging...'), findsOneWidget);
      expect(find.byKey(Key('alertOpen-${alertId(1)}')), findsOneWidget);
      expect(find.byKey(Key('alertAcknowledged-${alertId(1)}')), findsNothing);
      // a second tap while waiting sends nothing
      await tester.tap(find.byKey(Key('acknowledge-${alertId(1)}')));
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(app.backend.count('POST', '/api/v1/alerts/${alertId(1)}/acknowledge'), 1);
      expect(find.byKey(Key('alertAcknowledged-${alertId(1)}')), findsOneWidget);
    });

    testWidgets('a failed acknowledgement: a safe message, and the alert stays open', (tester) async {
      final app = farmer();
      app.backend.alerts.add(pest(1));
      await startApp(tester, app);
      await openNotifications(tester);
      app.backend.overrides['/api/v1/alerts/${alertId(1)}/acknowledge'] = FakeReply.error(503, 'service_unavailable');
      await tester.tap(find.byKey(Key('acknowledge-${alertId(1)}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('acknowledgeError')), findsOneWidget);
      expect(find.textContaining('The alert could not be acknowledged.'), findsOneWidget);
      expect(find.textContaining('backend message that must never be shown'), findsNothing);
      expect(find.byKey(Key('alertOpen-${alertId(1)}')), findsOneWidget);
      expect(find.byKey(Key('acknowledge-${alertId(1)}')), findsOneWidget);
      expect(find.byKey(Key('alertAcknowledged-${alertId(1)}')), findsNothing);
      expect(app.backend.alerts.single['status'], 'open');

      // it works once the backend answers
      app.backend.overrides.clear();
      await tester.tap(find.byKey(Key('acknowledge-${alertId(1)}')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('alertAcknowledged-${alertId(1)}')), findsOneWidget);
    });
  });

  group('session', () {
    testWidgets('session ended on the Notifications page: back to sign-in through the Phase 3A mechanism', (tester) async {
      final app = farmer();
      app.backend.alerts.add(pest(1));
      await startApp(tester, app);
      await openNotifications(tester);
      app.backend
        ..expireAccessToken()
        ..sessionRevoked = true;
      await tester.tap(find.byKey(Key('acknowledge-${alertId(1)}')));
      await tester.pumpAndSettle();

      expect(find.byType(SignInPage), findsOneWidget);
      expect(find.textContaining('session has ended'), findsOneWidget);
      expect(find.byType(NotificationsPage), findsNothing);
      expect(app.tokens.session, isNull);
      expect(app.services.alerts.alerts, isEmpty);
      expect(app.services.dashboard.data, isNull);
      expect(app.backend.alerts.single['status'], 'open');
      expect(app.backend.count('POST', '/api/v1/auth/refresh'), 1);
      expect(app.live.openSockets, isEmpty);
      final attempts = app.live.attempts.length;
      await tester.pump(const Duration(hours: 1));
      expect(app.live.attempts.length, attempts);
    });

    testWidgets('no token is displayed on the Notifications page', (tester) async {
      final app = farmer();
      app.backend.alerts.add(pest(1));
      await startApp(tester, app);
      await openNotifications(tester);
      final shown = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText() ?? '').join('\n');
      expect(shown, isNot(contains(app.tokens.session!.accessToken)));
      expect(shown, isNot(contains(app.tokens.session!.refreshToken)));
      expect(shown, isNot(contains('Bearer')));
    });
  });
}
