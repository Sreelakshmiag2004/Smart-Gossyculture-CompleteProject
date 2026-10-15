import 'package:flutter/material.dart';

import '../core/api/api_failure.dart';
import '../core/api/failure_messages.dart';
import '../core/app_services.dart';
import '../core/onboarding/onboarding_repository.dart';
import 'dashboard.dart';
import 'device_claim_page.dart';
import 'farm_onboarding_page.dart';
import 'sign_in_page.dart';

/// Decides where a signed-in farmer goes next, from what the backend reports:
///
///   no farm                 -> farm onboarding
///   farm, no active device  -> device claim
///   farm and device         -> dashboard
///
/// Shown after sign-in, after each onboarding step and when a stored session is restored.
class OnboardingGatePage extends StatefulWidget {
  const OnboardingGatePage({super.key});

  @override
  State<OnboardingGatePage> createState() => _OnboardingGatePageState();
}

class _OnboardingGatePageState extends State<OnboardingGatePage> {
  String? _error;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _resolve(initial: true);
    }
  }

  Future<void> _resolve({bool initial = false}) async {
    if (!initial) setState(() => _error = null);
    try {
      final state = await AppScope.of(context).onboarding.currentState();
      if (!mounted) return;
      final Widget next = switch (state) {
        NeedsFarm() => const FarmOnboardingPage(),
        NeedsDevice(farms: final farms) => DeviceClaimPage(farms: farms),
        OnboardingComplete() => const Dashboard(),
      };
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (context) => next), (route) => false);
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      // An ended session is handled by the app shell (return to sign-in).
      if (failure.kind == ApiFailureKind.sessionExpired) return;
      setState(() => _error = messageForFailure(failure));
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
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _error == null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: primary),
                      const SizedBox(height: 20),
                      const Text('Getting your farm ready...', style: TextStyle(fontSize: 16, color: Colors.black54)),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_rounded, size: 48, color: Colors.black38),
                      const SizedBox(height: 16),
                      Text(_error!, key: const Key('gateError'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.black87)),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          key: const Key('gateRetry'),
                          style: ElevatedButton.styleFrom(backgroundColor: primary, foregroundColor: Colors.white),
                          onPressed: () => _resolve(),
                          child: const Text('Try again', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(onPressed: _logout, child: const Text('Log out')),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
