import 'package:flutter/material.dart';

import '../core/api/api_failure.dart';
import '../core/api/failure_messages.dart';
import '../core/app_services.dart';
import '../core/validators.dart';
import 'onboarding_gate_page.dart';
import 'sign_in_page.dart';

/// First onboarding step for a farmer who owns no farm: create one (POST /api/v1/farms).
class FarmOnboardingPage extends StatefulWidget {
  const FarmOnboardingPage({super.key});

  @override
  State<FarmOnboardingPage> createState() => _FarmOnboardingPageState();
}

class _FarmOnboardingPageState extends State<FarmOnboardingPage> {
  final TextEditingController _nameController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_saving) return;
    final name = normalizeFarmName(_nameController.text);
    if (name == null) {
      setState(() => _error = 'Enter a farm name of up to 80 characters.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await AppScope.of(context).onboarding.createFarm(name);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (context) => const OnboardingGatePage()), (route) => false);
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      if (failure.kind == ApiFailureKind.sessionExpired) return; // the app shell returns to sign-in
      setState(() {
        _saving = false;
        _error = messageForFailure(failure, context: FailureContext.createFarm);
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
              const Text('Set up your farm', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 28, color: Colors.black)),
              const SizedBox(height: 12),
              const Text(
                'Step 1 of 2. Give your farm a name. You will add your BollBot device next.',
                style: TextStyle(fontSize: 16, color: Colors.black54),
              ),
              const SizedBox(height: 32),
              const Text('Farm name', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Colors.black)),
              const SizedBox(height: 8),
              TextField(
                key: const Key('farmNameField'),
                controller: _nameController,
                enabled: !_saving,
                maxLength: 80,
                textCapitalization: TextCapitalization.words,
                onSubmitted: (_) => _create(),
                decoration: InputDecoration(
                  hintText: 'Enter your farm name',
                  prefixIcon: const Icon(Icons.location_on_outlined, color: Colors.black38),
                  errorText: _error,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const Key('createFarmButton'),
                  style: ElevatedButton.styleFrom(backgroundColor: primary, foregroundColor: Colors.white),
                  onPressed: _saving ? null : _create,
                  child: _saving
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : const Text('Continue', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                ),
              ),
              const SizedBox(height: 8),
              Center(child: TextButton(onPressed: _saving ? null : _logout, child: const Text('Log out'))),
            ],
          ),
        ),
      ),
    );
  }
}
