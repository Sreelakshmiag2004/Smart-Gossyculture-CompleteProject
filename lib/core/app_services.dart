import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';

import 'api/api_client.dart';
import 'alerts/alerts_controller.dart';
import 'alerts/alerts_repository.dart';
import 'app_config.dart';
import 'auth/auth_repository.dart';
import 'auth/session_controller.dart';
import 'auth/token_store.dart';
import 'dashboard/dashboard_controller.dart';
import 'dashboard/dashboard_repository.dart';
import 'onboarding/onboarding_repository.dart';
import 'pest/pest_history_controller.dart';
import 'pest/pest_history_repository.dart';
import 'realtime/live_connection.dart';
import 'realtime/live_socket.dart';

/// The app's services, built once at start-up and handed to the widget tree through [AppScope].
class AppServices {
  AppServices._({required this.config, required this.session, required this.auth, required this.onboarding, required this.dashboard, required this.alerts, required this.pestHistory, required this.live, required this.api});

  /// [adapter], [tokens], [clock], [liveConnector] and [random] exist for tests; the app uses
  /// the defaults.
  factory AppServices.create({required AppConfig config, TokenStore? tokens, HttpClientAdapter? adapter, DateTime Function()? clock, LiveConnector? liveConnector, Random? random}) {
    final store = tokens ?? SecureTokenStore();
    final session = SessionController();
    final api = ApiClient(config: config, tokens: store, onSessionInvalidated: session.handleInvalidated, adapter: adapter, clock: clock);
    final auth = AuthRepository(api: api, tokens: store);
    session.attach(auth);
    // The live channel of the same backend, authenticated with the same session: its token comes
    // from the HTTP client's interceptor, the only place where tokens are renewed.
    final live = LiveConnection(url: liveUrlFor(config.apiBaseUrl), accessToken: api.interceptor.accessToken, connector: liveConnector, random: random, clock: clock);
    final dashboard = DashboardController(DashboardRepository(api: api), live: live, clock: clock);
    // Alerts arrive inside the live events of the dashboard's connection; there is no second
    // connection. They are read over REST by the pages that show them.
    final alerts = AlertsController(AlertsRepository(api: api));
    // The Pest page's history follows the dashboard's selected device and receives new rows
    // from the same events of the same connection.
    final pestHistory = PestHistoryController(PestHistoryRepository(api: api), dashboard);
    dashboard
      ..onLiveEvent = (event) {
        alerts.onLiveEvent(event);
        pestHistory.onLiveEvent(event);
      }
      ..onLiveStreamFresh = () {
        alerts.onLiveStreamFresh();
        pestHistory.onLiveStreamFresh();
      };
    // Dashboard data and alerts belong to the signed-in user: forget them - and close the live
    // connection - as soon as the session ends.
    session.addListener(() {
      if (session.status == SessionStatus.signedIn) return;
      if (dashboard.phase != DashboardPhase.idle) dashboard.reset();
      alerts.reset();
      pestHistory.reset();
    });
    return AppServices._(config: config, session: session, auth: auth, onboarding: OnboardingRepository(api: api), dashboard: dashboard, alerts: alerts, pestHistory: pestHistory, live: live, api: api);
  }

  final AppConfig config;
  final SessionController session;
  final AuthRepository auth;
  final OnboardingRepository onboarding;
  final DashboardController dashboard;

  /// The caller's alerts (Notifications page, dashboard bell).
  final AlertsController alerts;

  /// Detection and spray history of the dashboard's selected device (Pest page).
  final PestHistoryController pestHistory;

  /// The live channel connection, opened and closed by [dashboard].
  final LiveConnection live;
  final ApiClient api;
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope is missing above this widget');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => !identical(services, oldWidget.services);
}
