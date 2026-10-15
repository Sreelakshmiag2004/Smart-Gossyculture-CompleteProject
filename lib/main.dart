import 'package:flutter/material.dart';
import 'core/api/failure_messages.dart';
import 'core/app_config.dart';
import 'core/app_services.dart';
import 'ui/launch_page.dart';
import 'ui/sign_in_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    runApp(MyApp(services: AppServices.create(config: AppConfig.fromEnvironment())));
  } on ConfigurationError catch (error) {
    runApp(_ConfigurationErrorApp(message: error.message));
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key, required this.services});

  final AppServices services;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // A signed-in user whose session is no longer accepted by the backend is returned to the
    // sign-in page from wherever they are. The stored tokens have already been deleted.
    widget.services.session.onForcedSignOut = _returnToSignIn;
  }

  @override
  void dispose() {
    widget.services.session.onForcedSignOut = null;
    super.dispose();
  }

  void _returnToSignIn() {
    _navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const SignInPage(notice: sessionExpiredMessage)),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: widget.services,
      child: _buildApp(),
    );
  }

  Widget _buildApp() {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Smart Gossy Culture App',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5FA62C),
          primary: const Color(0xFF5FA62C),
          secondary: const Color(0xFF00B2FF),
          surface: const Color(0xFFF6FBF4),
        ),
        scaffoldBackgroundColor: const Color(0xFFF6FBF4),
        fontFamily: 'Roboto', 
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none, 
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF5FA62C), width: 2),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        ),
      ),
      home: const LaunchPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// Shown instead of the app when the build has no usable server address.
class _ConfigurationErrorApp extends StatelessWidget {
  const _ConfigurationErrorApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('This app is not configured correctly.\n$message', textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}