import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/format.dart';
import '../shared/widgets.dart';
import 'agenda_docx.dart';
import 'officer_shell.dart';

/// Collects reps' agenda items per meeting + open follow-ups (auto carry-forward).
class AgendaBuilderPage extends StatefulWidget {
  final OfficerData data;
  const AgendaBuilderPage({super.key, required this.data});
  @override
  State<AgendaBuilderPage> createState() => _AgendaBuilderPageState();
}

class _AgendaBuilderPageState extends State<AgendaBuilderPage> {
  late Future<(List<Meeting>, Map<String, String>)> _f = _load();
  String? _sel;
  int _v = 0;

  Future<(List<Meeting>, Map<String, String>)> _load() async =>
      ((await Repo.meetings()).where((m) => !m.isPast).toList(), await Repo.memberNames());

  void _reload() => setState(() {
        _f = _load();
        _v++;
      });

  Future<void> _addMeeting() async {
    final d = widget.data;
    String council = d.councils.first.id;
    final title = TextEditingController(), loc = TextEditingController(text: 'Teams');
    DateTime date = DateTime.now().add(const Duration(days: 21));
    TimeOfDay time = const TimeOfDay(hour: 13, minute: 15);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Add meeting'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: council,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Council'),
                items: [for (final c in d.councils) DropdownMenuItem(value: c.id, child: Text(c.name))],
                onChanged: (v) => setD(() => council = v ?? council),
              ),
              const SizedBox(height: 10),
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Title (e.g. Program council CS #3)')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.event),
                    label: Text(fmtDateY(date)),
                    onPressed: () async {
                      final p = await showDatePicker(
                          context: ctx,
                          initialDate: date,
                          firstDate: DateTime.now().subtract(const Duration(days: 365)),
                          lastDate: DateTime.now().add(const Duration(days: 730)));
                      if (p != null) setD(() => date = p);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () async {
                    final p = await showTimePicker(context: ctx, initialTime: time);
                    if (p != null) setD(() => time = p);
                  },
                  child: Text(time.format(ctx)),
                ),
              ]),
              const SizedBox(height: 10),
              TextField(controller: loc, decoration: const InputDecoration(labelText: 'Location')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final startsAt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    final name = title.text.trim().isEmpty ? (d.council(council)?.name ?? 'Meeting') : title.text.trim();
    if (await runAction(context,
        () => Repo.createMeeting(councilId: council, title: name, startsAt: startsAt, location: loc.text.trim()),
        success: 'Meeting added')) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Loader<(List<Meeting>, Map<String, String>)>(
      future: _f,
      onRetry: _reload,
      builder: (context, data) {
        final (meetings, names) = data;
        final sel = meetings.where((m) => m.id == _sel).toList();
        final m = sel.isNotEmpty ? sel.first : (meetings.isEmpty ? null : meetings.first);
        return ListView(padding: const EdgeInsets.all(24), children: [
          Row(children: [
            const Expanded(
              child: Text('Reps send items from the app. Unanswered issues from earlier meetings are added '
                  'automatically, so nothing is forgotten.'),
            ),
            FilledButton.icon(onPressed: _addMeeting, icon: const Icon(Icons.add), label: const Text('Add meeting')),
          ]),
          const SizedBox(height: 12),
          if (m == null)
            const EmptyState('No upcoming meetings')
          else ...[
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final x in meetings)
                ChoiceChip(
                  label: Text('${x.title} · ${fmtDate(x.startsAt)}'),
                  selected: x.id == m.id,
                  onSelected: (_) => setState(() => _sel = x.id),
                ),
            ]),
            const SizedBox(height: 12),
            _MeetingAgenda(key: ValueKey('${m.id}$_v'), meeting: m, data: widget.data, names: names, onChanged: _reload),
          ],
        ]);
      },
    );
  }
}

class _MeetingAgenda extends StatefulWidget {
  final Meeting meeting;
  final OfficerData data;
  final Map<String, String> names;
  final VoidCallback onChanged;
  const _MeetingAgenda(
      {super.key, required this.meeting, required this.data, required this.names, required this.onChanged});
  @override
  State<_MeetingAgenda> createState() => _MeetingAgendaState();
}

class _MeetingAgendaState extends State<_MeetingAgenda> {
  late Future<(List<OpenIssue>, List<AgendaItem>)> _f = _load();
  Future<(List<OpenIssue>, List<AgendaItem>)> _load() async =>
      (await Repo.openIssuesForMeeting(widget.meeting.id), await Repo.agendaItems(meetingId: widget.meeting.id));

