import 'package:flutter/material.dart';
import '../core/alerts/alerts_controller.dart';
import '../core/api/failure_messages.dart';
import '../core/app_services.dart';
import '../core/dashboard/dashboard_controller.dart';
import '../core/formatting.dart';
import '../core/models.dart';
import '../core/realtime/live_connection.dart';
import 'field_page.dart';
import 'onboarding_gate_page.dart';
import 'pest_alerts_page.dart';
import 'settings_profile_page.dart';
import 'notifications_page.dart';
import 'marketplace_page.dart';
import 'widgets/bottom_nav_bar.dart';

/// Home page. Device status, the newest telemetry reading and the newest reported detection
/// come from the backend: the REST API gives the state when the page opens or the user refreshes
/// (Phase 3B), and the live channel then replaces a value when the backend reports a newer one
/// (Phase 3C, see lib/core/realtime). There is no polling. The live connection exists only while
/// a dashboard page is open and the app is in the foreground (Phase 4): in the background it is
/// closed, and on return the state is read again over REST before it is reopened.
///
/// Only values the backend provides are shown as data. A reading the device did not send is
/// shown as "no reading"; nothing is estimated, and no verdict is attached to a reading.
/// Whether a reading is the device's current one or the last known one is shown next to it
/// (see [ReadingFreshness]); since Phase 5A that includes a device that is online but has sent
/// no reading for longer than the backend's threshold.
class Dashboard extends StatefulWidget {
  const Dashboard({super.key});

  @override
  State<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends State<Dashboard> with WidgetsBindingObserver {
  DashboardController? _controller;
  AlertsController? _alerts;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller == null) {
      // Attached as THIS page: when one dashboard page replaces another, the old page's
      // disposal must not take the connection away from the new one.
      _controller = AppScope.of(context).dashboard..attachLive(this);
      _alerts = AppScope.of(context).alerts;
      // After the first frame: loading notifies listeners, which must not happen during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _controller?.pauseLive();
      case AppLifecycleState.resumed:
        _controller?.resumeLive(); // does nothing unless the app really was in the background
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break; // passing states (a system dialog, the app switcher): the connection is kept
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.detachLive(this); // the last page closes the socket and cancels its timers
    super.dispose();
  }

  /// The dashboard's snapshot and, for the bell, the alerts.
  Future<void> _refresh() async {
    await Future.wait([_controller!.load(), _alerts!.load()]);
  }

