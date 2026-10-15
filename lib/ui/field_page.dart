import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api/api_failure.dart';
import '../core/api/failure_messages.dart';
import '../core/app_services.dart';
import '../core/farm/farm_controller.dart';
import '../core/farm/farm_models.dart';
import '../core/formatting.dart';
import '../core/validators.dart';
import 'dashboard.dart';
import 'widgets/bottom_nav_bar.dart';

const Color _green = Color(0xFF5FA62C);
const Color _amber = Color(0xFFF2A007);
const Color _red = Color(0xFFD64545);
const Color _blue = Color(0xFF2F80ED);

/// The farm's field view from the backend's farm rules (Phase II 7c): advice in English or Tamil,
/// whether picking is safe now, readiness of every row segment from the cart's scans, the pest
/// thresholds, and entry of field data (trap counts, scouting counts, checked detections).
///
/// Every value shown is what the backend computed; the page derives no advice of its own and has
/// no control of any kind: nothing here reaches a device.
class FieldPage extends StatefulWidget {
  const FieldPage({super.key});

  @override
  State<FieldPage> createState() => _FieldPageState();
}

class _FieldPageState extends State<FieldPage> {
  AppServices? _services;

  FarmController get _farm => _services!.farm;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services == null) {
      _services = AppScope.of(context);
      // After the first frame: loading notifies listeners, which must not happen during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _farm.load();
      });
    }
  }

  Future<void> _refresh() => _farm.load(recompute: true);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6FBF4),
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
        title: const Text('Field', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 20)),
        centerTitle: true,
        actions: [
          ListenableBuilder(
            listenable: _farm,
            builder: (context, _) => TextButton(
              key: const Key('fieldLanguage'),
              onPressed: () => _farm.tamil = !_farm.tamil,
              child: Text(_farm.tamil ? 'English' : 'தமிழ்', style: const TextStyle(color: _green, fontWeight: FontWeight.bold)),
            ),
          ),
          ListenableBuilder(
            listenable: _farm,
            builder: (context, _) => IconButton(
              key: const Key('fieldRefresh'),
              tooltip: 'Run the field rules now',
              icon: const Icon(Icons.refresh, color: Colors.black87),
              onPressed: _farm.busy ? null : _refresh,
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: _green,
        onRefresh: _refresh,
        child: ListenableBuilder(
          listenable: _farm,
          builder: (context, _) => ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: _content(),
          ),
        ),
      ),
      bottomNavigationBar: const CommonBottomNavBar(currentIndex: 1),
    );
  }

  // --------------------------------------------------------------------------- content
  List<Widget> _content() {
    switch (_farm.phase) {
      case FarmPhase.idle:
      case FarmPhase.loading:
        return [const _Message(key: Key('fieldLoading'), icon: Icons.hourglass_top_rounded, title: 'Loading your field...', loading: true)];
      case FarmPhase.error:
        return [
          _Message(
            key: const Key('fieldError'),
            icon: Icons.cloud_off_rounded,
            title: 'The field could not be loaded',
            text: messageForFailure(_farm.failure!),
            action: TextButton(key: const Key('fieldRetry'), onPressed: _farm.busy ? null : () => _farm.load(), child: const Text('Try again')),
          ),
        ];
      case FarmPhase.ready:
        break;
    }
    final farm = _farm.farm;
    if (farm == null) {
      return [const _Message(key: Key('fieldNoFarm'), icon: Icons.agriculture_rounded, title: 'No farm yet', text: 'Create a farm first. Its field view appears here.')];
    }
    final status = _farm.status;
    final tamil = _farm.tamil;
    return [
      if (_farm.farms.length > 1) _farmPicker(),
      _farmHeader(),
      if (_farm.failure != null)
        _Banner(key: const Key('fieldStale'), color: _amber, text: 'Showing the last result. ${messageForFailure(_farm.failure!)}'),
      if (farm.isOwner && !farm.hasLocation)
        _Banner(
          key: const Key('fieldNoLocation'),
          color: _blue,
          text: 'Set the farm\'s location to get rain forecasts and the rain alert.',
          action: TextButton(onPressed: _setLocation, child: const Text('Set location')),
        ),
      if (status == null || status.computedAt == null)
        const _Message(
          key: Key('fieldNotComputed'),
          icon: Icons.pending_outlined,
          title: 'No result yet',
          text: 'The field rules have not run for this farm yet. Pull down to run them now.',
        )
      else ...[
        _section('Picking window', 'Is it safe to pick now? Dew, humidity and recent rain spoil lint quality.'),
        _windowCard(status),
        _section(tamil ? 'ஆலோசனை' : 'Advice', 'From the farm rules, in ${tamil ? 'Tamil' : 'English'}.'),
        if (_farm.advisories.isEmpty)
          const _Message(key: Key('fieldNoAdvice'), icon: Icons.check_circle_outline_rounded, title: 'No advice right now', text: 'Nothing is ready to pick and no pest threshold is crossed.')
        else
          for (final a in _farm.advisories) _AdviceCard(advisory: a, tamil: tamil, ruleName: a.pest == null ? null : _farm.ruleFor(a.pest!)?.name(tamil)),
        _section('Field map', 'Readiness of each row segment from the cart\'s latest scan (last 14 days).'),
        _fieldMap(status),
        _section('Pest thresholds', 'Each rule with its value now. "Scout more" means there is not yet enough evidence to decide.'),
        for (final p in status.pests) _pestRow(p, tamil),
      ],
      _section('Field data', 'Counts you take in the field. The advice updates as soon as they are saved.'),
      _dataButtons(),
      if (farm.isOwner) ...[
        _section('Farm', 'Only you, the owner, can change these.'),
        _ownerButtons(),
      ],
    ];
  }

  Widget _farmPicker() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropdownButton<String>(
        key: const Key('fieldFarmPicker'),
        value: _farm.farm?.id,
        isExpanded: true,
        items: [for (final f in _farm.farms) DropdownMenuItem(value: f.id, child: Text(f.name))],
        onChanged: (id) {
          if (id != null) _farm.select(id);
        },
      ),
    );
  }

  Widget _farmHeader() {
    final farm = _farm.farm!;
    final computed = _farm.status?.computedAt;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(farm.name, key: const Key('fieldFarmName'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          if (!farm.isOwner)
            const Text('You enter field data for this farm (operator).', key: Key('fieldOperator'), style: TextStyle(color: Colors.black54)),
          if (computed != null)
            Text('Rules last run ${formatDateTime(computed)}', key: const Key('fieldComputedAt'), style: const TextStyle(color: Colors.black54, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _section(String title, String caption) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.black87)),
          const SizedBox(height: 2),
          Text(caption, style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------- picking window
  Widget _windowCard(FarmStatus status) {
    final window = status.window;
    final weather = status.weatherNow;
    final lines = <String>[
      if (weather != null)
        '${formatTemperature(weather.airTempC)}, humidity ${formatPercent(weather.airRhPct)} (${weather.fromCart ? 'cart sensor' : 'forecast'})',
      if (status.rainLast24hMm != null) 'Rain in the last 24 h: ${_decimal(status.rainLast24hMm!)} mm',
      if (status.rainMaxProb48hPct != null) 'Chance of rain in the next 48 h: up to ${formatPercent(status.rainMaxProb48hPct!)}',
    ];
    if (window == null) {
      return _Card(
        key: const Key('windowUnknown'),
        color: Colors.grey,
        icon: Icons.help_outline_rounded,
        title: 'No weather reading',
        lines: ['There is no recent cart reading and no forecast for this farm.', ...lines],
      );
    }
    return _Card(
      key: Key(window.safe ? 'windowSafe' : 'windowWait'),
      color: window.safe ? _green : _amber,
      icon: window.safe ? Icons.check_circle_rounded : Icons.schedule_rounded,
      title: window.safe ? 'Safe to pick now' : 'Wait before picking',
      lines: [
        ...window.reasons,
        'Dew point ${formatTemperature(window.dewpointC)}; air is ${_decimal(window.dewpointDepressionC)} °C above it',
        ...lines,
      ],
    );
  }

  // --------------------------------------------------------------------------- field map
  Widget _fieldMap(FarmStatus status) {
    if (status.segments.isEmpty) {
      return const _Message(key: Key('fieldNoScans'), icon: Icons.grid_off_rounded, title: 'No scans yet', text: 'No cart scan in the last 14 days. Segments appear after the cart\'s next pass.');
    }
    final rows = <int, List<SegmentStatus>>{};
    for (final s in status.segments) {
      rows.putIfAbsent(s.row, () => []).add(s);
    }
    final rowNumbers = rows.keys.toList()..sort();
    return Container(
      key: const Key('fieldMap'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rowNumbers)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 56, child: Padding(padding: const EdgeInsets.only(top: 10), child: Text('Row $row', style: const TextStyle(fontWeight: FontWeight.w600)))),
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [for (final s in rows[row]!..sort((a, b) => a.segment.compareTo(b.segment))) _SegmentTile(segment: s)],
                    ),
                  ),
                ],
              ),
            ),
          const Divider(),
          const Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              _Legend(color: _green, text: 'Ready (40% open or more)'),
              _Legend(color: _amber, text: 'Building (20-40%)'),
              _Legend(color: Color(0xFF9BB88A), text: 'Not ready'),
              _Legend(color: Colors.grey, text: 'No bolls seen'),
            ],
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------- pests
  Widget _pestRow(PestStatus p, bool tamil) {
    final name = _farm.ruleFor(p.pest)?.name(tamil) ?? formatDetectionLabel(p.pest);
    final (Color color, String label) = p.crossed
        ? (_red, 'Threshold crossed')
        : p.insufficient
            ? (Colors.grey, 'Scout more')
            : (_green, 'Below threshold');
    final value = p.value == null ? '' : 'Value ${_decimal(p.value!)} / threshold ${_decimal(p.threshold)}';
    return Container(
      key: Key('pest-${p.pest}'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(value.isEmpty ? p.detail : '$value. ${p.detail}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
            child: Text(label, key: Key('pestState-${p.pest}'), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------- data entry
  Widget _dataButtons() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _ActionButton(key: const Key('addTrap'), icon: Icons.pest_control_rodent_outlined, label: 'Trap count', onPressed: () => _openSheet(_TrapForm(farm: _farm))),
        _ActionButton(
          key: const Key('addObservation'),
          icon: Icons.fact_check_outlined,
          label: 'Scouting count',
          onPressed: _farm.scoutingRules.isEmpty ? null : () => _openSheet(_ObservationForm(farm: _farm)),
        ),
        _ActionButton(key: const Key('addConfirmation'), icon: Icons.center_focus_strong_outlined, label: 'Check a detection', onPressed: () => _openSheet(_ConfirmationForm(farm: _farm))),
      ],
    );
  }

  Widget _ownerButtons() {
    final farm = _farm.farm!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (farm.hasLocation)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Location ${farm.latitude!.toStringAsFixed(4)}, ${farm.longitude!.toStringAsFixed(4)}', key: const Key('fieldLocation')),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _ActionButton(key: const Key('setLocation'), icon: Icons.place_outlined, label: farm.hasLocation ? 'Change location' : 'Set location', onPressed: _setLocation),
            _ActionButton(key: const Key('addOperator'), icon: Icons.person_add_alt_1_outlined, label: 'Add operator', onPressed: () => _openSheet(_OperatorForm(farm: _farm))),
          ],
        ),
      ],
    );
  }

  Future<void> _setLocation() => _openSheet(_LocationForm(farm: _farm));

  Future<void> _openSheet(Widget form) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 28), child: form),
      ),
    );
    if (saved != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(key: const Key('fieldSaved'), content: Text(saved)));
    }
  }
}

