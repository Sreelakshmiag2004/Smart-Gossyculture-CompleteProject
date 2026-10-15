import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/main.dart';
import 'package:smart_gossy_culture_app/ui/sign_in_page.dart';

import 'fake_backend.dart';

bool _fontLoaded = false;

/// The test environment's placeholder font makes every glyph a full square, about twice as wide as
/// on a device. The app's font (Roboto, shipped with the Flutter SDK) is loaded instead so that
/// layouts are measured as they are on a phone.
Future<void> _loadAppFont() async {
  if (_fontLoaded) return;
  final root = Platform.environment['FLUTTER_ROOT'];
  final file = File('$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
  if (root != null && file.existsSync()) {
    final bytes = file.readAsBytesSync();
    await (FontLoader('Roboto')..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
  }
  _fontLoaded = true;
}

/// Starts the real app (launch page included) on a phone-sized surface with the fake backend.
Future<void> startApp(WidgetTester tester, TestApp app) async {
  await tester.runAsync(_loadAppFont);
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MyApp(services: app.services));
  await tester.pump(const Duration(seconds: 3)); // splash
  await tester.pumpAndSettle();
}

/// Types a phone number on the sign-in page and requests a code.
Future<void> requestCode(WidgetTester tester, String phone) async {
  expect(find.byType(SignInPage), findsOneWidget);
  await tester.enterText(find.byKey(const Key('phoneField')), phone);
  await tester.tap(find.byKey(const Key('continueButton')));
  await tester.pumpAndSettle();
}

Future<void> enterCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byKey(const Key('codeField')), code);
  await tester.tap(find.byKey(const Key('verifyButton')));
  await tester.pumpAndSettle();
}

/// Phone + code through the UI, ending wherever the app navigates next.
Future<void> signInThroughUi(WidgetTester tester, TestApp app) async {
  await requestCode(tester, FakeBackend.allowedPhone);
  await enterCode(tester, app.backend.currentCode);
}