  /// The number on the bell: open alerts, "99+" beyond that, "N+" when the backend has more
  /// open alerts than were read. Null (no number) when there are none or it is not known.
  static String? _alertBadge(AlertsController alerts) {
    if (!alerts.openCountKnown || alerts.openCount == 0) return null;
    if (alerts.openCount > 99) return '99+';
    return alerts.openCountIsMinimum ? '${alerts.openCount}+' : '${alerts.openCount}';
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final controller = _controller!;
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA), // Neutral professional background
      appBar: AppBar(
        backgroundColor: const Color(0xFFFAFAFA),
        elevation: 0,
        // No title, clean look
        actions: [
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) => IconButton(
              key: const Key('dashboardRefresh'),
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh, color: Colors.black87),
              onPressed: controller.busy ? null : _refresh,
            ),
          ),
          // The bell shows how many alerts the backend holds as open (not acknowledged). The
          // number comes from the alerts' `status` field only; before the alerts have been
          // read, or when reading them failed, no number is shown.
          ListenableBuilder(
            listenable: services.alerts,
            builder: (context, _) {
              final badge = _alertBadge(services.alerts);
              return IconButton(
                key: const Key('dashboardBell'),
                tooltip: 'Notifications',
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.notifications_outlined, color: Colors.black87), // Outlined icon
                    if (badge != null)
                      Positioned(
                        right: -6,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          constraints: const BoxConstraints(minWidth: 16),
                          decoration: BoxDecoration(color: const Color(0xFFD32F2F), borderRadius: BorderRadius.circular(8)),
                          child: Text(
                            badge,
                            key: const Key('alertBadge'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                  ],
                ),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const NotificationsPage(),
                    ),
                  );
                },
              );
            },
          ),

          Padding(
            padding: const EdgeInsets.only(right: 16, left: 8),
            child: InkWell(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const SettingsProfilePage(),
                  ),
                );
              },
              borderRadius: BorderRadius.circular(18),
              child: CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF5FA62C),
                child: const Icon(Icons.person, color: Colors.white, size: 20),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: const Color(0xFF5FA62C),
        onRefresh: _refresh,
        child: SafeArea(
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Greeting Section
              ListenableBuilder(
                listenable: services.session,
                builder: (context, _) {
                  final name = services.session.user?.displayName?.trim();
                  return Text(
                    'Welcome back, ${name == null || name.isEmpty ? 'Farmer' : name}!',
                    key: const Key('greeting'),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 26, // Larger, more prominent
                      color: Colors.black87,
                      letterSpacing: -0.5,
                    ),
                  );
                },
              ),
              const SizedBox(height: 6),
              Text(
                formatDateHeader(DateTime.now()), // today's date from the phone's clock
                key: const Key('dateLine'),
                style: const TextStyle(
                  color: Colors.black54,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 24),

              ListenableBuilder(
                listenable: controller,
                builder: (context, _) => _buildData(context, controller),
              ),

              const SizedBox(height: 28),
              
              const Text(
                'Quick Actions',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 16),

              LayoutBuilder(
                builder: (context, constraints) {
                  return GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 1.5, // Wider buttons
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    children: [
                      _DashboardButton(
                        icon: Icons.search,
                        label: 'Monitor',
                        color: const Color(0xFF4A90E2),
                        onTap: () {},
                      ),
                      _DashboardButton(
                        icon: Icons.grass_rounded,
                        label: 'Field',
                        color: const Color(0xFF5FA62C),
                        onTap: () {
                           Navigator.of(context).pushReplacement(
                            MaterialPageRoute(builder: (context) => const FieldPage()),
                          );
                        },
                      ),
                      _DashboardButton(
                        icon: Icons.qr_code_scanner,
                        label: 'Scan',
                         color: const Color(0xFF9C27B0),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const PestAlertsPage(),
                            ),
                          );
                        },
                      ),
                      _DashboardButton(
                        icon: Icons.storefront,
                        label: 'Market',
                         color: const Color(0xFFFF9800),
                        onTap: () {
                           Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => const MarketplacePage(),
                            ),
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
      ),
      bottomNavigationBar: const CommonBottomNavBar(currentIndex: 0),
    );
  }

  // ---------------------------------------------------------------- backend-driven section

  Widget _buildData(BuildContext context, DashboardController controller) {
    final data = controller.data;
    switch (controller.phase) {
      case DashboardPhase.idle:
      case DashboardPhase.loading:
        return _buildLoading();
      case DashboardPhase.error:
        return _buildMessageCard(
          key: const Key('dashboardError'),
          icon: Icons.cloud_off_rounded,
          title: 'Your farm data could not be loaded',
          message: messageForFailure(controller.failure!),
          actionKey: const Key('dashboardRetry'),
          actionLabel: 'Try again',
          onAction: controller.busy ? null : _refresh,
        );
      case DashboardPhase.ready:
        if (data == null) return _buildLoading();
        final device = data.device;
        if (device == null) {
          // Normally prevented by onboarding; possible if the device was detached on the backend.
          return _buildMessageCard(
            key: const Key('dashboardNoDevice'),
            icon: Icons.memory_outlined,
            title: 'No device is linked to your farm',
            message: 'Add your BollBot device to see its data here.',
            actionKey: const Key('dashboardAddDevice'),
            actionLabel: 'Add a device',
            onAction: () => Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (context) => const OnboardingGatePage()),
              (route) => false,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (controller.failure != null) ...[
              _buildRefreshError(controller, data),
              const SizedBox(height: 16),
            ],
            _buildDeviceRow(controller, data, device),
            const SizedBox(height: 16),
            if (data.telemetry == null) ...[
              _buildMessageCard(
                key: const Key('dashboardNoTelemetry'),
                icon: Icons.sensors_off_outlined,
                title: 'No readings yet',
                message: 'This device has not sent any data. Readings appear here after the device connects and reports.',
              ),
              const SizedBox(height: 16),
            ],
            if (controller.freshness != null) ...[
              _buildFreshness(controller.freshness!, controller.staleAfter),
              const SizedBox(height: 10),
            ],
            _buildReadings(data.telemetry, current: controller.freshness == ReadingFreshness.live),
            if (data.latestDetection != null) ...[
              const SizedBox(height: 20),
              _buildDetectionBanner(context, data.latestDetection!),
            ],
          ],
        );
    }
  }

  Widget _buildLoading() {
    return _buildStatusCard(
      child: const Row(
        key: Key('dashboardLoading'),
        children: [
          SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF5FA62C))),
          SizedBox(width: 16),
          Expanded(child: Text('Loading your farm data...', style: TextStyle(fontSize: 15, color: Colors.black54))),
        ],
      ),
    );
  }

  Widget _buildMessageCard({
    required Key key,
    required IconData icon,
    required String title,
    required String message,
    Key? actionKey,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return KeyedSubtree(
      key: key,
      child: _buildStatusCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Colors.black38, size: 26),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Colors.black87))),
              ],
            ),
            const SizedBox(height: 8),
            Text(message, style: const TextStyle(fontSize: 14, color: Colors.black54, height: 1.4)),
            if (actionLabel != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: actionKey,
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF5FA62C), foregroundColor: Colors.white),
                  onPressed: onAction,
                  child: Text(actionLabel, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// A refresh failed: the values below are the last ones loaded, and say so.
  Widget _buildRefreshError(DashboardController controller, DashboardData data) {
    return Container(
      key: const Key('dashboardRefreshError'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFFD591)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${messageForFailure(controller.failure!)}\nShowing data loaded ${formatDateTime(data.loadedAt)}.',
              style: const TextStyle(color: Color(0xFF874D00), fontSize: 13, height: 1.35),
            ),
          ),
          TextButton(
            key: const Key('dashboardRefreshRetry'),
            onPressed: controller.busy ? null : _refresh,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  /// Which device is shown, its reported connection state and when it was last heard from.
  Widget _buildDeviceRow(DashboardController controller, DashboardData data, Device device) {
    final state = device.status.state;
    final Color stateColor = switch (state) { 'online' => const Color(0xFF5FA62C), 'offline' => const Color(0xFFCF1322), _ => Colors.black45 };
    final String stateText = switch (state) { 'online' => 'Online', 'offline' => 'Offline', _ => 'Status not reported' };
    final lastSeen = device.status.lastSeenAt;
    return _buildStatusCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.memory_outlined, color: Colors.black54, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: data.devices.length > 1
                    ? DropdownButton<String>(
                        key: const Key('deviceSelector'),
                        value: device.deviceId,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final d in data.devices)
                            DropdownMenuItem(value: d.deviceId, child: Text(_deviceName(d), overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: controller.busy ? null : (value) => value == null ? null : controller.selectDevice(value),
                      )
                    : Text(
                        _deviceName(device),
                        key: const Key('deviceName'),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Colors.black87),
                      ),
              ),
              const SizedBox(width: 8),
              Container(
                key: const Key('deviceStatus'),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(stateText, style: TextStyle(color: stateColor, fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            lastSeen == null ? 'Not heard from yet' : 'Last heard from: ${formatDateTime(lastSeen)}',
            key: const Key('deviceLastSeen'),
            style: const TextStyle(color: Colors.black54, fontSize: 13),
          ),
          ..._buildLiveStatus(controller.liveState),
        ],
      ),
    );
  }

  /// State of the app's live connection to the server. It is worded and coloured so that it
  /// cannot be read as the device's state or as a sensor problem: the values on the page stay
  /// as they are whatever this line says.
  List<Widget> _buildLiveStatus(LiveState state) {
    final String text = switch (state) {
      LiveState.connected => 'Live updates on',
      LiveState.connecting => 'Connecting to live updates...',
      LiveState.reconnecting => 'Live updates interrupted - reconnecting. Showing the last values received.',
      LiveState.authFailed || LiveState.unavailable => 'Live updates are off. Refresh to update.',
      LiveState.disconnected => 'Live updates are not connected.',
    };
    return [
      const SizedBox(height: 4),
      Text(text, key: const Key('liveStatus'), style: const TextStyle(color: Colors.black45, fontSize: 12)),
    ];
  }

  String _deviceName(Device device) {
    final name = device.displayName?.trim();
    return name == null || name.isEmpty ? device.deviceId : '$name (${device.deviceId})';
  }

  /// Says whether the readings below are the device's current ones or the last known ones, and
  /// why. It follows what the backend reports (device online / offline), the state of the live
  /// channel and - Phase 5A - how long ago the backend last received a reading, against the
  /// threshold the backend gives ([staleAfter]). The reading's own time is always shown.
  Widget _buildFreshness(ReadingFreshness freshness, Duration? staleAfter) {
    final live = freshness == ReadingFreshness.live;
    final color = live ? const Color(0xFF3F7D1A) : const Color(0xFF874D00);
    final text = switch (freshness) {
      ReadingFreshness.live => 'Live - newest reading from the device',
      ReadingFreshness.noRecentReading =>
        'Last known reading - no reading received for over ${staleAfter == null ? 'the expected time' : formatDurationWords(staleAfter)}',
      ReadingFreshness.deviceOffline => 'Last known reading - the device is offline',
      ReadingFreshness.deviceStatusUnknown => 'Last known reading - the device has not reported its status',
      ReadingFreshness.notConnected => 'Last known reading - live updates are not connected',
    };
    return Container(
      key: const Key('readingFreshnessBox'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: live ? const Color(0xFFE9F7E5) : const Color(0xFFFFF7E6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: live ? const Color(0xFFB7E3A8) : const Color(0xFFFFD591)),
      ),
      child: Row(
        children: [
          Icon(live ? Icons.sensors : Icons.history, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, key: const Key('readingFreshness'), style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// The reading cards. [telemetry] is the newest row the backend holds for the device;
  /// [current] is false when that row is only the last known reading (shown in grey).
  Widget _buildReadings(TelemetryPoint? telemetry, {required bool current}) {
    const noReading = '—';
    final valueColor = current ? Colors.black87 : Colors.black45;
    final bolls = telemetry?.bollsHarvestedTotal;
    final moisture = telemetry?.moistureRhPct;
    final airTemp = telemetry?.airTempC;
    final solar = telemetry?.solarActive;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Cotton Boll Count Card
        _buildStatusCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Cotton Boll Count',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      bolls == null ? noReading : formatCount(bolls),
                      key: const Key('bollValue'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 36, // Bigger impact
                        color: valueColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      // The backend field bollsHarvestedTotal: the count of harvested bolls the
                      // device itself reports with its telemetry (contract: integer >= 0,
                      // optional). It is not an estimate of bolls on the plants, and the contract
                      // does not say when a device starts its count again.
                      bolls == null ? 'No reading' : 'Bolls harvested (device total)',
                      key: const Key('bollCaption'),
                      style: TextStyle(
                        color: bolls == null ? Colors.black45 : Colors.green,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFE9F7E5),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.agriculture, // Changed icon to agriculture for variety check
                    color: Color(0xFF5FA62C), size: 32),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Split Row: Moisture & Power
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _buildStatusCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Moisture',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: Colors.black54,
                          ),
                        ),
                        Icon(
                          Icons.water_drop,
                          color: Color(0xFF00B2FF),
                          size: 20,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      moisture == null ? noReading : formatPercent(moisture),
                      key: const Key('moistureValue'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 28,
                        color: valueColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      // A reading only. No "optimal"/"ready" verdict exists (U-1 is undecided).
                      moisture == null ? 'No reading' : 'Sensor reading (%RH)',
                      key: const Key('moistureCaption'),
                      style: const TextStyle(
                        color: Colors.black45,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildStatusCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Power',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: Colors.black54,
                          ),
                        ),
                        Icon(
                          Icons.flash_on,
                          color: Color(0xFFFFC107), // Amber for power
                          size: 20,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      telemetry?.batteryPct == null ? noReading : formatPercent(telemetry!.batteryPct!),
                      key: const Key('powerValue'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 28,
                        color: valueColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      telemetry == null
                          ? 'No reading'
                          : switch (solar) { true => 'Solar Active', false => 'Solar inactive', null => 'Battery level' },
                      key: const Key('powerCaption'),
                      style: TextStyle(
                        color: solar == true ? Colors.orange : Colors.black45,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Air temperature: the optional telemetry field airTempC, shown as reported.
        _buildStatusCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Air temperature',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: Colors.black54,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      airTemp == null ? noReading : formatTemperature(airTemp),
                      key: const Key('airTempValue'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 28,
                        color: valueColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      // A reading only, like moisture: no verdict is attached to it.
                      airTemp == null ? 'No reading' : 'Sensor reading (°C)',
                      key: const Key('airTempCaption'),
                      style: const TextStyle(
                        color: Colors.black45,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.thermostat, color: Color(0xFFFF7043), size: 24),
            ],
          ),
        ),
        if (telemetry != null) ...[
          const SizedBox(height: 10),
          Text(
            'Reading taken by the device: ${formatDateTime(telemetry.time)}',
            key: const Key('telemetryTime'),
            style: const TextStyle(color: Colors.black45, fontSize: 12),
          ),
        ],
      ],
    );
  }

  /// The newest detection the device reported (label and confidence as reported).
  Widget _buildDetectionBanner(BuildContext context, Detection detection) {
    return Material(
      key: const Key('detectionBanner'),
      color: const Color(0xFFFFF2F0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFFFFCCC7)),
      ),
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => const PestAlertsPage(),
            ),
          );
        },
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF4D4F),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.warning_amber_rounded,
                    color: Colors.white, size: 24),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Latest detection',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Color(0xFFCF1322),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${formatDetectionLabel(detection.label)} · confidence ${formatConfidence(detection.confidence)}\nReported ${formatDateTime(detection.detectedAt)}',
                      key: const Key('detectionText'),
                      style: const TextStyle(
                        color: Color(0xFFA8071A),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFFCF1322)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04), // Very subtle shadow
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: child,
    );
  }
}

class _DashboardButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _DashboardButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
             borderRadius: BorderRadius.circular(16),
             border: Border.all(color: Colors.grey.withOpacity(0.1)),
             boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.03),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                )
             ]
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                style: TextStyle(
                  color: Colors.black87,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