  String _agendaText(List<OpenIssue> fol, List<AgendaItem> items) {
    final m = widget.meeting;
    final b = StringBuffer()
      ..writeln('AGENDA – ${m.title}')
      ..writeln(widget.data.council(m.councilId)?.name ?? '')
      ..writeln('${fmtDateTime(m.startsAt)} · ${m.location ?? ''}')
      ..writeln()
      ..writeln('1. Opening')
      ..writeln('2. Follow-up from previous meetings (response required)');
    if (fol.isEmpty) b.writeln('   – none');
    for (var i = 0; i < fol.length; i++) {
      b.writeln('   2.${i + 1} ${fol[i].title}${fol[i].responsible == null ? '' : ' – responsible: ${fol[i].responsible}'}');
    }
    b.writeln("3. Student representatives' items");
    final inc = items.where((a) => a.status != 'declined').toList();
    if (inc.isEmpty) b.writeln('   – none');
    for (var i = 0; i < inc.length; i++) {
      b.writeln('   3.${i + 1} ${inc[i].title} (${widget.names[inc[i].userId] ?? ''}, ${inc[i].studentCount} students)');
    }
    b
      ..writeln('4. Other matters')
      ..writeln('5. Next meeting');
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.meeting;
    return Loader<(List<OpenIssue>, List<AgendaItem>)>(
      future: _f,
      onRetry: () => setState(() => _f = _load()),
      builder: (context, data) {
        final (fol, items) = data;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Card(
            child: ListTile(
              title: Text('${m.title} · ${widget.data.council(m.councilId)?.name ?? ''}'),
              subtitle: Text('${fmtDateTime(m.startsAt)} · ${m.location ?? ''} · input closes ${fmtDate(m.inputDeadline)}'),
              trailing: Wrap(spacing: 8, children: [
                if (m.inputRequested)
                  StatusChip('Input requested ✓', Colors.green.shade700)
                else
                  FilledButton.tonal(
                    onPressed: () async {
                      try {
                        final n = await Repo.requestAgendaInput(m.id);
                        if (context.mounted) showSnack(context, 'Request sent to $n reps');
                        widget.onChanged();
                      } catch (e) {
                        if (context.mounted) showSnack(context, errorText(e));
                      }
                    },
                    child: const Text('Ask reps for input'),
                  ),
                FilledButton.icon(
                  icon: const Icon(Icons.download),
                  label: const Text('Agenda (Word)'),
                  onPressed: () async {
                    try {
                      final where = await exportAgendaDocx(
                        meeting: m,
                        council: widget.data.council(m.councilId),
                        followUps: fol,
                        items: items,
                        names: widget.names,
                        nextMeeting: await nextMeetingAfter(m),
                      );
                      if (where != null && context.mounted) showSnack(context, 'Saved: $where');
                    } catch (e) {
                      if (context.mounted) showSnack(context, errorText(e));
                    }
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.description_outlined),
                  label: const Text('Copy text'),
                  onPressed: () async {
                    final text = _agendaText(fol, items);
                    await Clipboard.setData(ClipboardData(text: text));
                    if (!context.mounted) return;
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Agenda (copied to clipboard)'),
                        content: SizedBox(width: 560, child: SelectableText(text)),
                        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
                      ),
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Delete meeting',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    if (await confirm(context, 'Delete meeting?', m.title, ok: 'Delete') &&
                        await runAction(context, () => Repo.deleteMeeting(m.id))) {
                      widget.onChanged();
                    }
                  },
                ),
              ]),
            ),
          ),
          const SectionTitle('1 · Follow-up from previous meetings (added automatically)'),
          if (fol.isEmpty) const EmptyState('No open follow-ups for this council'),
          for (final i in fol)
            Card(
              child: ListTile(
                title: Text(i.title),
                subtitle: Text('Raised by ${i.raisedByName ?? ''} · responsible: ${i.responsible ?? '—'}\n'
                    'The university must give a written or verbal answer at this meeting.'),
                isThreeLine: true,
                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  StatusChip.issue(i.status),
                  if (i.meetingsWithoutAnswer > 0)
                    Text('${i.meetingsWithoutAnswer} meeting(s) w/o answer',
                        style: const TextStyle(color: Colors.red, fontSize: 12)),
                ]),
              ),
            ),
          const SectionTitle('2 · Items from student representatives'),
          if (items.isEmpty) const EmptyState('No items yet'),
          for (final a in items)
            Card(
              child: ListTile(
                title: Row(children: [Flexible(child: Text(a.title)), const SizedBox(width: 8), StatusChip.agenda(a.status)]),
                subtitle: Text('${a.details}\n${widget.names[a.userId] ?? ''} · ${a.source} · ${a.studentCount} students'),
                isThreeLine: true,
                trailing: Wrap(spacing: 6, children: [
                  if (a.status != 'included')
                    FilledButton(
                        onPressed: () async {
                          if (await runAction(context, () => Repo.setAgendaStatus(a.id, 'included'))) {
                            setState(() => _f = _load());
                          }
                        },
                        child: const Text('Include')),
                  if (a.status != 'declined')
                    OutlinedButton(
                        onPressed: () async {
                          if (await runAction(context, () => Repo.setAgendaStatus(a.id, 'declined'))) {
                            setState(() => _f = _load());
                          }
                        },
                        child: const Text('Decline')),
                ]),
              ),
            ),
        ]);
      },
    );
  }
}
