import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/format.dart';
import '../shared/widgets.dart';
import 'rep_shell.dart';

/// Reps send agenda topics before each meeting; the officer gets them combined.
class RepAgendaPage extends StatefulWidget {
  final RepData data;
  final String? openMeetingId;
  const RepAgendaPage({super.key, required this.data, this.openMeetingId});
  @override
  State<RepAgendaPage> createState() => _RepAgendaPageState();
}

class _RepAgendaPageState extends State<RepAgendaPage> {
  late Future<(List<Meeting>, List<AgendaItem>)> _f = _load();
  String? _open;

  @override
  void initState() {
    super.initState();
    _open = widget.openMeetingId;
  }

  Future<(List<Meeting>, List<AgendaItem>)> _load() async =>
      ((await Repo.meetings()).where((m) => !m.isPast).toList(), await Repo.agendaItems());

  @override
  Widget build(BuildContext context) {
    return Loader<(List<Meeting>, List<AgendaItem>)>(
      future: _f,
      onRetry: () => setState(() => _f = _load()),
      builder: (context, data) {
        final (meetings, items) = data;
        final open = meetings.where((m) => m.id == _open).toList();
        if (open.isNotEmpty) {
          return _MeetingInput(
            meeting: open.first,
            data: widget.data,
            myItems: items.where((a) => a.meetingId == open.first.id).toList(),
            onBack: () => setState(() => _open = null),
            onChanged: () => setState(() => _f = _load()),
          );
        }
        if (meetings.isEmpty) return const EmptyState('No upcoming meetings in your councils');
        return ListView(padding: const EdgeInsets.all(16), children: [
          Text('Send topics before each meeting. Ask your classmates as early as you can.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final m in meetings)
            Card(
              child: ListTile(
                title: Text(m.title),
                subtitle: Text('${fmtDateTime(m.startsAt)} · send by ${fmtDate(m.inputDeadline)}\n'
                    '${widget.data.council(m.councilId)?.name ?? ''}'),
                isThreeLine: true,
                trailing: Builder(builder: (_) {
                  final n = items.where((a) => a.meetingId == m.id).length;
                  return n > 0 ? StatusChip('$n sent', Colors.green.shade700) : StatusChip('Add input', Colors.orange.shade800);
                }),
                onTap: () => setState(() => _open = m.id),
              ),
            ),
        ]);
      },
    );
  }
}

class _MeetingInput extends StatefulWidget {
  final Meeting meeting;
  final RepData data;
  final List<AgendaItem> myItems;
  final VoidCallback onBack;
  final VoidCallback onChanged;
  const _MeetingInput(
      {required this.meeting, required this.data, required this.myItems, required this.onBack, required this.onChanged});
  @override
  State<_MeetingInput> createState() => _MeetingInputState();
}

class _MeetingInputState extends State<_MeetingInput> {
  final _title = TextEditingController();
  final _details = TextEditingController();
  final _count = TextEditingController(text: '5');
  String _source = agendaSources.first;
  late final Future<List<OpenIssue>> _issues = Repo.openIssuesForMeeting(widget.meeting.id);

  Future<void> _send() async {
    if (_title.text.trim().isEmpty) return showSnack(context, 'Write a topic first');
    final ok = await runAction(
      context,
      () => Repo.addAgendaItem(
        meetingId: widget.meeting.id,
        title: _title.text.trim(),
        details: _details.text.trim(),
        source: _source,
        studentCount: int.tryParse(_count.text) ?? 1,
      ),
      success: 'Sent to the Head of Education ✓',
    );
    if (ok) {
      _title.clear();
      _details.clear();
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.meeting;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(onPressed: widget.onBack, icon: const Icon(Icons.arrow_back), label: const Text('Back')),
      ),
      Text(m.title, style: Theme.of(context).textTheme.titleLarge),
      Text('${fmtDateTime(m.startsAt)} · input closes ${fmtDate(m.inputDeadline)}'),
      FutureBuilder<List<OpenIssue>>(
        future: _issues,
        builder: (context, s) {
          final list = s.data ?? const <OpenIssue>[];
          if (list.isEmpty) return const SizedBox.shrink();
          return Card(
            margin: const EdgeInsets.only(top: 12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Already on the agenda (follow-ups)', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final i in list) Text('• ${i.title}'),
              ]),
            ),
          );
        },
      ),
      const SizedBox(height: 12),
      TextField(controller: _title, decoration: const InputDecoration(labelText: 'Topic')),
      const SizedBox(height: 10),
      TextField(
          controller: _details,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'What do students say? What do you want?')),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            value: _source,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Source'),
            items: [for (final s in agendaSources) DropdownMenuItem(value: s, child: Text(s))],
            onChanged: (v) => setState(() => _source = v ?? _source),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 110,
          child: TextField(
              controller: _count,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '# students')),
        ),
      ]),
      const SizedBox(height: 12),
      FilledButton(onPressed: _send, child: const Text('Send to Head of Education')),
      const SectionTitle('My items for this meeting'),
      if (widget.myItems.isEmpty) const EmptyState('Nothing sent yet'),
      for (final a in widget.myItems)
        Card(
          child: ListTile(
            title: Text(a.title),
            subtitle: Text(a.details),
            trailing: a.status == 'new'
                ? IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (await runAction(context, () => Repo.deleteAgendaItem(a.id))) widget.onChanged();
                    })
                : StatusChip.agenda(a.status),
          ),
        ),
    ]);
  }
}
