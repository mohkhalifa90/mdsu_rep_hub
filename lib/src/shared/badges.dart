import 'dart:async';

import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../push/push_service.dart';

/// Numbers on the tabs: new posts, meetings to answer (reps); reports to review, sign-ups (officer).
/// Refreshed on start, every minute, when a push arrives, when the app comes back and on tab changes.
class Badges extends ChangeNotifier with WidgetsBindingObserver {
  Badges._();
  static final instance = Badges._();

  Map<String, int> counts = const {};
  Timer? _timer;
  bool _started = false;

  int of(String key) => counts[key] ?? 0;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    PushService.instance.received.addListener(refresh);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => refresh());
    refresh();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    PushService.instance.received.removeListener(refresh);
    _timer?.cancel();
    counts = const {};
  }

  Future<void> refresh() async {
    final c = await Repo.badges();
    counts = c;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }
}

/// An icon with a small red number when [count] > 0
Widget badgeIcon(IconData icon, int count) =>
    Badge(isLabelVisible: count > 0, label: Text(count > 99 ? '99+' : '$count'), child: Icon(icon));
