import 'package:flutter/material.dart';
import '../core/api/failure_messages.dart';
import '../core/app_services.dart';
import '../core/auth/session_controller.dart';
import 'onboarding_gate_page.dart';
import 'sign_in_page.dart';

class LaunchPage extends StatefulWidget {
  const LaunchPage({super.key});

  @override
  State<LaunchPage> createState() => _LaunchPageState();
}

class _LaunchPageState extends State<LaunchPage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;
  bool _started = false;
  bool _unreachable = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _start();
    }
  }

  /// Shows the splash for 3 seconds while looking for a stored session, then continues:
  /// no session -> sign-in; accepted session -> onboarding check / dashboard;
  /// rejected session -> sign-in with a notice; backend unreachable -> retry here.
  Future<void> _start() async {
    final session = AppScope.of(context).session;
    final results = await Future.wait<Object?>([
      session.restore(),
      Future<void>.delayed(const Duration(seconds: 3)),
    ]);
    if (!mounted) return;
    _continueWith(results.first as SessionRestore);
  }

  Future<void> _retry() async {
    setState(() => _unreachable = false);
    final result = await AppScope.of(context).session.restore();
    if (!mounted) return;
    _continueWith(result);
  }

  void _continueWith(SessionRestore result) {
    switch (result) {
      case SessionRestore.none:
        _goTo(const SignInPage());
      case SessionRestore.expired:
        _goTo(const SignInPage(notice: sessionExpiredMessage));
      case SessionRestore.restored:
        _goTo(const OnboardingGatePage());
      case SessionRestore.unreachable:
        setState(() => _unreachable = true);
    }
  }

  void _goTo(Widget page) {
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 800),
        pageBuilder: (_, __, ___) => page,
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    
    // Initialize animation controller
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );
     _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            // Professional Green Gradient: Fresh growth to deep maturity
            colors: [Color(0xFF5FA62C), Color(0xFF3E7B1A)], 
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Stack(
          children: [
            // Background Pattern 1 (Top Right)
             Positioned(
              top: -50,
              right: -50,
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.05),
                ),
              ),
            ),
            // Background Pattern 2 (Bottom Left)
             Positioned(
              bottom: -30,
              left: -30,
              child: Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.05),
                ),
              ),
            ),
            
            // Main Content
            Center(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: ScaleTransition(
                  scale: _scaleAnimation,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Logo with elegant shadow
                      Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle, 
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 30,
                              offset: const Offset(0, 15),
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/logo.png',
                          width: 140, 
                          height: 140,
                        ),
                      ),
                      const SizedBox(height: 40),
                      
                      // App Name
                      const Text(
                        'Smart Gossy Culture',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 32, 
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                          fontFamily: 'Roboto', 
                          shadows: [
                            Shadow(
                              offset: Offset(0, 2),
                              blurRadius: 4.0,
                              color: Color.fromARGB(64, 0, 0, 0),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      
                      // Tagline in Pill
                       Container(
                         padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                         decoration: BoxDecoration(
                           color: Colors.white.withOpacity(0.15),
                           borderRadius: BorderRadius.circular(30),
                           border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
                         ),
                        child: const Text(
                          'Intelligent Cotton Farming',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            
            // Bottom Footer
            Positioned(
              bottom: 50,
              left: 0,
              right: 0,
              child: Center(
                child: Column(
                  children: [
                    if (_unreachable) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          'Cannot reach the server. Check your internet connection.',
                          key: Key('launchUnreachable'),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        key: const Key('launchRetry'),
                        onPressed: _retry,
                        child: const Text('Try again', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ] else
                      const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          strokeWidth: 2.5,
                        ),
                      ),
                    const SizedBox(height: 24),
                    Text(
                      'Powered by BollBot AI',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.8),
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
