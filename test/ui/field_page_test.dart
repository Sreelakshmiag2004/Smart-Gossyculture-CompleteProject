// Phase II 7c: the Field page - the real app with the fake backend's farm-rules endpoints
// (backend/src/gossy/farmrules). Everything shown must be what the backend computed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/farm/farm_models.dart';
import 'package:smart_gossy_culture_app/ui/dashboard.dart';
import 'package:smart_gossy_culture_app/ui/field_page.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';
import '../support/fake_live.dart';

const farmId = 'farm-1';
const device = 'unit-a';

/// What the old sample Harvest page showed and the backend has no source for. None may appear.
const fabricated = ['Harvest Logs', 'Daily Yield', 'Weekly Yield', 'Monthly Yield', 'RECENT LOGS', 'Export', 'Share'];

String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

/// A signed-in farmer who owns one farm with one device, and the rules' result for it:
/// segment R003-S02 ready, R003-S01 building, R004-S01 not ready; a pick list and a
/// spray-blocked aphid advisory; the picking window is WAIT because of humidity.
TestApp farmer({String access = 'owner', bool located = false}) {
  final app = TestApp(random: FixedRandom(1.0))..signIn();
  app.backend.farms.add({
    'id': farmId, 'name': 'North field', 'createdAt': '2026-10-01T00:00:00Z', 'access': access,
    if (located) 'latitude': 11.23,
    if (located) 'longitude': 78.88,
  });
  app.backend.devices.add(FakeBackend.device(device, state: 'online', lastSeenAt: '2026-10-01T15:00:00Z'));
  app.backend.telemetry[device] = [FakeBackend.telemetryRow(time: '2026-10-01T15:00:00Z', batteryPct: 91.4, msgId: '01K6CQ4W0D8V9J4Q9W2Y000001')];
  app.backend.farmStatus[farmId] = FakeBackend.statusRow(
    farmId,
    segments: [
      FakeBackend.segmentRow(3, 1, status: SegmentStatus.building, readiness: 0.3, openBolls: 9),
      FakeBackend.segmentRow(3, 2, status: SegmentStatus.ready, readiness: 0.6667, openBolls: 20),
      FakeBackend.segmentRow(4, 1, status: SegmentStatus.notReady, readiness: 0.0323, openBolls: 1),
    ],
    window: {'status': 'WAIT', 'dewpointC': 24.1, 'dewpointDepressionC': 3.9, 'reasons': ['RH 82.0% > 75.0%']},
    weatherNow: {'airTempC': 28.0, 'airRhPct': 82.0, 'dewpointC': 24.1, 'source': 'cart'},
    rainLast24hMm: 0,
    rainMaxProb48hPct: 35,
    pests: [
      FakeBackend.pestStatusRow('aphid', crossed: true, value: 25, threshold: 10, detail: '5 over 20 units on 2026-10-01'),
      FakeBackend.pestStatusRow('jassid', insufficient: true, threshold: 2, detail: '0 units observed, need 25'),
    ],
  );
  app.backend.farmAdvisories[farmId] = [
    FakeBackend.advisoryRow('adv-1', Advisory.pickList, segments: ['R003-S02'], textEn: 'Ready to pick: R003-S02.', textTa: 'பறிக்கத் தயாரான பகுதிகள்: R003-S02.'),
    FakeBackend.advisoryRow('adv-2', Advisory.sprayBlocked, pest: 'aphid', textEn: 'Aphid has crossed its threshold, but cotton is ready for picking.', textTa: 'அசுவினி சேத நிலையைத் தாண்டியுள்ளது.'),
    FakeBackend.advisoryRow('adv-old', Advisory.pestEtl, pest: 'thrips', active: false, textEn: 'resolved advice'),
  ];
  return app;
}

Future<void> openField(WidgetTester tester) async {
  expect(find.byType(Dashboard), findsOneWidget);
  await tester.tap(find.text('Field').last); // the bottom navigation
  await tester.pumpAndSettle();
  expect(find.byType(FieldPage), findsOneWidget);
}

/// Scrolls the page back to the top, then down until [finder] is built and visible, so items
/// above the current position are found too.
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await toTop(tester);
  await tester.scrollUntilVisible(finder, 300, scrollable: find.byType(Scrollable).first);
}

Future<void> toTop(WidgetTester tester) async {
  tester.state<ScrollableState>(find.byType(Scrollable).first).position.jumpTo(0);
  await tester.pump();
}

