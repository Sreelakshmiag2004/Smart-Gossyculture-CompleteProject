// The Dashboard WIDGET against the local development backend with real simulator data.
// Kept in its own file: a widget test installs a test binding that blocks HTTP for the whole
// file unless it is switched off, which this test does (HttpOverrides.global = null).
// Skipped unless GOSSY_IT_BASE_URL and GOSSY_IT_OTP_CODE are set (see it_support.dart).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/app_services.dart';
import 'package:smart_gossy_culture_app/core/formatting.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';

import 'it_support.dart';

void main() {
  testWidgets('Dashboard widget renders the real backend values', (tester) async {
    HttpOverrides.global = null; // allow real HTTP in this widget test
    late AppServices services;
    Future<void>? pending;
    await tester.runAsync(() async {
      final font = File('${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
      if (font.existsSync()) {
        await (FontLoader('Roboto')..addFont(Future.value(ByteData.view(font.readAsBytesSync().buffer)))).load();
      }
      services = await signedIn(farmer);
      await ensureSimulatorDeviceClaimed(services);
      await services.dashboard.load();
      await services.dashboard.selectDevice(simDevice);
      // Start the loads the page itself would start, in the real async zone; the page's own calls
      // then find a load in progress. (Since Phase 5B the page also reads the alerts for its bell.)
      pending = Future.wait([services.dashboard.load(), services.alerts.load()]);
    });
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppScope(services: services, child: MaterialApp(theme: ThemeData(fontFamily: 'Roboto'), home: const Dashboard())));
    await tester.pump();
    await tester.runAsync(() => pending!);
    await tester.pump();

    final data = services.dashboard.data!;
    final telemetry = data.telemetry!;
    String text(String key) => tester.widget<Text>(find.byKey(Key(key))).data!;
    // The farmer owns several test devices, so the device is shown in the selector.
    final selector = find.byKey(const Key('deviceSelector'));
    final shownDevice = selector.evaluate().isNotEmpty ? tester.widget<DropdownButton<String>>(selector).value! : text('deviceName');
    expect(shownDevice, contains(simDevice));
    expect(text('powerValue'), formatPercent(telemetry.batteryPct!));
    expect(text('moistureValue'), telemetry.moistureRhPct == null ? '—' : formatPercent(telemetry.moistureRhPct!));
    expect(text('bollValue'), telemetry.bollsHarvestedTotal == null ? '—' : formatCount(telemetry.bollsHarvestedTotal!));
    expect(text('telemetryTime'), contains(formatDateTime(telemetry.time)));
    expect(find.descendant(of: find.byKey(const Key('deviceStatus')), matching: find.text(switch (data.device!.status.state) { 'online' => 'Online', 'offline' => 'Offline', _ => 'Status not reported' })), findsOneWidget);
    if (data.latestDetection != null) {
      expect(text('detectionText'), contains(formatDetectionLabel(data.latestDetection!.label)));
    } else {
      expect(find.byKey(const Key('detectionBanner')), findsNothing);
    }
    for (final sample in ['Optimal', 'Estimated ripe bolls in sector A', 'SUNDAY, SEPTEMBER 7, 2025', 'Aphid infestation detected in Sector C.']) {
      expect(find.text(sample), findsNothing);
    }
    // ignore: avoid_print
    print('IT-DASH widget: device="$shownDevice" power="${text('powerValue')}" (${text('powerCaption')}) moisture="${text('moistureValue')}" bolls="${text('bollValue')}" '
        '${text('telemetryTime')} msgId=${telemetry.msgId}');
  }, skip: skipReason != null, timeout: const Timeout(Duration(minutes: 2)));
}