String _decimal(double value) => value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(1);

// ============================================================================= small widgets
class _Message extends StatelessWidget {
  const _Message({super.key, required this.icon, required this.title, this.text, this.action, this.loading = false});

  final IconData icon;
  final String title;
  final String? text;
  final Widget? action;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          if (loading) const CircularProgressIndicator(color: _green) else Icon(icon, size: 36, color: Colors.black38),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          if (text != null) ...[const SizedBox(height: 4), Text(text!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54))],
          if (action != null) ...[const SizedBox(height: 8), action!],
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.color, required this.text, this.action});

  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.4))),
      child: Row(children: [Expanded(child: Text(text)), if (action != null) action!]),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({super.key, required this.color, required this.icon, required this.title, required this.lines});

  final Color color;
  final IconData icon;
  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border(left: BorderSide(color: color, width: 5))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [Icon(icon, color: color), const SizedBox(width: 8), Expanded(child: Text(title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17, color: color)))]),
          for (final line in lines) Padding(padding: const EdgeInsets.only(top: 4), child: Text(line, style: const TextStyle(color: Colors.black87))),
        ],
      ),
    );
  }
}

/// Titles of the backend's advisory types (the same wording as its push titles).
const Map<String, (String, String)> _adviceTitles = {
  Advisory.pickNow: ('Pick now – rain coming', 'இப்போதே பறிக்கவும் – மழை வருகிறது'),
  Advisory.pickList: ('Cotton ready to pick', 'பருத்தி பறிக்கத் தயார்'),
  Advisory.pestEtl: ('Pest threshold crossed', 'பூச்சி சேத நிலை தாண்டியது'),
  Advisory.spotTreat: ('Spot treatment needed', 'குறிப்பிட்ட இடத்தில் சிகிச்சை தேவை'),
  Advisory.pestAlert: ('Disease alert', 'நோய் எச்சரிக்கை'),
  Advisory.sprayBlocked: ('Pest found – pick first', 'பூச்சி கண்டறியப்பட்டது – முதலில் பறிக்கவும்'),
};

