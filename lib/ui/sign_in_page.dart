import 'package:flutter/material.dart';
import '../core/api/api_failure.dart';
import '../core/api/failure_messages.dart';
import '../core/app_services.dart';
import '../core/validators.dart';
import 'otp_verify_page.dart';

class SignInPage extends StatefulWidget {
  const SignInPage({super.key, this.notice});

  /// Shown above the form, e.g. after the session has ended.
  final String? notice;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  bool isPhoneSelected = true;
  final TextEditingController phoneController = TextEditingController();
  bool _requesting = false;
  String? _error;

  @override
  void dispose() {
    phoneController.dispose();
    super.dispose();
  }

  /// Asks the backend to issue a sign-in code for the entered number, then opens code entry.
  Future<void> _continue() async {
    if (_requesting) return;
    if (!isPhoneSelected) {
      setState(() => _error = 'Sign-in with email is not available. Please use your phone number.');
      return;
    }
    final phone = normalizePhone(phoneController.text);
    if (phone == null) {
      setState(() => _error = 'Enter your full phone number with the country code, for example +91 98765 43210.');
      return;
    }
    setState(() {
      _requesting = true;
      _error = null;
    });
    try {
      await AppScope.of(context).session.requestCode(phone);
      if (!mounted) return;
      setState(() => _requesting = false);
      Navigator.of(context).push(MaterialPageRoute(builder: (context) => OtpVerifyPage(phone: phone)));
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _requesting = false;
        _error = messageForFailure(failure, context: FailureContext.requestCode);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Icon(Icons.eco, color: Theme.of(context).primaryColor, size: 32),
                    const SizedBox(width: 8),
                    Text(
                      'Smart Gossyculture',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 28,
                        color: Theme.of(context).primaryColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                const Text(
                  'Sign In or Sign Up',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 28,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Manage your cotton farm with ease.',
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.black54,
                  ),
                ),
                const SizedBox(height: 32),
                if (widget.notice != null) ...[
                  Container(
                    key: const Key('signInNotice'),
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF7E6),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFFD591)),
                    ),
                    child: Text(widget.notice!, style: const TextStyle(color: Color(0xFF874D00), fontSize: 14)),
                  ),
                  const SizedBox(height: 16),
                ],
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F5F5),
                    borderRadius: BorderRadius.circular(32),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              isPhoneSelected = true;
                              _error = null;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            decoration: BoxDecoration(
                              color: isPhoneSelected
                                  ? Theme.of(context).primaryColor
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(32),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.phone,
                                    color: isPhoneSelected
                                        ? Colors.white
                                        : Colors.black54),
                                const SizedBox(width: 6),
                                Text(
                                  'Phone Number',
                                  style: TextStyle(
                                    color: isPhoneSelected
                                        ? Colors.white
                                        : Colors.black54,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14, // Adjusted font size
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              isPhoneSelected = false;
                              _error = null;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            decoration: BoxDecoration(
                              color: !isPhoneSelected
                                  ? Theme.of(context).primaryColor
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(32),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.email,
                                    color: !isPhoneSelected
                                        ? Colors.white
                                        : Colors.black54),
                                const SizedBox(width: 6),
                                Text(
                                  'Email',
                                  style: TextStyle(
                                    color: !isPhoneSelected
                                        ? Colors.white
                                        : Colors.black54,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14, // Adjusted font size
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  isPhoneSelected ? 'Phone Number' : 'Email',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('phoneField'),
                  controller: phoneController,
                  enabled: !_requesting,
                  keyboardType: isPhoneSelected
                      ? TextInputType.phone
                      : TextInputType.emailAddress,
                  onSubmitted: (_) => _continue(),
                  decoration: InputDecoration(
                    hintText: isPhoneSelected
                        ? 'Phone number with country code'
                        : 'Enter your email address',
                    errorText: _error,
                    errorMaxLines: 3,
                    prefixIcon: Icon(
                      isPhoneSelected ? Icons.phone : Icons.email,
                      color: Colors.black38,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Colors.white,
                    ),
                    key: const Key('continueButton'),
                    onPressed: _requesting ? null : _continue,
                    child: _requesting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          )
                        : const Text(
                            'Continue',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Divider(color: Colors.black12, thickness: 1),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        'Or continue with',
                        style: TextStyle(
                          color: Colors.black38,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Divider(color: Colors.black12, thickness: 1),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: Color(0xFFE5E5E5)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.language, color: Colors.black),
                    label: const Text(
                      'Sign in with Google',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    onPressed: () {},
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: const Color(0xFF1877F3),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.facebook, color: Colors.white),
                    label: const Text(
                      'Sign in with Facebook',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    onPressed: () {},
                  ),
                ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: const TextStyle(
                        color: Colors.black38,
                        fontSize: 13,
                      ),
                      children: [
                        const TextSpan(text: 'By continuing, you agree to BollBot\'s '),
                        TextSpan(
                          text: 'Terms of Service',
                          style: TextStyle(
                            color: Theme.of(context).primaryColor,
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                        const TextSpan(text: ' and '),
                        TextSpan(
                          text: 'Privacy Policy.',
                          style: TextStyle(
                            color: Theme.of(context).primaryColor,
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}