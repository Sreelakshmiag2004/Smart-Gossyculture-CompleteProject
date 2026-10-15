import 'package:flutter/material.dart';

import '../core/api/failure_messages.dart';
import '../core/app_services.dart';
import '../core/dashboard/dashboard_controller.dart';
import '../core/formatting.dart';
import '../core/models.dart';
import '../core/pest/pest_history_controller.dart';
import 'dashboard.dart';
import 'widgets/bottom_nav_bar.dart';

/// Detection history and spray history of the device selected on the dashboard (Phase 5C).
///
/// Every row is a record the backend stores: a detection the device's detector reported, or a
/// spray the device reported having performed. The label is shown exactly as the device sent
/// it. Nothing is added to a record - no recommendation, no severity, no pesticide, no photo.
///
/// The page only reads. It has no control of any kind: the app cannot start a scan, a capture,
/// a treatment or a spray.
///
/// New rows appear by themselves through the dashboard's live connection, which this page keeps
/// in use while it is open; it opens no connection of its own.
class PestAlertsPage extends StatefulWidget {
  const PestAlertsPage({super.key});

  @override
  State<PestAlertsPage> createState() => _PestAlertsPageState();
}

class _PestAlertsPageState extends State<PestAlertsPage> with WidgetsBindingObserver {
  AppServices? _services;

