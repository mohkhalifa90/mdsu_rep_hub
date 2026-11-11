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

  bool get enabled => _isPhone && _options != null;

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
  Future<void> register() async {
    if (!_initialized) return;
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
    await Repo.saveDeviceToken(token, defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');
  }

  void _open(dynamic link) {
    if (link is String && link.isNotEmpty) onOpenLink?.call(link);
  }
}
