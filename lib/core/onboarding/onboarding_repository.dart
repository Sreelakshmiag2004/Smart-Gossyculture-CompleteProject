import '../api/api_client.dart';
import '../models.dart';

/// What a signed-in farmer still has to do before the dashboard can show anything.
sealed class OnboardingState {
  const OnboardingState();
}

/// The farmer owns no farm yet.
class NeedsFarm extends OnboardingState {
  const NeedsFarm();
}

/// The farmer owns at least one farm but has no claimed device.
class NeedsDevice extends OnboardingState {
  const NeedsDevice(this.farms);
  final List<Farm> farms;
}

/// At least one farm and one active device: go to the dashboard.
class OnboardingComplete extends OnboardingState {
  const OnboardingComplete();
}

/// Farm and device onboarding with the existing backend endpoints (Phase 2):
///
///   GET  /api/v1/farms                              farms owned by the caller
///   POST /api/v1/farms          {name}              create a farm owned by the caller
///   GET  /api/v1/devices                            active devices on the caller's farms
///   POST /api/v1/devices/claim  {deviceId, claimCode, farmId}
///
/// Ownership, claim-code validity and the attempt limit are enforced by the backend; this class
/// adds no rule of its own and never handles device credentials (the claim code is a one-time
/// registration code, not a credential the device uses).
class OnboardingRepository {
  OnboardingRepository({required ApiClient api}) : _api = api;

  final ApiClient _api;

  Future<List<Farm>> listFarms() => guardApi(() async {
        final response = await _api.authed.get<dynamic>('/api/v1/farms');
        return asJsonList(response.data).map(Farm.fromJson).toList();
      });

  Future<Farm> createFarm(String name) => guardApi(() async {
        final response = await _api.authed.post<dynamic>('/api/v1/farms', data: {'name': name});
        return Farm.fromJson(asJsonObject(response.data));
      });

  Future<List<Device>> listDevices() => guardApi(() async {
        final response = await _api.authed.get<dynamic>('/api/v1/devices');
        return asJsonList(response.data).map(Device.fromJson).toList();
      });

  Future<Device> claimDevice({required String deviceId, required String claimCode, required String farmId}) => guardApi(() async {
        final response = await _api.authed.post<dynamic>('/api/v1/devices/claim', data: {'deviceId': deviceId, 'claimCode': claimCode, 'farmId': farmId});
        return Device.fromJson(asJsonObject(response.data));
      });

  Future<OnboardingState> currentState() async {
    final farms = await listFarms();
    if (farms.isEmpty) return const NeedsFarm();
    final devices = await listDevices();
    if (devices.isEmpty) return NeedsDevice(farms);
    return const OnboardingComplete();
  }
}