  DashboardController get _dashboard => _services!.dashboard;
  PestHistoryController get _history => _services!.pestHistory;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services == null) {
      _services = AppScope.of(context);
      // The dashboard's live connection stays in use while this page is open (attached as THIS
      // page, so that the dashboard page it replaces does not take the connection with it).
      _dashboard.attachLive(this);
      _history.attach(this);
      // After the first frame: loading notifies listeners, which must not happen during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The same rule as on the dashboard: no connection while the app is in the background.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _services?.dashboard.pauseLive();
      case AppLifecycleState.resumed:
        _services?.dashboard.resumeLive();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _services?.pestHistory.detach(this);
    _services?.dashboard.detachLive(this);
    super.dispose();
  }

  /// Both lists for the selected device. The dashboard's snapshot is read first when it is
  /// missing or its live connection is not open: that is what tells which device is selected
  /// and what (re)starts the connection - REST first, then live, as on the dashboard.
  Future<void> _refresh() async {
    if (_dashboard.phase != DashboardPhase.ready || !_services!.live.isOpen) await _dashboard.load();
    await _history.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA), // Slightly off-white background
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const Dashboard()),
            (route) => false,
          ),
        ),
        title: const Text(
          'Pest & Disease Alerts',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        centerTitle: true,
        actions: [
          ListenableBuilder(
            listenable: Listenable.merge([_dashboard, _history.detections, _history.sprays]),
            builder: (context, _) => IconButton(
              key: const Key('pestRefresh'),
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh, color: Colors.black87),
              onPressed: _dashboard.busy || _history.detections.busy || _history.sprays.busy ? null : _refresh,
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: const Color(0xFF5FA62C),
        onRefresh: _refresh,
        child: ListenableBuilder(
          listenable: Listenable.merge([_dashboard, _history.detections, _history.sprays]),
          builder: (context, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            children: _buildContent(),
          ),
        ),
      ),
      bottomNavigationBar: const CommonBottomNavBar(currentIndex: 2),
    );
  }

  List<Widget> _buildContent() {
    final device = _dashboard.data?.device;
    if (device == null || _history.deviceId != device.deviceId) return [_buildNoDevice()];
    return [
      _buildDeviceLine(device),
      const SizedBox(height: 20),
      _buildSectionHeader('Detections', 'Reported by the device\'s detector. Labels are shown as the device sent them.'),
      const SizedBox(height: 12),
      ..._buildFeed<Detection>(
        feed: _history.detections,
        name: 'detections',
        loadingText: 'Loading detections...',
        errorTitle: 'The detections could not be loaded',
        refreshErrorTitle: 'The detections could not be updated',
        emptyTitle: 'No detection records',
        emptyText: 'The backend holds no detection reported by this device.',
        moreText: 'Show older detections',
        row: _buildDetectionRow,
      ),
      const SizedBox(height: 28),
      _buildSectionHeader('Spray History', 'Sprays the device reported having performed.'),
      const SizedBox(height: 12),
      ..._buildFeed<SprayRecord>(
        feed: _history.sprays,
        name: 'sprays',
        loadingText: 'Loading spray history...',
        errorTitle: 'The spray history could not be loaded',
        refreshErrorTitle: 'The spray history could not be updated',
        emptyTitle: 'No spray records',
        emptyText: 'The backend holds no spray record for this device.',
        moreText: 'Show older sprays',
        row: _buildSprayRow,
      ),
    ];
  }

  /// No device is selected (yet): the dashboard's snapshot is loading, failed, or lists none.
  Widget _buildNoDevice() {
    if (_dashboard.phase == DashboardPhase.error) {
      return _buildMessage(
        key: const Key('pestDeviceError'),
        icon: Icons.cloud_off_rounded,
        title: 'Your device could not be loaded',
        message: messageForFailure(_dashboard.failure!),
        action: TextButton(key: const Key('pestDeviceRetry'), onPressed: _dashboard.busy ? null : _refresh, child: const Text('Try again')),
      );
    }
    if (_dashboard.phase == DashboardPhase.ready && _dashboard.data?.device == null) {
      return _buildMessage(
        key: const Key('pestNoDevice'),
        icon: Icons.devices_other_rounded,
        title: 'No device',
        message: 'Detections and sprays are listed for the device selected on the dashboard. No device is linked to your account.',
      );
    }
    return _buildLoading(const Key('pestDeviceLoading'), 'Loading your device...');
  }

  Widget _buildDeviceLine(Device device) {
    final name = device.displayName;
    return Text(
      name == null || name.isEmpty ? 'Device ${device.deviceId}' : 'Device $name (${device.deviceId})',
      key: const Key('pestDevice'),
      style: const TextStyle(fontSize: 13, color: Colors.black54, fontWeight: FontWeight.w600),
    );
  }

  Widget _buildSectionHeader(String title, String caption) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
            color: Colors.black87,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 2),
        Text(caption, style: const TextStyle(fontSize: 12, color: Colors.black45)),
      ],
    );
  }

  /// One list in whichever state it is: loading, failed, empty, or its rows - with the older
  /// pages on request. The two lists are independent of each other.
  List<Widget> _buildFeed<T>({
    required HistoryFeed<T> feed,
    required String name,
    required String loadingText,
    required String errorTitle,
    required String refreshErrorTitle,
    required String emptyTitle,
    required String emptyText,
    required String moreText,
    required Widget Function(T row) row,
  }) {
    switch (feed.phase) {
      case HistoryPhase.idle:
      case HistoryPhase.loading:
        return [_buildLoading(Key('${name}Loading'), loadingText)];
      case HistoryPhase.error:
        return [
          _buildMessage(
            key: Key('${name}Error'),
            icon: Icons.cloud_off_rounded,
            title: errorTitle,
            message: messageForFailure(feed.failure!),
            action: TextButton(key: Key('${name}Retry'), onPressed: feed.busy ? null : feed.load, child: const Text('Try again')),
          ),
        ];
      case HistoryPhase.ready:
        return [
          if (feed.failure != null) ...[
            _buildMessage(
              key: Key('${name}RefreshError'),
              icon: Icons.cloud_off_rounded,
              title: refreshErrorTitle,
              message: '${messageForFailure(feed.failure!)} Showing the records loaded earlier.',
            ),
            const SizedBox(height: 12),
          ],
          if (feed.rows.isEmpty) _buildMessage(key: Key('${name}Empty'), icon: Icons.inbox_outlined, title: emptyTitle, message: emptyText),
          for (final item in feed.rows) ...[row(item), const SizedBox(height: 12)],
          if (feed.hasMore)
            Center(
              child: TextButton(
                key: Key('${name}LoadMore'),
                onPressed: feed.loadingMore || feed.busy ? null : feed.loadMore,
                child: Text(feed.loadingMore ? 'Loading...' : moreText),
              ),
            ),
        ];
    }
  }

  Widget _buildCard({Key? key, required Widget child}) {
    return Container(
      key: key,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildLoading(Key key, String text) {
    return _buildCard(
      key: key,
      child: Row(
        children: [
          const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF5FA62C))),
          const SizedBox(width: 16),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 15, color: Colors.black54))),
        ],
      ),
    );
  }

  Widget _buildMessage({required Key key, required IconData icon, required String title, required String message, Widget? action}) {
    return _buildCard(
      key: key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.black45, size: 24),
              const SizedBox(width: 12),
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87))),
            ],
          ),
          const SizedBox(height: 8),
          Text(message, style: const TextStyle(fontSize: 13, color: Colors.black54, height: 1.4)),
          if (action != null) Align(alignment: Alignment.centerRight, child: action),
        ],
      ),
    );
  }

  /// One detection: the label as the device sent it, its confidence and the device's time.
  Widget _buildDetectionRow(Detection detection) {
    return _buildCard(
      key: Key('detection-${detection.id}'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.bug_report_outlined, color: Colors.black54, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detection.label,
                  key: Key('detectionLabel-${detection.id}'),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.black87),
                ),
                const SizedBox(height: 4),
                Text(
                  'Confidence: ${formatConfidence(detection.confidence)}',
                  key: Key('detectionConfidence-${detection.id}'),
                  style: const TextStyle(fontSize: 13, color: Colors.black54),
                ),
                const SizedBox(height: 4),
                Text(
                  'Reported ${formatDateTime(detection.detectedAt)}',
                  key: Key('detectionTime-${detection.id}'),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One spray: how long the device reports it sprayed, and the device's time.
  Widget _buildSprayRow(SprayRecord spray) {
    return _buildCard(
      key: Key('spray-${spray.msgId}'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.shower_outlined, color: Colors.black54, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Spray performed', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Colors.black87)),
                const SizedBox(height: 4),
                Text(
                  'Duration ${formatSeconds(spray.durationMs)}',
                  key: Key('sprayDuration-${spray.msgId}'),
                  style: const TextStyle(fontSize: 13, color: Colors.black54),
                ),
                const SizedBox(height: 4),
                Text(
                  'Reported ${formatDateTime(spray.time)}',
                  key: Key('sprayTime-${spray.msgId}'),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
