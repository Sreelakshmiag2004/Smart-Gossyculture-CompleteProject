import 'package:flutter/material.dart';

import '../core/api/api_failure.dart';
import '../core/api/failure_messages.dart';
import '../core/app_services.dart';
import '../core/models.dart';
import '../core/validators.dart';
import 'onboarding_gate_page.dart';
import 'sign_in_page.dart';

/// Second onboarding step: attach a provisioned BollBot device to one of the farmer's farms with
/// its one-time claim code (POST /api/v1/devices/claim).
///
/// This is a registration step with the BACKEND only. The app does not contact the device, and
/// the backend decides whether the claim is valid (code, ownership, attempt limit).
class DeviceClaimPage extends StatefulWidget {
  const DeviceClaimPage({super.key, required this.farms});

  /// The farmer's farms (at least one).
  final List<Farm> farms;

  @override
  State<DeviceClaimPage> createState() => _DeviceClaimPageState();
}

class _DeviceClaimPageState extends State<DeviceClaimPage> {
  final TextEditingController _deviceIdController = TextEditingController();
  final TextEditingController _claimCodeController = TextEditingController();
  late String _farmId = widget.farms.first.id;
  bool _claiming = false;
  String? _deviceIdError;
  String? _claimCodeError;
  String? _error;

  @override
  void dispose() {
    _deviceIdController.dispose();
    _claimCodeController.dispose();
    super.dispose();
  }

  Future<void> _claim() async {
    if (_claiming) return;
    final deviceId = normalizeDeviceId(_deviceIdController.text);
    final claimCode = normalizeClaimCode(_claimCodeController.text);
    setState(() {
      _deviceIdError = deviceId == null ? 'Enter the device ID printed on the device label.' : null;
      _claimCodeError = claimCode == null ? 'Enter the claim code (6 to 32 characters).' : null;
      _error = null;
    });
    if (deviceId == null || claimCode == null) return;
    setState(() => _claiming = true);
    try {
      await AppScope.of(context).onboarding.claimDevice(deviceId: deviceId, claimCode: claimCode, farmId: _farmId);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (context) => const OnboardingGatePage()), (route) => false);
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      if (failure.kind == ApiFailureKind.sessionExpired) return; // the app shell returns to sign-in
      _claimCodeController.clear();
      setState(() {
        _claiming = false;
        _error = messageForFailure(failure, context: FailureContext.claimDevice);
      });
    }
  }

  Future<void> _logout() async {
    await AppScope.of(context).session.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (context) => const SignInPage()), (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).primaryColor;
    const labelStyle = TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Colors.black);
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.eco, color: primary, size: 32),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text('Smart Gossyculture', overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24, color: primary)),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const Text('Add your BollBot', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 28, color: Colors.black)),
              const SizedBox(height: 12),
              const Text(
                'Step 2 of 2. Enter the device ID and the one-time claim code supplied with your device.',
                style: TextStyle(fontSize: 16, color: Colors.black54),
              ),
              const SizedBox(height: 24),
              if (widget.farms.length > 1) ...[
                const Text('Farm', style: labelStyle),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: const Key('farmDropdown'),
                  initialValue: _farmId,
                  items: [for (final farm in widget.farms) DropdownMenuItem(value: farm.id, child: Text(farm.name, overflow: TextOverflow.ellipsis))],
                  onChanged: _claiming ? null : (value) => setState(() => _farmId = value ?? _farmId),
                ),
                const SizedBox(height: 16),
              ] else ...[
                Text('Farm: ${widget.farms.first.name}', key: const Key('farmName'), style: const TextStyle(fontSize: 15, color: Colors.black87)),
                const SizedBox(height: 16),
              ],
              const Text('Device ID', style: labelStyle),
              const SizedBox(height: 8),
              TextField(
                key: const Key('deviceIdField'),
                controller: _deviceIdController,
                enabled: !_claiming,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  hintText: 'Enter the device ID',
                  prefixIcon: const Icon(Icons.memory_outlined, color: Colors.black38),
                  errorText: _deviceIdError,
                  errorMaxLines: 2,
                ),
              ),
              const SizedBox(height: 16),
              const Text('Claim code', style: labelStyle),
              const SizedBox(height: 8),
              TextField(
                key: const Key('claimCodeField'),
                controller: _claimCodeController,
                enabled: !_claiming,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) => _claim(),
                decoration: InputDecoration(
                  hintText: 'Enter the claim code',
                  prefixIcon: const Icon(Icons.vpn_key_outlined, color: Colors.black38),
                  errorText: _claimCodeError,
                  errorMaxLines: 2,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  key: const Key('claimError'),
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF2F0),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFFCCC7)),
                  ),
                  child: Text(_error!, style: const TextStyle(color: Color(0xFFA8071A), fontSize: 14)),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const Key('claimButton'),
                  style: ElevatedButton.styleFrom(backgroundColor: primary, foregroundColor: Colors.white),
                  onPressed: _claiming ? null : _claim,
                  child: _claiming
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : const Text('Add device', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                ),
              ),
              const SizedBox(height: 8),
              Center(child: TextButton(onPressed: _claiming ? null : _logout, child: const Text('Log out'))),
            ],
          ),
        ),
      ),
    );
  }
}