const Map<String, Color> _adviceColors = {
  Advisory.pickNow: _red,
  Advisory.pickList: _green,
  Advisory.pestEtl: _amber,
  Advisory.spotTreat: _amber,
  Advisory.pestAlert: _red,
  Advisory.sprayBlocked: _blue,
};

class _AdviceCard extends StatelessWidget {
  const _AdviceCard({required this.advisory, required this.tamil, this.ruleName});

  final Advisory advisory;
  final bool tamil;
  final String? ruleName;

  @override
  Widget build(BuildContext context) {
    final titles = _adviceTitles[advisory.type]!;
    final color = _adviceColors[advisory.type]!;
    final id = '${advisory.type}-${advisory.pest ?? 'crop'}';
    return Container(
      key: Key('advice-$id'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border(left: BorderSide(color: color, width: 5))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tamil ? titles.$2 : titles.$1, key: Key('adviceTitle-$id'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color)),
          if (ruleName != null) Text(ruleName!, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 6),
          Text(advisory.text(tamil), key: Key('adviceText-$id'), style: const TextStyle(height: 1.35)),
          if (advisory.segments.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [for (final s in advisory.segments) Chip(label: Text(s), visualDensity: VisualDensity.compact)]),
          ],
        ],
      ),
    );
  }
}

