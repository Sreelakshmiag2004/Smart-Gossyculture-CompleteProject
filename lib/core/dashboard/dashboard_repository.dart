import '../api/api_client.dart';
import '../models.dart';

/// Dashboard data over the existing Phase 2 REST contract. Read-only; every call goes through
/// the authenticated client of Phase 3A (bearer token, single refresh, session handling).
///
///   GET /api/v1/devices                                   -> [Device]  (status, last seen)
///   GET /api/v1/devices/{deviceId}/telemetry?limit=1      -> Page<TelemetryPoint> (newest first)
///   GET /api/v1/detections?deviceId={deviceId}&limit=1    -> Page<Detection>      (newest first)
///
/// The backend decides which devices the caller may read; an unreadable device answers 404.
class DashboardRepository {
  DashboardRepository({required ApiClient api}) : _api = api;

  final ApiClient _api;

  /// Active devices on the caller's farms, with their status.
  Future<List<Device>> devices() => guardApi(() async {
        final response = await _api.authed.get<dynamic>('/api/v1/devices');
        return asJsonList(response.data).map(Device.fromJson).toList();
      });

  /// The newest telemetry row of [deviceId], or null when the device has sent none.
  Future<TelemetryPoint?> latestTelemetry(String deviceId) => guardApi(() async {
        final response = await _api.authed.get<dynamic>('/api/v1/devices/${Uri.encodeComponent(deviceId)}/telemetry', queryParameters: {'limit': 1});
        final page = Page.fromJson(response.data, TelemetryPoint.fromJson);
        return page.items.isEmpty ? null : page.items.first;
      });

  /// The newest detection reported by [deviceId], or null when there is none.
  Future<Detection?> latestDetection(String deviceId) => guardApi(() async {
        final response = await _api.authed.get<dynamic>('/api/v1/detections', queryParameters: {'deviceId': deviceId, 'limit': 1});
        final page = Page.fromJson(response.data, Detection.fromJson);
        return page.items.isEmpty ? null : page.items.first;
      });
}
