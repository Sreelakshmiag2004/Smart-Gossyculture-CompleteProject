import '../api/api_client.dart';
import '../models.dart';

/// Detection and spray history of ONE device over the existing Phase 2 REST contract, through
/// the authenticated client of Phase 3A (bearer token, single refresh, session handling).
///
///   GET /api/v1/detections?deviceId=&limit=&cursor=              -> Page<Detection>   (newest first)
///   GET /api/v1/devices/{deviceId}/events?type=spray&limit=&cursor= -> Page<DeviceEvent> (newest first)
///
/// Both are read-only. `cursor` is the backend's opaque `nextCursor`, passed back unchanged.
/// The backend decides which devices the caller may read; an unreadable device answers 404.
class PestHistoryRepository {
  PestHistoryRepository({required ApiClient api}) : _api = api;

  final ApiClient _api;

  /// One page of the detections [deviceId] reported.
  Future<Page<Detection>> detections(String deviceId, {required int limit, String? cursor}) => guardApi(() async {
        final response = await _api.authed.get<dynamic>('/api/v1/detections', queryParameters: {
          'deviceId': deviceId,
          'limit': limit,
          if (cursor != null) 'cursor': cursor,
        });
        return Page.fromJson(response.data, Detection.fromJson);
      });

  /// One page of the spray actions [deviceId] reported.
  Future<Page<SprayRecord>> sprays(String deviceId, {required int limit, String? cursor}) => guardApi(() async {
        final response = await _api.authed.get<dynamic>('/api/v1/devices/${Uri.encodeComponent(deviceId)}/events', queryParameters: {
          'type': SprayRecord.eventType,
          'limit': limit,
          if (cursor != null) 'cursor': cursor,
        });
        return Page.fromJson(response.data, SprayRecord.fromJson);
      });
}