class _SegmentTile extends StatelessWidget {
  const _SegmentTile({required this.segment});

  final SegmentStatus segment;

  @override
  Widget build(BuildContext context) {
    final color = switch (segment.status) {
      SegmentStatus.ready => _green,
      SegmentStatus.building => _amber,
      SegmentStatus.notReady => const Color(0xFF9BB88A),
      _ => Colors.grey,
    };
    final r = segment.readiness;
    return Tooltip(
      message: '${segment.key}: ${segment.openBolls} open bolls, scanned ${formatDateTime(segment.scannedAt)}',
      child: Container(
        key: Key('segment-${segment.key}'),
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
        child: Column(
          children: [
            Text('S${segment.segment}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
            Text(r == null ? '–' : '${(r * 100).round()}%', key: Key('segmentReadiness-${segment.key}'), style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
      const SizedBox(width: 4),
      Text(text, style: const TextStyle(fontSize: 11, color: Colors.black54)),
    ]);
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({super.key, required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(foregroundColor: _green, side: const BorderSide(color: _green), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    );
  }
}

// ============================================================================= forms
/// Wording for the backend's data-entry error codes; everything else as elsewhere in the app.
String _entryError(ApiFailure failure) {
  switch (failure.code) {
    case 'invalid_date':
      return 'Choose a day that is not in the future and not more than 60 days ago.';
    case 'unknown_trap_type':
      return 'Use a pheromone-trap id that starts with PBW, for example PBW-1.';
    case 'count_exceeds_units':
      return 'The number of plants counted cannot be more than the plants examined.';
    case 'unknown_observation':
      return 'This count type is not known to the server. Refresh the page and try again.';
    case 'owner_is_not_operator':
      return 'That is your own number: as the owner you already have full access.';
  }
  return messageForFailure(failure);
}

/// Base of the entry sheets: title, fields, error line and a save button that runs [save].
abstract class _EntryForm extends StatefulWidget {
  const _EntryForm({required this.farm});

  final FarmController farm;
}

abstract class _EntryFormState<T extends _EntryForm> extends State<T> {
  String? _error;
  bool _saving = false;

  String get title;
  List<Widget> fields();

  /// Validates and saves; returns the confirmation text, or null after setting [_error].
  Future<String?> save();

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final done = await save();
      if (!mounted) return;
      if (done != null) {
        Navigator.of(context).pop(done);
        return;
      }
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      _error = _entryError(failure);
    }
    setState(() => _saving = false);
  }

  void invalid(String message) => _error = message;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        const SizedBox(height: 12),
        ...fields(),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, key: const Key('entryError'), style: const TextStyle(color: _red))),
        const SizedBox(height: 16),
        ElevatedButton(
          key: const Key('entrySave'),
          style: ElevatedButton.styleFrom(backgroundColor: _green, foregroundColor: Colors.white),
          onPressed: _saving ? null : _submit,
          child: Text(_saving ? 'Saving...' : 'Save'),
        ),
      ],
    );
  }
}

