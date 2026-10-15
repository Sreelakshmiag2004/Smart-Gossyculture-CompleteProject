// Phase 3C: the Dashboard WIDGET receiving a live event from the local development backend.
//
//   simulator -> MQTT/TLS -> ingest -> PostgreSQL/TimescaleDB -> REST snapshot
//             -> WebSocket event -> app live connection -> Dashboard widget
//
// Kept in its own file: a widget test installs a test binding that blocks HTTP for the whole
// file unless it is switched off, which this test does (HttpOverrides.global = null).
// Skipped unless GOSSY_IT_BASE_URL and GOSSY_IT_OTP_CODE are set (see it_support.dart).

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/app_services.dart';
import 'package:smart_gossy_culture_app/core/formatting.dart';
import 'package:smart_gossy_culture_app/core/realtime/live_connection.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';

import 'it_support.dart';

void main() {
  testWidgets('Dashboard widget shows the REST snapshot, then a value delivered by a real live event', (tester) async {
    HttpOverrides.global = null; // allow real HTTP and WebSocket connections in this widget test
    late AppServices services;
    Future<void>? pending;
    var requests = 0;
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
      services.api.authed.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        requests++;
        handler.next(options);
      }));
      // What the page does when it opens, done here so that the network work runs in real time:
      // live updates wanted, snapshot loaded over REST, the simulator's device shown.
      final dashboard = services.dashboard..attachLive();
      await dashboard.load();
      if (dashboard.data!.device!.deviceId != simDevice) await dashboard.selectDevice(simDevice);
      // Start the loads the page itself would start, in the real async zone; the page's own calls
      // then find a load in progress. (Since Phase 5B the page also reads the alerts for its bell.)
      pending = Future.wait([dashboard.load(), services.alerts.load()]);
    });
    final dashboard = services.dashboard;
    final snapshot = dashboard.data!.telemetry!;

    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(services: services, child: MaterialApp(theme: ThemeData(fontFamily: 'Roboto'), home: const Dashboard())));
    await tester.pump();
    await tester.runAsync(() => pending!);
    String text(String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

    // 1. The REST snapshot is on screen (the page's own load may replace it with a newer one).
    await tester.runAsync(() => realTime(() => !dashboard.busy && dashboard.liveState == LiveState.connected, const Duration(seconds: 30), 'the snapshot and the live connection'));
    await tester.pump();
    expect(text('powerValue'), formatPercent(dashboard.data!.telemetry!.batteryPct!));
    expect(text('liveStatus'), 'Live updates on');
    final shownFirst = dashboard.data!.telemetry!;
    final firstLine = 'power="${text('powerValue')}" moisture="${text('moistureValue')}" bolls="${text('bollValue')}" ${text('telemetryTime')}';

    // 2. Without any further request, the simulator's next reading arrives over the live channel.
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1))); // the background re-read
    final requestsBefore = requests;
    final before = dashboard.data!.telemetry!;
    await tester.runAsync(() => realTime(() => dashboard.data!.telemetry!.msgId != before.msgId, const Duration(seconds: 40), 'a live telemetry event'));
    final live = dashboard.data!.telemetry!;
    expect(requests, requestsBefore, reason: 'no REST request was sent: the value came from the live event');
    await tester.pump();

    // 3. The widget shows exactly the event's values.
    expect(text('powerValue'), formatPercent(live.batteryPct!));
    expect(text('moistureValue'), live.moistureRhPct == null ? '—' : formatPercent(live.moistureRhPct!));
    expect(text('bollValue'), live.bollsHarvestedTotal == null ? '—' : formatCount(live.bollsHarvestedTotal!));
    expect(text('bollCaption'), live.bollsHarvestedTotal == null ? 'No reading' : 'Bolls harvested (device total)');
    expect(text('telemetryTime'), 'Reading taken by the device: ${formatDateTime(live.time)}');
    expect(text('deviceLastSeen'), 'Last heard from: ${formatDateTime(dashboard.data!.device!.status.lastSeenAt!)}');
    expect(text('liveStatus'), 'Live updates on');
    // Phase 4: the air temperature reading and the freshness of what is shown
    expect(text('airTempValue'), live.airTempC == null ? '—' : formatTemperature(live.airTempC!));
    expect(text('readingFreshness'), 'Live - newest reading from the device');
    expect(live.time.isAfter(shownFirst.time), isTrue);
    final selector = find.byKey(const Key('deviceSelector'));
    final shownDevice = selector.evaluate().isNotEmpty ? tester.widget<DropdownButton<String>>(selector).value! : text('deviceName');
    expect(shownDevice, contains(simDevice));
    for (final sample in ['Optimal', 'Estimated ripe bolls in sector A', 'Action Required', 'Low Battery']) {
      expect(find.text(sample), findsNothing);
    }

    // 4. The same message as the backend serves it over REST (independent of the app's models).
    late Map<dynamic, dynamic> row;
    await tester.runAsync(() async {
      final raw = await rawClient(farmer);
      final page = (await raw.get<dynamic>('/api/v1/devices/$simDevice/telemetry', queryParameters: {'limit': 50})).data as Map;
      row = (page['items'] as List).cast<Map>().firstWhere((r) => r['msgId'] == live.msgId);
    });
    expect(text('powerValue'), formatPercent((row['batteryPct'] as num).toDouble()));
    if (row['bollsHarvestedTotal'] != null) expect(text('bollValue'), formatCount(row['bollsHarvestedTotal'] as int));

    // ignore: avoid_print
    print('IT-LIVE widget: device="$shownDevice" restSnapshotMsgId=${snapshot.msgId} shownFirst[$firstLine] '
        'liveMsgId=${live.msgId} shownAfterLiveEvent[power="${text('powerValue')}" (${text('powerCaption')}) moisture="${text('moistureValue')}" airTemp="${text('airTempValue')}" bolls="${text('bollValue')}" ${text('telemetryTime')}] freshness="${text('readingFreshness')}" '
        'liveStatus="${text('liveStatus')}" restRequestsBetween=${requests - requestsBefore}');

    // Close the connection in real time. Since Phase 4 it is kept until the last user has let
    // go of it: the page (disposed here) and this test, which attached above.
    await tester.pumpWidget(const SizedBox());
    expect(dashboard.liveState, LiveState.connected, reason: 'the test is still attached');
    await tester.runAsync(() async {
      dashboard.detachLive();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    expect(dashboard.liveState, LiveState.disconnected);
  }, skip: skipReason != null, timeout: const Timeout(Duration(minutes: 3)));
}
