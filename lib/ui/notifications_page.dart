import 'package:flutter/material.dart';

import '../core/alerts/alerts_controller.dart';
import '../core/api/api_failure.dart';
import '../core/api/failure_messages.dart';
import '../core/app_services.dart';
import '../core/formatting.dart';
import '../core/models.dart';

/// The caller's alerts, as the backend holds them (Phase 5B).
///
/// Every entry is an alert the backend created: a detection a device reported, a spray a device
/// performed, or a device reported offline. Nothing else is listed and nothing is added to what
/// the backend stored - no recommendation, no severity of the app's own, no photo.
///
/// "Read" is the backend's acknowledgement: the Acknowledge button calls the backend, and an
/// alert is shown as acknowledged only once the backend has said so. There is no "mark all as
/// read": the backend has no bulk acknowledgement.
///
/// New alerts appear by themselves while the dashboard's live connection is on; this page
/// opens no connection of its own.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  AlertsController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller == null) {
      _controller = AppScope.of(context).alerts;
      // After the first frame: loading notifies listeners, which must not happen during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller!.load();
      });
    }
  }

  Future<void> _refresh() => _controller!.load();

  Future<void> _acknowledge(Alert alert) async {
    final messenger = ScaffoldMessenger.of(context);
    final failure = await _controller!.acknowledge(alert.id);
    // An ended session is handled by the app shell (return to sign-in).
    if (failure == null || failure.kind == ApiFailureKind.sessionExpired || !mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(key: const Key('acknowledgeError'), content: Text('The alert could not be acknowledged. ${messageForFailure(failure)}')));
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller!;
    return Scaffold(
      backgroundColor: const Color(0xFFF6FBF4), // Match app background
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          'Notifications',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        centerTitle: true,
        actions: [
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => IconButton(
              key: const Key('alertsRefresh'),
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh, color: Colors.black87),
              onPressed: controller.busy ? null : _refresh,
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: const Color(0xFF5FA62C),
        onRefresh: _refresh,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: _buildContent(controller),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildContent(AlertsController controller) {
    switch (controller.phase) {
      case AlertsPhase.idle:
      case AlertsPhase.loading:
        return [
          _buildCard(
            child: const Row(
              key: Key('alertsLoading'),
              children: [
                SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF5FA62C))),
                SizedBox(width: 16),
                Expanded(child: Text('Loading your alerts...', style: TextStyle(fontSize: 15, color: Colors.black54))),
              ],
            ),
          ),
        ];
      case AlertsPhase.error:
        return [
          _buildMessage(
            key: const Key('alertsError'),
            icon: Icons.cloud_off_rounded,
            title: 'Your alerts could not be loaded',
            message: messageForFailure(controller.failure!),
            action: TextButton(
              key: const Key('alertsRetry'),
              onPressed: controller.busy ? null : _refresh,
              child: const Text('Try again'),
            ),
          ),
        ];
      case AlertsPhase.ready:
        final alerts = controller.alerts;
        return [
          if (controller.failure != null) ...[
            _buildMessage(
              key: const Key('alertsRefreshError'),
              icon: Icons.cloud_off_rounded,
              title: 'The alerts could not be updated',
              message: '${messageForFailure(controller.failure!)} Showing the alerts loaded earlier.',
            ),
            const SizedBox(height: 12),
          ],
          if (alerts.isEmpty)
            _buildMessage(
              key: const Key('alertsEmpty'),
              icon: Icons.notifications_none_rounded,
              title: 'No alerts',
              message: 'Alerts appear here when one of your devices reports a detection, performs a spray or goes offline.',
            ),
          for (final alert in alerts) _buildAlertCard(controller, alert),
          if (controller.hasMore)
            Center(
              child: TextButton(
                key: const Key('alertsLoadMore'),
                onPressed: controller.loadingMore || controller.busy ? null : controller.loadMore,
                child: Text(controller.loadingMore ? 'Loading...' : 'Show older alerts'),
              ),
            ),
        ];
    }
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildMessage({required Key key, required IconData icon, required String title, required String message, Widget? action}) {
    return _buildCard(
      child: Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.black45, size: 24),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87))),
            ],
          ),
          const SizedBox(height: 8),
          Text(message, style: const TextStyle(fontSize: 14, color: Colors.black54, height: 1.4)),
          if (action != null) Align(alignment: Alignment.centerRight, child: action),
        ],
      ),
    );
  }

  Widget _buildAlertCard(AlertsController controller, Alert alert) {
    final color = _severityColor(alert.severity);
    final acknowledging = controller.isAcknowledging(alert.id);
    return KeyedSubtree(
      key: Key('alert-${alert.id}'),
      child: _buildCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(_icon(alert.type), color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          alertTitle(alert),
                          key: Key('alertTitle-${alert.id}'),
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.black87),
                        ),
                      ),
                      if (alert.isOpen)
                        Container(
                          key: Key('alertOpen-${alert.id}'),
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    alertMessage(alert),
                    key: Key('alertMessage-${alert.id}'),
                    style: const TextStyle(fontSize: 14, color: Colors.black54, height: 1.4),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    alertTimeLine(alert),
                    key: Key('alertTime-${alert.id}'),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 4),
                  if (alert.isOpen)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: Key('acknowledge-${alert.id}'),
                        onPressed: acknowledging ? null : () => _acknowledge(alert),
                        child: Text(acknowledging ? 'Acknowledging...' : 'Acknowledge'),
                      ),
                    )
                  else
                    Text(
                      alert.acknowledgedAt == null ? 'Acknowledged' : 'Acknowledged ${formatDateTime(alert.acknowledgedAt!)}',
                      key: Key('alertAcknowledged-${alert.id}'),
                      style: const TextStyle(fontSize: 12, color: Colors.black45, fontWeight: FontWeight.w600),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The backend's severity, coloured; a value this app does not know gets a neutral colour.
  static Color _severityColor(String severity) => switch (severity) {
        'warning' => Colors.orange,
        'info' => Colors.blue,
        _ => Colors.grey,
      };

  static IconData _icon(String type) => switch (type) {
        Alert.pestDetected => Icons.bug_report_outlined,
        Alert.sprayPerformed => Icons.shower_outlined,
        Alert.deviceOffline => Icons.cloud_off_outlined,
        _ => Icons.notifications_none_rounded,
      };
}