Widget _numberField(TextEditingController controller, String label, Key key, {String? hint}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      key: key,
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label, hintText: hint, fillColor: const Color(0xFFF2F5F0)),
    ),
  );
}

/// Today or one of the 6 days before it (trap counts are entered night by night).
class _DayChoice extends StatelessWidget {
  const _DayChoice({required this.daysAgo, required this.onChanged});

  final int daysAgo;
  final ValueChanged<int> onChanged;

  static String label(int daysAgo) => daysAgo == 0 ? 'Today' : daysAgo == 1 ? 'Yesterday' : '$daysAgo days ago';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          const Text('Day: '),
          const SizedBox(width: 8),
          DropdownButton<int>(
            key: const Key('entryDay'),
            value: daysAgo,
            items: [for (var d = 0; d < 7; d++) DropdownMenuItem(value: d, child: Text(label(d)))],
            onChanged: (d) {
              if (d != null) onChanged(d);
            },
          ),
        ],
      ),
    );
  }
}

DateTime _day(int daysAgo) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day).subtract(Duration(days: daysAgo));
}

int? _int(TextEditingController c) => int.tryParse(c.text.trim());

// ---------------------------------------------------------------------------- trap count
class _TrapForm extends _EntryForm {
  const _TrapForm({required super.farm});

  @override
  State<_TrapForm> createState() => _TrapFormState();
}

class _TrapFormState extends _EntryFormState<_TrapForm> {
  final _trap = TextEditingController(text: 'PBW-1');
  final _moths = TextEditingController();
  int _daysAgo = 0;

  @override
  String get title => 'Pheromone-trap count';

