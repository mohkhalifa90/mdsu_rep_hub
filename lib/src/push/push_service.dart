import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../data/repo.dart';

// Firebase settings, passed at build time (see README → "Phone notifications").
// If they are empty, the app still works; notifications are then only shown inside the app.
const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
const _androidAppId = String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
const _iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
const _iosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');
// Web version (iPhone "Add to Home Screen" app, desktop browsers)
const _webAppId = String.fromEnvironment('FIREBASE_WEB_APP_ID');
const _vapidKey = String.fromEnvironment('FIREBASE_VAPID_KEY');

/// State of notifications in the web version.
enum WebPushState {
  /// Firebase for the web is not set up, or this is not the web version
  off,

  /// The browser cannot get notifications here (on iPhone: not opened from the Home Screen)
  unsupported,

  /// Supported, the user has not been asked yet
  ask,

  /// The user said no (can only be changed in the phone/browser settings)
  blocked,

  /// Notifications are on for this device
  on,
}

/// Phone notifications (Android & iPhone) through Firebase Cloud Messaging.
class PushService {
  PushService._();
  static final instance = PushService._();

  bool _initialized = false;
  String? _token;
  void Function(String link)? onOpenLink;

  bool get _isPhone =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  FirebaseOptions? get _options {
    if (_apiKey.isEmpty || _projectId.isEmpty || _senderId.isEmpty) return null;
    if (kIsWeb) {
      if (_webAppId.isEmpty || _vapidKey.isEmpty) return null;
      return const FirebaseOptions(
          apiKey: _apiKey,
          appId: _webAppId,
          messagingSenderId: _senderId,
          projectId: _projectId,
          authDomain: '$_projectId.firebaseapp.com');
    }
    if (defaultTargetPlatform == TargetPlatform.android && _androidAppId.isNotEmpty) {
      return const FirebaseOptions(
          apiKey: _apiKey, appId: _androidAppId, messagingSenderId: _senderId, projectId: _projectId);
    }
    if (defaultTargetPlatform == TargetPlatform.iOS && _iosAppId.isNotEmpty) {
      return const FirebaseOptions(
          apiKey: _apiKey,
          appId: _iosAppId,
          messagingSenderId: _senderId,
          projectId: _projectId,
          iosBundleId: _iosBundleId);
    }
    return null;
  }

  bool get enabled => (_isPhone || kIsWeb) && _options != null;

  /// Call once at start-up.
  Future<void> init() async {
    if (!enabled || _initialized) return;
    try {
      await Firebase.initializeApp(options: _options);
      _initialized = true;
      // Tapping a notification while the app was in the background
      FirebaseMessaging.onMessageOpenedApp.listen((m) => _open(m.data['link']));
    } catch (e) {
      debugPrint('Push disabled: $e');
    }
  }

  /// Call after the user has signed in: asks permission and saves this phone's token.
  /// In the web version nothing is asked here (iPhone only allows it after a tap):
  /// if notifications are already allowed the token is saved, otherwise the app shows
  /// a "Turn on notifications" card that calls [enableWeb].
  Future<void> register() async {
    if (!_initialized) return;
    if (kIsWeb) {
      if (await webState() == WebPushState.on) await _saveWebToken();
      return;
    }
    try {
      final fm = FirebaseMessaging.instance;
      final settings = await fm.requestPermission(alert: true, badge: true, sound: true);
      if (settings.authorizationStatus == AuthorizationStatus.denied) return;
      await fm.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);

      final token = await fm.getToken();
      if (token != null) await _save(token);
      fm.onTokenRefresh.listen(_save);

      // App was opened from a notification while closed
      final initial = await fm.getInitialMessage();
      if (initial != null) _open(initial.data['link']);
    } catch (e) {
      debugPrint('Push registration failed: $e');
    }
  }

  /// Web version: can this device get notifications, and are they on?
  Future<WebPushState> webState() async {
    if (!kIsWeb || !_initialized) return WebPushState.off;
    try {
      final fm = FirebaseMessaging.instance;
      if (!await fm.isSupported()) return WebPushState.unsupported;
      final s = await fm.getNotificationSettings();
      return switch (s.authorizationStatus) {
        AuthorizationStatus.authorized || AuthorizationStatus.provisional => WebPushState.on,
        AuthorizationStatus.denied => WebPushState.blocked,
        _ => WebPushState.ask,
      };
    } catch (e) {
      debugPrint('Web push state: $e');
      return WebPushState.unsupported;
    }
  }

  /// Web version: ask permission (must be called from a button tap) and save the token.
  Future<WebPushState> enableWeb() async {
    if (!kIsWeb || !_initialized) return WebPushState.off;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
      if (settings.authorizationStatus == AuthorizationStatus.denied) return WebPushState.blocked;
      if (settings.authorizationStatus == AuthorizationStatus.notDetermined) return WebPushState.ask;
      await _saveWebToken();
      return WebPushState.on;
    } catch (e) {
      debugPrint('Web push enable failed: $e');
      rethrow;
    }
  }

  Future<void> _saveWebToken() async {
    try {
      final fm = FirebaseMessaging.instance;
      final token = await fm.getToken(vapidKey: _vapidKey);
      if (token != null) await _save(token);
      fm.onTokenRefresh.listen(_save);
    } catch (e) {
      debugPrint('Web push token failed: $e');
    }
  }

  /// Call before signing out so this phone stops receiving the user's notifications.
  Future<void> unregister() async {
    final t = _token;
    _token = null;
    if (t == null) return;
    try {
      await Repo.deleteDeviceToken(t);
    } catch (_) {}
  }

  Future<void> _save(String token) async {
    _token = token;
    await Repo.saveDeviceToken(
        token, kIsWeb ? 'web' : (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android'));
  }

  void _open(dynamic link) {
    if (link is String && link.isNotEmpty) onOpenLink?.call(link);
  }
}
