import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/widgets.dart';
import 'officer_shell.dart';

const _typeLabels = {
  'program': 'Program council',
  'academy': 'Academy council',
  'general': 'General council',
  'siec': 'SIEC',
};
const _academies = ['EST', 'HVV', 'IDT', 'UKK'];

/// Head of Education: add, rename and remove councils.
class CouncilsPage extends StatefulWidget {
  final OfficerData data;
  final VoidCallback onChanged;
  const CouncilsPage({super.key, required this.data, required this.onChanged});
  @override
  State<CouncilsPage> createState() => _CouncilsPageState();
}

class _CouncilsPageState extends State<CouncilsPage> {
  late Future<CouncilStats> _f = Repo.councilStats();
  void _reload() => setState(() => _f = Repo.councilStats());

  Future<void> _edit({Council? council}) async {
    final name = TextEditingController(text: council?.name ?? '');
    String type = council?.type ?? 'program';
    String? academy = council?.academy;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(council == null ? 'New council' : 'Edit council'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name (e.g. Program council – Nursing)'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final e in _typeLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setD(() => type = v ?? type),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                value: academy,
                decoration: const InputDecoration(labelText: 'Academy'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('— (whole university)')),
                  for (final a in _academies) DropdownMenuItem<String?>(value: a, child: Text(a)),
                ],
                onChanged: (v) => setD(() => academy = v),
              ),
              if (type == 'siec')
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text('SIEC councils include every representative automatically.'),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    final saved = await runAction(
      context,
      () => council == null
          ? Repo.createCouncil(name: name.text.trim(), type: type, academy: academy)
          : Repo.updateCouncil(council.id, name: name.text.trim(), type: type, academy: academy),
      success: 'Saved',
    );
    if (saved) {
      _reload();
      widget.onChanged();
    }
  }

  Future<void> _delete(Council c, int meetings, int members) async {
    final warning = meetings > 0
        ? 'This council has $meetings meeting(s). Deleting it also deletes its meetings, agenda items '
            'and follow-up issues.\n\nTip: rename it instead if it still exists under another name.'
        : 'This cannot be undone.';
    if (!await confirm(context, 'Delete “${c.name}”?', '$warning\n\n$members representative(s) will be removed from it.',
        ok: 'Delete')) {
      return;
    }
    if (await runAction(context, () => Repo.deleteCouncil(c.id), success: 'Deleted')) {
      _reload();
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) => Loader<CouncilStats>(
        future: _f,
        onRetry: _reload,
        builder: (context, st) {
          final byType = <String, List<Council>>{};
          for (final c in st.councils) {
            byType.putIfAbsent(c.type, () => []).add(c);
          }
          return ListView(padding: const EdgeInsets.all(24), children: [
            Row(children: [
              const Expanded(
                child: Text('The councils representatives sit on. Assign representatives to councils on the '
                    'Representatives page.'),
              ),
              FilledButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('New council')),
            ]),
            for (final type in _typeLabels.keys)
              if (byType[type] != null) ...[
                SectionTitle(_typeLabels[type]!),
                Card(
                  child: Column(children: [
                    for (final c in byType[type]!)
                      ListTile(
                        title: Text(c.name),
                        subtitle: Text([
                          if (c.academy != null) 'Academy ${c.academy}',
                          c.isSiec ? 'all representatives' : '${st.members[c.id] ?? 0} representative(s)',
                          '${st.meetings[c.id] ?? 0} meeting(s)',
                        ].join(' · ')),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(council: c)),
                          IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(c, st.meetings[c.id] ?? 0, st.members[c.id] ?? 0),
                          ),
                        ]),
                      ),
                  ]),
                ),
              ],
          ]);
        },
      );
}