/// What kind of alert it is, by the backend's `type`. A type this app does not know is named
/// as such; no meaning is guessed for it.
String alertTitle(Alert alert) => switch (alert.type) {
      Alert.pestDetected => 'Detection reported',
      Alert.sprayPerformed => 'Spray performed',
      Alert.deviceOffline => 'Device offline',
      _ => 'Alert',
    };

/// The alert's stored details in words. Only what the backend stored is used.
String alertMessage(Alert alert) {
  final device = 'Device ${alert.deviceId}';
  switch (alert.type) {
    case Alert.pestDetected:
      final label = alert.details['label'];
      final confidence = alert.details['confidence'];
      if (label is! String) return '$device reported a detection.';
      return confidence is num ? '${formatDetectionLabel(label)} · confidence ${formatConfidence(confidence.toDouble())}\n$device' : '${formatDetectionLabel(label)}\n$device';
    case Alert.sprayPerformed:
      final durationMs = alert.details['durationMs'];
      return durationMs is num ? 'Spray duration ${formatSeconds(durationMs)}\n$device' : '$device reported a spray.';
    case Alert.deviceOffline:
      return '$device was reported offline.';
    default:
      return 'Type: ${alert.type}\n$device';
  }
}

/// The device's time for the alert, and the backend's when it differs by more than a minute
/// (an offline report carries the time the device connected, not the time it went offline).
String alertTimeLine(Alert alert) {
  final reported = 'Reported ${formatDateTime(alert.occurredAt)}';
  return alert.createdAt.difference(alert.occurredAt).abs() > const Duration(minutes: 1) ? '$reported · received ${formatDateTime(alert.createdAt)}' : reported;
}
