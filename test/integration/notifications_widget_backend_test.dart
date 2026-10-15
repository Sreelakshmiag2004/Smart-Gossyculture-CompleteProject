// Phase 5B: the Dashboard bell and the Notifications PAGE on the local development backend.
//
//   simulator -> MQTT/TLS -> ingest -> PostgreSQL -> REST /api/v1/alerts -> bell + Notifications page
//             -> acknowledge (REST) -> PostgreSQL -> page
//
// Kept in its own file: a widget test installs a test binding that blocks HTTP for the whole
// file unless it is switched off, which this test does (HttpOverrides.global = null).
// Skipped unless GOSSY_IT_BASE_URL and GOSSY_IT_OTP_CODE are set (see it_support.dart).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/alerts/alerts_controller.dart';
import 'package:smart_gossy_culture_app/core/app_services.dart';
import 'package:smart_gossy_culture_app/core/formatting.dart';
import 'package:smart_gossy_culture_app/core/models.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';
import 'package:smart_gossy_culture_app/ui/notifications_page.dart';

import 'it_support.dart';

void main() {
  testWidgets('bell and Notifications page show the backend\'s alerts; Acknowledge changes the alert on the backend', (tester) async {
    HttpOverrides.global = null; // allow real HTTP and WebSocket connections in this widget test
    late AppServices services;
    Future<void>? pending;
    Future<void> realTime(bool Function() condition, Duration timeout, String what) async {
      final deadline = DateTime.now().add(timeout);
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    await tester.runAsync(() async {
      final font = File('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
      if (font.existsSync()) {
        await (FontLoader('Roboto')..addFont(Future.value(ByteData.view(font.readAsBytesSync().buffer)))).load();
      }
      services = await signedIn(farmer);
      await ensureSimulatorDeviceClaimed(services);
      // What the page does when it opens, done here so that the network work runs in real time.
      final dashboard = services.dashboard..attachLive();
      await Future.wait([dashboard.load(), services.alerts.load()]);
      if (dashboard.data!.device!.deviceId != simDevice) await dashboard.selectDevice(simDevice);
      pending = Future.wait([dashboard.load(), services.alerts.load()]);
    });
    final alerts = services.alerts;

    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(services: services, child: MaterialApp(theme: ThemeData(fontFamily: 'Roboto'), home: const Dashboard())));
    await tester.pump();
    await tester.runAsync(() => pending!);
    await tester.runAsync(() => realTime(() => !alerts.busy && !services.dashboard.busy && alerts.phase == AlertsPhase.ready, const Duration(seconds: 30), 'the alerts'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2))); // the re-read after the stream starts
    await tester.runAsync(() => realTime(() => !alerts.busy, const Duration(seconds: 30), 'the alerts re-read'));
    await tester.pump();
    String text(String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

    // 1. The bell: the backend's open alerts.
    expect(alerts.openCount, greaterThan(0), reason: 'the simulator has reported detections that nobody acknowledged');
    final expectedBadge = alerts.openCount > 99 ? '99+' : (alerts.openCountIsMinimum ? '${alerts.openCount}+' : '${alerts.openCount}');
    expect(text('alertBadge'), expectedBadge);
    final badgeBefore = text('alertBadge');

    // 2. The page.
    // Requests the PAGE starts run inside the widget test's own clock: real time is let pass in
    // small steps, each followed by a frame, until the request has completed.
    Future<void> drive(bool Function() done, String what) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done(), isTrue, reason: 'timed out waiting for $what');
    }

    await tester.tap(find.byKey(const Key('dashboardBell')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await drive(() => !alerts.busy, 'the page\'s own load');
    expect(find.byType(NotificationsPage), findsOneWidget);
    final target = alerts.alerts.firstWhere((a) => a.isOpen && a.type == Alert.pestDetected);
    final card = find.byKey(Key('alert-${target.id}'));
    await tester.scrollUntilVisible(card, 600, scrollable: find.byType(Scrollable).last);
    expect(text('alertTitle-${target.id}'), 'Detection reported');
    expect(text('alertMessage-${target.id}'), '${formatDetectionLabel(target.details['label'] as String)} · confidence ${formatConfidence((target.details['confidence'] as num).toDouble())}\nDevice $simDevice');
    for (final sample in ['Low Battery', 'Moisture Alert', 'Harvest Ready', 'System Update', 'Gateway Error', 'Pest Detected!']) {
      expect(find.text(sample), findsNothing);
    }
    expect(find.byTooltip('Mark all as read'), findsNothing);

    // 3. Acknowledge through the page.
    final acknowledge = find.byKey(Key('acknowledge-${target.id}'));
    await tester.scrollUntilVisible(acknowledge, 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(acknowledge);
    await tester.pump();
    expect(alerts.isAcknowledging(target.id), isTrue);
    await drive(() => !alerts.isAcknowledging(target.id), 'the acknowledgement');
    final shown = alerts.alerts.firstWhere((a) => a.id == target.id);
    expect(shown.isAcknowledged, isTrue);
    expect(text('alertAcknowledged-${target.id}'), 'Acknowledged ${formatDateTime(shown.acknowledgedAt!)}');
    expect(find.byKey(Key('acknowledge-${target.id}')), findsNothing);

    // 4. The backend agrees (independent of the app's models).
    late Map<dynamic, dynamic> row;
    await tester.runAsync(() async {
      final raw = await rawClient(farmer);
      row = (await raw.get<dynamic>('/api/v1/alerts/${target.id}')).data as Map;
    });
    expect(row['status'], 'acknowledged');
    expect(DateTime.parse(row['acknowledgedAt'] as String).toUtc(), shown.acknowledgedAt);

    // ignore: avoid_print
    print('IT-ALERT widget: bell="$badgeBefore" page alert id=${target.id} title="Detection reported" message="${alertMessage(target).replaceAll('\n', ' | ')}" '
        '-> tapped Acknowledge -> shown "${text('alertAcknowledged-${target.id}')}" backendStatus=${row['status']} backendAcknowledgedAt=${row['acknowledgedAt']}');

    await tester.pumpWidget(const SizedBox());
    // The page's own requests were made inside the test clock: let their idle HTTP connections
    // time out there, so that no timer outlives the test.
    await tester.pump(const Duration(seconds: 30));
    await tester.runAsync(() async {
      services.dashboard.detachLive();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
  }, skip: skipReason != null, timeout: const Timeout(Duration(minutes: 3)));
}
