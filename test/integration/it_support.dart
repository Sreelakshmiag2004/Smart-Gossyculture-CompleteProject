// Shared helpers for the dashboard tests against the LOCAL DEVELOPMENT backend with real simulator data
// (backend/deploy/dev/compose.yaml, started with `--profile simulator`).
//
//   simulator -> MQTT/TLS -> ingest -> PostgreSQL/TimescaleDB -> REST API -> app services -> Dashboard
//
// Skipped unless GOSSY_IT_BASE_URL and GOSSY_IT_OTP_CODE are set (see dev_backend_test.dart for
// how to obtain the development test code; it is not stored in the app or in this file).
// The simulator's device id defaults to sim-0001 (GOSSY_IT_SIM_DEVICE overrides it).
//
// Only allow-listed +999 test numbers are used. Not a production test.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_gossy_culture_app/core/app_config.dart';
import 'package:smart_gossy_culture_app/core/app_services.dart';

import '../support/fake_backend.dart' show MemoryTokenStore;

const String farmer = '+99900000003';
const String otherFarmer = '+99900000002';
const String adminPhone = '+99900000009';

final String? baseUrl = Platform.environment['GOSSY_IT_BASE_URL'];
final String? otpCode = Platform.environment['GOSSY_IT_OTP_CODE'];
final String simDevice = Platform.environment['GOSSY_IT_SIM_DEVICE'] ?? 'sim-0001';

final Map<AppServices, MemoryTokenStore> stores = {};

AppServices newServices() {
  final tokens = MemoryTokenStore();
  final services = AppServices.create(config: AppConfig.resolve(baseUrl!, debugBuild: true), tokens: tokens);
  stores[services] = tokens;
  return services;
}

Future<AppServices> signedIn(String phone) async {
  final services = newServices();
  await services.session.requestCode(phone);
  await services.session.verifyCode(phone, otpCode!);
  return services;
}

/// Test harness only: raw access as an administrator / as a farmer, independent of the app code.
Future<Dio> rawClient(String phone) async {
  final dio = Dio(BaseOptions(baseUrl: baseUrl!, contentType: Headers.jsonContentType, validateStatus: (_) => true));
  await dio.post<dynamic>('/api/v1/auth/otp/request', data: {'phone': phone});
  final login = await dio.post<dynamic>('/api/v1/auth/otp/verify', data: {'phone': phone, 'code': otpCode});
  dio.options.headers['Authorization'] = 'Bearer ${(login.data as Map)['accessToken']}';
  return dio;
}

/// Makes sure [farmer] owns the simulator's device, using only existing endpoints: the admin
/// registers the device id (once) and the farmer claims it with the one-time code.
Future<void> ensureSimulatorDeviceClaimed(AppServices services) => ensureDeviceClaimed(services, simDevice, 'Development simulator');

/// The same for any device id that has a development broker credential (e.g. sim-0002).
Future<void> ensureDeviceClaimed(AppServices services, String deviceId, String displayName) async {
  if ((await services.onboarding.listDevices()).any((d) => d.deviceId == deviceId)) return;
  final admin = await rawClient(adminPhone);
  var response = await admin.post<dynamic>('/api/v1/admin/devices', data: {'deviceId': deviceId, 'displayName': displayName});
  if (response.statusCode == 409) response = await admin.post<dynamic>('/api/v1/admin/devices/$deviceId/claim-code');
  expect(response.statusCode, anyOf(200, 201), reason: 'admin could not provision $deviceId');
  final farms = await services.onboarding.listFarms();
  final farm = farms.isNotEmpty ? farms.first : await services.onboarding.createFarm('IT dashboard farm');
  await services.onboarding.claimDevice(deviceId: deviceId, claimCode: (response.data as Map)['claimCode'] as String, farmId: farm.id);
}


final String? skipReason = (baseUrl == null || otpCode == null) ? 'set GOSSY_IT_BASE_URL and GOSSY_IT_OTP_CODE to run against the development backend' : null;
