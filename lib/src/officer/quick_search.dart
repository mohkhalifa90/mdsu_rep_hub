import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/format.dart';
import '../shared/widgets.dart';

class _Hit {
  final IconData icon;
  final String title;
  final String sub;
  final String link; // as used by the officer shell: reps/<email>, programmes/<id>, agenda/<id>, chat/<id>
  const _Hit(this.icon, this.title, this.sub, this.link);
}

/// Ctrl+K: find a representative, programme or council, meeting or channel and go there.
Future<void> showQuickSearch(BuildContext context, {required List<Council> councils, required void Function(String) open}) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => _QuickSearch(councils: councils, open: open),
    );

class _QuickSearch extends StatefulWidget {
  final List<Council> councils;
  final void Function(String) open;
  const _QuickSearch({required this.councils, required this.open});
  @override
  State<_QuickSearch> createState() => _QuickSearchState();
}

class _QuickSearchState extends State<_QuickSearch> {
  late final Future<(List<Profile>, List<Meeting>, List<Channel>)> _f = _load();
  Future<(List<Profile>, List<Meeting>, List<Channel>)> _load() async =>
      (await Repo.profiles(), await Repo.meetings(), await Repo.channels());
  String _q = '';

  List<_Hit> _hits(List<Profile> people, List<Meeting> meetings, List<Channel> channels) {
    final q = _q.trim().toLowerCase();
    if (q.length < 2) return const [];
    bool has(String s) => s.toLowerCase().contains(q);
    final byId = {for (final c in widget.councils) c.id: c};
    return [
      for (final p in people)
        if (has(p.fullName) || has(p.email ?? '') || has(p.program ?? ''))
          _Hit(Icons.person_outline, p.fullName, [p.email ?? '', if (!p.active) 'not active'].join(' · '),
              'reps/${p.email ?? p.fullName}'),
      for (final c in widget.councils)
        if (has(c.name) || has(c.directorName ?? ''))
          _Hit(c.isProgramme ? Icons.school_outlined : Icons.account_balance_outlined, c.name,
              c.isProgramme ? 'Programme' : 'Council', 'programmes/${c.id}'),
      for (final m in meetings)
        if (has(m.title) || has(byId[m.councilId]?.name ?? ''))
          _Hit(Icons.event_note_outlined, m.title, '${fmtDateY(m.startsAt)} · ${byId[m.councilId]?.name ?? ''}',
              'agenda/${m.id}'),
      for (final ch in channels)
        if (has(ch.name)) _Hit(Icons.forum_outlined, ch.name, 'Channel', 'chat/${ch.id}'),
    ].take(30).toList();
  }

  void _go(_Hit h) {
    Navigator.pop(context);
    widget.open(h.link);
  }

  @override
  Widget build(BuildContext context) => Dialog(
        alignment: const Alignment(0, -0.6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
          child: Loader<(List<Profile>, List<Meeting>, List<Channel>)>(
            future: _f,
            builder: (context, data) {
              final (people, meetings, channels) = data;
              final hits = _hits(people, meetings, channels);
              return Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search), hintText: 'Name, email, programme, meeting or channel…'),
                    onChanged: (v) => setState(() => _q = v),
                    onSubmitted: (_) {
                      if (hits.isNotEmpty) _go(hits.first);
                    },
                  ),
                ),
                Flexible(
                  child: _q.trim().length < 2
                      ? const EmptyState('Type at least 2 letters. Enter opens the first result.', icon: Icons.search)
                      : hits.isEmpty
                          ? const EmptyState('Nothing found')
                          : ListView(shrinkWrap: true, children: [
                              for (final h in hits)
                                ListTile(
                                  leading: Icon(h.icon),
                                  title: Text(h.title),
                                  subtitle: Text(h.sub),
                                  onTap: () => _go(h),
                                ),
                            ]),
                ),
              ]);
            },
          ),
        ),
      );
}
