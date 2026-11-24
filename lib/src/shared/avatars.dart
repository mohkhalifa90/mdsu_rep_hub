import 'package:flutter/material.dart';

import '../data/repo.dart';

/// Everyone's profile photo, loaded once when the app starts and kept up to date.
class Avatars extends ChangeNotifier {
  Avatars._();
  static final instance = Avatars._();

  Map<String, String> _urls = {};
  String? of(String? id) => id == null ? null : _urls[id];

  Future<void> load() async {
    try {
      _urls = await Repo.avatars();
      notifyListeners();
    } catch (_) {/* photos are a nice-to-have */}
  }

  void set(String id, String? url) {
    if (url == null) {
      _urls.remove(id);
    } else {
      _urls[id] = url;
    }
    notifyListeners();
  }
}

const _palette = [
  Color(0xFF1E88E5), Color(0xFF43A047), Color(0xFFE53935), Color(0xFF8E24AA),
  Color(0xFFFB8C00), Color(0xFF00897B), Color(0xFF3949AB), Color(0xFFD81B60),
];

String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
}

/// A round photo – or coloured initials when the person has no photo.
class UserAvatar extends StatelessWidget {
  final String? id;
  final String name;
  final double radius;
  const UserAvatar({super.key, required this.id, required this.name, this.radius = 16});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Avatars.instance,
        builder: (context, _) {
          final url = Avatars.instance.of(id);
          final color = _palette[(id ?? name).hashCode.abs() % _palette.length];
          return CircleAvatar(
            radius: radius,
            backgroundColor: color.withValues(alpha: 0.18),
            foregroundImage: url == null ? null : NetworkImage(url),
            child: Text(initialsOf(name),
                style: TextStyle(fontSize: radius * 0.8, fontWeight: FontWeight.w600, color: color)),
          );
        },
      );
}