  @override
  List<Widget> fields() => [
        const Text('Moths in one trap for one night. A new count for the same trap and night replaces the old one.', style: TextStyle(color: Colors.black54)),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(key: const Key('trapId'), controller: _trap, decoration: const InputDecoration(labelText: 'Trap', hintText: 'PBW-1', fillColor: Color(0xFFF2F5F0))),
        ),
        _DayChoice(daysAgo: _daysAgo, onChanged: (d) => setState(() => _daysAgo = d)),
        _numberField(_moths, 'Moths counted', const Key('trapMoths')),
      ];

  @override
  Future<String?> save() async {
    final moths = _int(_moths);
    final trap = _trap.text.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]{2,8}-[0-9A-Z]{1,8}$').hasMatch(trap)) {
      invalid('Enter the trap id, for example PBW-1.');
      return null;
    }
    if (moths == null || moths > 10000) {
      invalid('Enter the number of moths (0 or more).');
      return null;
    }
    await widget.farm.addTrapCount(trap: trap, night: _day(_daysAgo), moths: moths);
    return 'Trap count saved. The advice is up to date.';
  }

  @override
  void dispose() {
    _trap.dispose();
    _moths.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------- scouting count
class _ObservationForm extends _EntryForm {
  const _ObservationForm({required super.farm});

  @override
  State<_ObservationForm> createState() => _ObservationFormState();
}

class _ObservationFormState extends _EntryFormState<_ObservationForm> {
  final _count = TextEditingController();
  final _units = TextEditingController();
  late PestRule _rule = widget.farm.scoutingRules.first;
  int _daysAgo = 0;

  @override
  String get title => 'Scouting count';

  String get _unitsLabel => _rule.observation != null && _rule.observation!.endsWith('per_leaf') ? 'Leaves examined' : 'Plants examined';

  @override
  List<Widget> fields() {
    final tamil = widget.farm.tamil;
    final rules = widget.farm.scoutingRules;
    return [
      DropdownButton<String>(
        key: const Key('observationRule'),
        value: _rule.pest,
        isExpanded: true,
        items: [for (final r in rules) DropdownMenuItem(value: r.pest, child: Text(r.name(tamil), overflow: TextOverflow.ellipsis))],
        onChanged: (pest) {
          if (pest == null) return;
          setState(() => _rule = rules.firstWhere((r) => r.pest == pest));
        },
      ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Threshold ${_rule.comparison} ${_decimal(_rule.threshold)}${_rule.countsUnits ? '% of plants' : ''}'
          '${_rule.minUnits == null ? '' : '; examine at least ${_rule.minUnits}'}.',
          key: const Key('observationThreshold'),
          style: const TextStyle(color: Colors.black54),
        ),
      ),
      _DayChoice(daysAgo: _daysAgo, onChanged: (d) => setState(() => _daysAgo = d)),
      _numberField(_count, _rule.countsUnits ? 'Plants affected' : 'Insects or damaged parts counted', const Key('observationCount')),
      _numberField(_units, _unitsLabel, const Key('observationUnits'), hint: _rule.minUnits?.toString()),
    ];
  }

  @override
  Future<String?> save() async {
    final count = _int(_count);
    final units = _int(_units);
    if (count == null || units == null || units < 1) {
      invalid('Enter what you counted and how many you examined (at least 1).');
      return null;
    }
    if (_rule.countsUnits && count > units) {
      invalid('The number of plants affected cannot be more than the plants examined.');
      return null;
    }
    await widget.farm.addObservation(observation: _rule.observation!, observedOn: _day(_daysAgo), count: count, units: units);
    return 'Scouting count saved. The advice is up to date.';
  }

  @override
  void dispose() {
    _count.dispose();
    _units.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------- detection check
/// Detector classes that are pest signs (the others are boll stages).
const Map<String, String> _signClasses = {
  'mealybug_colony': 'Mealybug colony',
  'boll_bored': 'Bored boll (pink bollworm)',
  'rosette_flower': 'Rosette flower (pink bollworm)',
  'boll_defective': 'Defective boll',
};

class _ConfirmationForm extends _EntryForm {
  const _ConfirmationForm({required super.farm});

  @override
  State<_ConfirmationForm> createState() => _ConfirmationFormState();
}

class _ConfirmationFormState extends _EntryFormState<_ConfirmationForm> {
  final _row = TextEditingController();
  final _segment = TextEditingController();
  String _class = _signClasses.keys.first;
  bool _confirmed = true;
  int _daysAgo = 0;

  @override
  String get title => 'Check a detection on the plant';

  @override
  List<Widget> fields() => [
        const Text('Go to the segment, look at the plants and record whether the camera was right. This tells the rules WHERE to act; it never decides WHETHER.', style: TextStyle(color: Colors.black54)),
        const SizedBox(height: 10),
        DropdownButton<String>(
          key: const Key('confirmationClass'),
          value: _class,
          isExpanded: true,
          items: [for (final e in _signClasses.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (c) {
            if (c != null) setState(() => _class = c);
          },
        ),
        Row(children: [
          Expanded(child: _numberField(_row, 'Row', const Key('confirmationRow'))),
          const SizedBox(width: 10),
          Expanded(child: _numberField(_segment, 'Segment', const Key('confirmationSegment'))),
        ]),
        _DayChoice(daysAgo: _daysAgo, onChanged: (d) => setState(() => _daysAgo = d)),
        Wrap(spacing: 8, children: [
          ChoiceChip(key: const Key('confirmationYes'), label: const Text('Confirmed'), selected: _confirmed, onSelected: (_) => setState(() => _confirmed = true)),
          ChoiceChip(key: const Key('confirmationNo'), label: const Text('Not there (camera wrong)'), selected: !_confirmed, onSelected: (_) => setState(() => _confirmed = false)),
        ]),
      ];

  @override
  Future<String?> save() async {
    final row = _int(_row);
    final segment = _int(_segment);
    if (row == null || segment == null || row < 1 || segment < 1) {
      invalid('Enter the row and segment numbers from the row marker.');
      return null;
    }
    await widget.farm.addConfirmation(row: row, segment: segment, className: _class, confirmed: _confirmed, observedOn: _day(_daysAgo));
    return 'Check saved. The advice is up to date.';
  }

  @override
  void dispose() {
    _row.dispose();
    _segment.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------- location (owner)
class _LocationForm extends _EntryForm {
  const _LocationForm({required super.farm});

  @override
  State<_LocationForm> createState() => _LocationFormState();
}

class _LocationFormState extends _EntryFormState<_LocationForm> {
  late final _lat = TextEditingController(text: widget.farm.farm?.latitude?.toString() ?? '');
  late final _lon = TextEditingController(text: widget.farm.farm?.longitude?.toString() ?? '');

  @override
  String get title => 'Farm location';

  Widget _coordinate(TextEditingController c, String label, Key key) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          key: key,
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(labelText: label, fillColor: const Color(0xFFF2F5F0)),
        ),
      );

  @override
  List<Widget> fields() => [
        const Text('Decimal degrees, as shown by a map app (for example 11.2300 and 78.8800). Used only for the rain forecast.', style: TextStyle(color: Colors.black54)),
        const SizedBox(height: 10),
        _coordinate(_lat, 'Latitude', const Key('locationLat')),
        _coordinate(_lon, 'Longitude', const Key('locationLon')),
      ];

  @override
  Future<String?> save() async {
    final lat = double.tryParse(_lat.text.trim());
    final lon = double.tryParse(_lon.text.trim());
    if (lat == null || lon == null || lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      invalid('Enter a latitude between -90 and 90 and a longitude between -180 and 180.');
      return null;
    }
    await widget.farm.setLocation(latitude: lat, longitude: lon);
    return 'Location saved. The rain forecast arrives within the hour.';
  }

  @override
  void dispose() {
    _lat.dispose();
    _lon.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------- operator (owner)
class _OperatorForm extends _EntryForm {
  const _OperatorForm({required super.farm});

  @override
  State<_OperatorForm> createState() => _OperatorFormState();
}

class _OperatorFormState extends _EntryFormState<_OperatorForm> {
  final _phone = TextEditingController();

  @override
  String get title => 'Add an operator';

  @override
  List<Widget> fields() => [
        const Text('The person signs in with this number and can then enter trap, scouting and detection data for this farm and read its advice. They cannot see your devices or change the farm.', style: TextStyle(color: Colors.black54)),
        const SizedBox(height: 10),
        TextField(
          key: const Key('operatorPhone'),
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(labelText: 'Phone number with country code', hintText: '+91 98765 43210', fillColor: Color(0xFFF2F5F0)),
        ),
      ];

  @override
  Future<String?> save() async {
    final phone = normalizePhone(_phone.text);
    if (phone == null) {
      invalid('Enter the full phone number with the country code, for example +91 98765 43210.');
      return null;
    }
    await widget.farm.addOperator(phone);
    return 'Operator ${maskPhone(phone)} added.';
  }

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }
}