void main() {
  testWidgets('shows the backend\'s picking window, advice, field map and pest thresholds', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    await openField(tester);

    expect(textOf(tester, 'fieldFarmName'), 'North field');
    expect(find.byKey(const Key('windowWait')), findsOneWidget);
    expect(find.text('Wait before picking'), findsOneWidget);
    expect(find.text('RH 82.0% > 75.0%'), findsOneWidget, reason: 'the backend\'s reason, unchanged');
    expect(find.textContaining('28 °C, humidity 82% (cart sensor)'), findsOneWidget);

    // Advice: only active ones, the spray block before the pick list.
    expect(textOf(tester, 'adviceText-SPRAY_BLOCKED-aphid'), 'Aphid has crossed its threshold, but cotton is ready for picking.');
    expect(textOf(tester, 'adviceText-PICK_LIST-crop'), 'Ready to pick: R003-S02.');
    expect(find.text('resolved advice'), findsNothing);
    final blockedTop = tester.getTopLeft(find.byKey(const Key('advice-SPRAY_BLOCKED-aphid'))).dy;
    final pickTop = tester.getTopLeft(find.byKey(const Key('advice-PICK_LIST-crop'))).dy;
    expect(blockedTop < pickTop, isTrue, reason: 'pest actions before the routine pick list');

    await scrollTo(tester, find.byKey(const Key('fieldMap')));
    expect(textOf(tester, 'segmentReadiness-R003-S02'), '67%');
    expect(textOf(tester, 'segmentReadiness-R003-S01'), '30%');
    expect(textOf(tester, 'segmentReadiness-R004-S01'), '3%');

    await scrollTo(tester, find.byKey(const Key('pest-jassid')));
    expect(textOf(tester, 'pestState-aphid'), 'Threshold crossed');
    expect(textOf(tester, 'pestState-jassid'), 'Scout more');

    for (final text in fabricated) {
      expect(find.text(text), findsNothing, reason: '"$text" is displayed');
    }
    expect(app.live.openSockets, isEmpty, reason: 'the Field page needs no live connection');
  });

  testWidgets('Tamil shows the backend\'s Tamil texts and titles', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    await openField(tester);
    await tester.tap(find.byKey(const Key('fieldLanguage')));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'adviceText-PICK_LIST-crop'), 'பறிக்கத் தயாரான பகுதிகள்: R003-S02.');
    expect(textOf(tester, 'adviceTitle-PICK_LIST-crop'), 'பருத்தி பறிக்கத் தயார்');
    expect(find.text('ஆலோசனை'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fieldLanguage')));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'adviceTitle-PICK_LIST-crop'), 'Cotton ready to pick');
  });

  testWidgets('a scouting count is sent as entered and the new advice is shown', (tester) async {
    final app = farmer();
    app.backend.onFarmEntry = (call) {
      // As the backend's rules would: mealybug crosses its threshold -> spot treatment.
      app.backend.farmAdvisories[farmId]!.insert(0, FakeBackend.advisoryRow('adv-3', Advisory.spotTreat, pest: 'mealybug', textEn: 'Mealybug has crossed its threshold. Never spray the whole field.'));
    };
    await startApp(tester, app);
    await openField(tester);
    await scrollTo(tester, find.byKey(const Key('addObservation')));
    await tester.tap(find.byKey(const Key('addObservation')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('observationRule')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mealybug').last);
    await tester.pumpAndSettle();
    expect(textOf(tester, 'observationThreshold'), 'Threshold >= 10% of plants; examine at least 41.');
    await tester.enterText(find.byKey(const Key('observationCount')), '50');
    await tester.enterText(find.byKey(const Key('observationUnits')), '41');
    await tester.tap(find.byKey(const Key('entrySave')));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'entryError'), 'The number of plants affected cannot be more than the plants examined.');
    expect(app.backend.count('POST', '/api/v1/farms/$farmId/observations'), 0, reason: 'refused before sending');

    await tester.enterText(find.byKey(const Key('observationCount')), '5');
    await tester.tap(find.byKey(const Key('entrySave')));
    await tester.pumpAndSettle();
    final sent = app.backend.calls.lastWhere((c) => c.path == '/api/v1/farms/$farmId/observations').body! as Map;
    expect(sent['observation'], 'mealybug_grade2_plants');
    expect((sent['count'], sent['units']), (5, 41));
    expect(sent['observedOn'], formatDay(DateTime.now()));
    expect(find.text('Scouting count saved. The advice is up to date.'), findsOneWidget);
    await scrollTo(tester, find.byKey(const Key('advice-SPOT_TREAT-mealybug')));
    expect(textOf(tester, 'adviceText-SPOT_TREAT-mealybug'), 'Mealybug has crossed its threshold. Never spray the whole field.');
  });

  testWidgets('a trap count goes to the backend; its error codes are explained', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    await openField(tester);
    await scrollTo(tester, find.byKey(const Key('addTrap')));
    await tester.tap(find.byKey(const Key('addTrap')));
    await tester.pumpAndSettle();
    app.backend.overrides['/api/v1/farms/$farmId/traps'] = FakeReply.error(422, 'invalid_date');
    await tester.enterText(find.byKey(const Key('trapMoths')), '9');
    await tester.tap(find.byKey(const Key('entrySave')));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'entryError'), 'Choose a day that is not in the future and not more than 60 days ago.');

    app.backend.overrides.remove('/api/v1/farms/$farmId/traps');
    await tester.tap(find.byKey(const Key('entrySave')));
    await tester.pumpAndSettle();
    final sent = app.backend.calls.lastWhere((c) => c.path == '/api/v1/farms/$farmId/traps').body! as Map;
    expect((sent['trap'], sent['moths'], sent['night']), ('PBW-1', 9, formatDay(DateTime.now())));
    expect(find.byKey(const Key('entrySave')), findsNothing, reason: 'the sheet closed');
  });

  testWidgets('a checked detection is sent with its verdict', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    await openField(tester);
    await scrollTo(tester, find.byKey(const Key('addConfirmation')));
    await tester.tap(find.byKey(const Key('addConfirmation')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('confirmationRow')), '4');
    await tester.enterText(find.byKey(const Key('confirmationSegment')), '1');
    await tester.tap(find.byKey(const Key('confirmationNo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('entrySave')));
    await tester.pumpAndSettle();
    final sent = app.backend.calls.lastWhere((c) => c.path == '/api/v1/farms/$farmId/confirmations').body! as Map;
    expect((sent['row'], sent['segment'], sent['className'], sent['verdict']), (4, 1, 'mealybug_colony', 'rejected'));
  });

  testWidgets('the owner sets the location; an operator gets no owner controls', (tester) async {
    final app = farmer();
    await startApp(tester, app);
    await openField(tester);
    expect(find.byKey(const Key('fieldNoLocation')), findsOneWidget);
    await scrollTo(tester, find.byKey(const Key('setLocation')));
    await tester.tap(find.byKey(const Key('setLocation')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('locationLat')), '11.23');
    await tester.enterText(find.byKey(const Key('locationLon')), '78.88');
    await tester.tap(find.byKey(const Key('entrySave')));
    await tester.pumpAndSettle();
    final sent = app.backend.calls.lastWhere((c) => c.method == 'PATCH').body! as Map;
    expect((sent['latitude'], sent['longitude']), (11.23, 78.88));
    expect(textOf(tester, 'fieldLocation'), 'Location 11.2300, 78.8800');
    await toTop(tester);
    expect(find.byKey(const Key('fieldFarmName')), findsOneWidget, reason: 'at the top of the page');
    expect(find.byKey(const Key('fieldNoLocation')), findsNothing);

    final operator = farmer(access: 'operator');
    await tester.pumpWidget(const SizedBox()); // drop the first app
    await startApp(tester, operator);
    await openField(tester);
    expect(find.byKey(const Key('fieldOperator')), findsOneWidget);
    expect(find.byKey(const Key('fieldNoLocation')), findsNothing);
    await scrollTo(tester, find.byKey(const Key('addTrap')));
    expect(find.byKey(const Key('setLocation')), findsNothing);
    expect(find.byKey(const Key('addOperator')), findsNothing);
  });

  testWidgets('not computed yet, and a failed read, are said plainly', (tester) async {
    final app = farmer();
    app.backend.farmStatus.remove(farmId);
    app.backend.farmAdvisories.remove(farmId);
    await startApp(tester, app);
    await openField(tester);
    expect(find.byKey(const Key('fieldNotComputed')), findsOneWidget);
    expect(find.byKey(const Key('windowWait')), findsNothing);

    app.backend.overrides['/api/v1/farms/$farmId/status/recompute'] = FakeReply.error(503, 'service_unavailable');
    await tester.tap(find.byKey(const Key('fieldRefresh')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('fieldStale')), findsOneWidget, reason: 'the last result stays, with a notice');

    final broken = farmer();
    broken.backend.overrides['/api/v1/farm-rules/catalog'] = FakeReply.error(500, 'internal_error');
    await tester.pumpWidget(const SizedBox());
    await startApp(tester, broken);
    await openField(tester);
    expect(find.byKey(const Key('fieldError')), findsOneWidget);
    broken.backend.overrides.clear();
    await tester.tap(find.byKey(const Key('fieldRetry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('windowWait')), findsOneWidget);
  });
}
