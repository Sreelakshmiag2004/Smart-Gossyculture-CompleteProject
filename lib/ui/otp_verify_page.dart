import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api/api_failure.dart';
import '../core/api/failure_messages.dart';
import '../core/app_services.dart';
import '../core/validators.dart';
import 'onboarding_gate_page.dart';

/// Second sign-in step: the 6-digit code for [phone]. The code is typed by the user and sent to
/// the backend for verification; the app holds no code of its own.
class OtpVerifyPage extends StatefulWidget {
  const OtpVerifyPage({super.key, required this.phone});

  /// E.164 number the code was requested for.
  final String phone;

  @override
  State<OtpVerifyPage> createState() => _OtpVerifyPageState();
}

class _OtpVerifyPageState extends State<OtpVerifyPage> {
  final TextEditingController _codeController = TextEditingController();
  bool _verifying = false;
  bool _resending = false;
  String? _error;
  String? _info;

  bool get _busy => _verifying || _resending;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (_busy) return;
    final code = _codeController.text.trim();
    if (!isValidOtpCode(code)) {
      setState(() {
        _error = 'Enter the 6-digit code.';
        _info = null;
      });
      return;
    }
    setState(() {
      _verifying = true;
      _error = null;
      _info = null;
    });
    try {
      await AppScope.of(context).session.verifyCode(widget.phone, code);
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (context) => const OnboardingGatePage()), (route) => false);
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      _codeController.clear();
      setState(() {
        _verifying = false;
        _error = messageForFailure(failure, context: FailureContext.verifyCode);
      });
    }
  }

  Future<void> _resend() async {
    if (_busy) return;
    setState(() {
      _resending = true;
      _error = null;
      _info = null;
    });
    try {
      await AppScope.of(context).session.requestCode(widget.phone);
      if (!mounted) return;
      _codeController.clear();
      setState(() {
        _resending = false;
        _info = 'A new code has been requested. Any earlier code no longer works.';
      });
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _resending = false;
        _error = messageForFailure(failure, context: FailureContext.requestCode);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).primaryColor;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter your code',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 28, color: Colors.black),
              ),
              const SizedBox(height: 12),
              Text(
                'Enter the 6-digit sign-in code for ${maskPhone(widget.phone)}.',
                style: const TextStyle(fontSize: 16, color: Colors.black54),
              ),
              const SizedBox(height: 32),
              const Text(
                'Sign-in code',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Colors.black),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('codeField'),
                controller: _codeController,
                enabled: !_busy,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                style: const TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.w600),
                onSubmitted: (_) => _verify(),
                decoration: InputDecoration(
                  hintText: '••••••',
                  prefixIcon: const Icon(Icons.lock_outline, color: Colors.black38),
                  errorText: _error,
                  errorMaxLines: 3,
                ),
              ),
              if (_info != null) ...[
                const SizedBox(height: 12),
                Text(_info!, key: const Key('codeInfo'), style: TextStyle(color: primary, fontSize: 14)),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const Key('verifyButton'),
                  style: ElevatedButton.styleFrom(backgroundColor: primary, foregroundColor: Colors.white),
                  onPressed: _busy ? null : _verify,
                  child: _verifying
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : const Text('Verify', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                children: [
                  TextButton(
                    key: const Key('resendButton'),
                    onPressed: _busy ? null : _resend,
                    child: Text(_resending ? 'Requesting...' : 'Request a new code'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Change number'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
