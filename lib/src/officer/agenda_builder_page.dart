import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/posts.dart';
import '../shared/format.dart';
import '../shared/widgets.dart';
import 'agenda_docx.dart';
import 'attendance_export.dart';
import 'meetings_calendar.dart';
import 'officer_shell.dart';

/// Meetings: every meeting, upcoming and earlier. Opening one shows attendance, the reps'
/// topics, open follow-ups (carried forward automatically) and the agenda tools.
class AgendaBuilderPage extends StatefulWidget {
  final OfficerData data;
  final String? openMeetingId; // from a notification link agenda/<id>
  const AgendaBuilderPage({super.key, required this.data, this.openMeetingId});
  @override
  State<AgendaBuilderPage> createState() => _AgendaBuilderPageState();
}

class _AgendaBuilderPageState extends State<AgendaBuilderPage> {
  late Future<(List<Meeting>, Map<String, String>, List<AgendaItem>, List<Attendance>)> _f = _load();
  bool _deepLinkDone = false;
  bool _calendar = false; // list or month view

  Future<(List<Meeting>, Map<String, String>, List<AgendaItem>, List<Attendance>)> _load() async =>
      (await Repo.meetings(), await Repo.memberNames(), await Repo.agendaItems(), await Repo.attendance());

  void _reload() => setState(() => _f = _load());

  Future<void> _open(Meeting m, Map<String, String> names) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: Text(m.title)),
          body: ListView(padding: EdgeInsets.all(isNarrow(ctx) ? 12 : 24), children: [
            _MeetingAgenda(
              meeting: m,
              data: widget.data,
              names: names,
              onChanged: _reload,
              onDeleted: () => Navigator.pop(ctx),
            ),
          ]),
        ),
      ),
    );
    if (mounted) _reload();
  }

  Widget _tile(Meeting m, Map<String, String> names, List<AgendaItem> items, List<Attendance> att) {
    final topics = items.where((a) => a.meetingId == m.id && a.status != 'declined').length;
    final mine = att.where((a) => a.meetingId == m.id);
    final room = mine.where((a) => a.mode == 'offline').length;
    final online = mine.where((a) => a.mode == 'online').length;
    final absent = mine.where((a) => a.mode == 'absent').length;
    return Card(
      child: ListTile(
        title: Text('${m.title} · ${widget.data.council(m.councilId)?.name ?? ''}'),
        subtitle: Text('${m.isPast ? fmtDateY(m.startsAt) : fmtDateTime(m.startsAt)}'
            '${m.location == null || m.location!.isEmpty ? '' : ' · ${m.location}'}\n'
            '$topics topics · $room in the room · $online online · $absent can\'t attend'),
        isThreeLine: true,
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _open(m, names),
      ),
    );
  }

  Future<void> _addMeeting([DateTime? day]) async {
    final d = widget.data;
    // SIEC first (most meetings), then A–Z
    final councils = [...d.councils]..sort((a, b) {
        if (a.isSiec != b.isSiec) return a.isSiec ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    String council = councils.first.id;
    final title = TextEditingController(), loc = TextEditingController(text: 'Teams');
    DateTime date = day ?? DateTime.now().add(const Duration(days: 21));
    TimeOfDay time = const TimeOfDay(hour: 13, minute: 15);
    bool food = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Add meeting'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownMenu<String>(
                initialSelection: council,
                expandedInsets: EdgeInsets.zero,
                label: const Text('Council (type to search)'),
                enableFilter: true,
                enableSearch: true,
                requestFocusOnTap: true,
                menuHeight: 320,
                dropdownMenuEntries: [
                  for (final c in councils) DropdownMenuEntry<String>(value: c.id, label: c.name),
                ],
                onSelected: (v) => setD(() => council = v ?? council),
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
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: food,
                onChanged: (v) => setD(() => food = v),
                secondary: const Icon(Icons.restaurant_outlined),
                title: const Text('Food is served'),
                subtitle: const Text('Reps in the room are asked for food preferences (allergies)'),
              ),
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
        () => Repo.createMeeting(
            councilId: council, title: name, startsAt: startsAt, location: loc.text.trim(), servesFood: food),
        success: 'Meeting added ✓ The representatives of this council were notified')) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Loader<(List<Meeting>, Map<String, String>, List<AgendaItem>, List<Attendance>)>(
      future: _f,
      onRetry: _reload,
      builder: (context, data) {
        final (meetings, names, items, att) = data;
        final upcoming = meetings.where((m) => !m.isPast).toList();
        final past = meetings.where((m) => m.isPast).toList().reversed.toList();
        if (!_deepLinkDone && widget.openMeetingId != null) {
          _deepLinkDone = true;
          final hit = meetings.where((m) => m.id == widget.openMeetingId).toList();
          if (hit.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _open(hit.first, names));
        }
        return ListView(padding: EdgeInsets.all(isNarrow(context) ? 12 : 24), children: [
          PageIntro(
            text: 'All meetings. Open one to see who attends, the reps\' topics, follow-ups and to make the agenda. '
                'Unanswered issues from earlier meetings are added automatically.',
            actions: [
              OutlinedButton.icon(
                onPressed: () async {
                  try {
                    final where =
                        await exportAttendanceXlsx(semester: widget.data.semester, councils: widget.data.councils);
                    if (where != null && context.mounted) showSnack(context, 'Saved: $where');
                  } catch (e) {
                    if (context.mounted) showSnack(context, errorText(e));
                  }
                },
                icon: const Icon(Icons.how_to_reg_outlined),
                label: const Text('Attendance (Excel)'),
              ),
              FilledButton.icon(onPressed: _addMeeting, icon: const Icon(Icons.add), label: const Text('Add meeting')),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.view_list_outlined), label: Text('List')),
                ButtonSegment(value: true, icon: Icon(Icons.calendar_month_outlined), label: Text('Month')),
              ],
              selected: {_calendar},
              onSelectionChanged: (v) => setState(() => _calendar = v.first),
            ),
          ),
          const SizedBox(height: 12),
          if (_calendar)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: MeetingsCalendar(
                  meetings: meetings,
                  councilName: (id) => widget.data.council(id)?.name ?? '',
                  onOpen: (m) => _open(m, names),
                  onAdd: _addMeeting,
                ),
              ),
            )
          else ...[
          const SectionTitle('Upcoming'),
          if (upcoming.isEmpty)
            EmptyState('No upcoming meetings. Add one – its council gets a notification.',
                icon: Icons.event_outlined, actionLabel: 'Add meeting', onAction: _addMeeting),
          for (final m in upcoming) _tile(m, names, items, att),
          SectionTitle('Earlier meetings (${past.length})'),
          if (past.isEmpty) const EmptyState('No earlier meetings'),
          for (final m in past) _tile(m, names, items, att),
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
  final VoidCallback onDeleted;
  const _MeetingAgenda(
      {super.key,
      required this.meeting,
      required this.data,
      required this.names,
      required this.onChanged,
      required this.onDeleted});
  @override
  State<_MeetingAgenda> createState() => _MeetingAgendaState();
}

class _MeetingAgendaState extends State<_MeetingAgenda> {
  late bool _food = widget.meeting.servesFood;

  late Future<(List<OpenIssue>, List<AgendaItem>, List<Attendance>, Set<String>, Set<String>)> _f = _load();
  Future<(List<OpenIssue>, List<AgendaItem>, List<Attendance>, Set<String>, Set<String>)> _load() async => (
        await Repo.openIssuesForMeeting(widget.meeting.id),
        await Repo.agendaItems(meetingId: widget.meeting.id),
        await Repo.attendance(meetingId: widget.meeting.id),
        await Repo.councilMemberIds(widget.meeting.councilId),
        await Repo.noInputFor(widget.meeting.id),
      );

  /// Add someone who came without signing up (or change/remove an answer). Attendees can
  /// then log their time for the meeting.
  Future<void> _addAttendee(Set<String> members, List<Attendance> answers) async {
    final names = widget.names;
    final ids = names.keys.toList()
      ..sort((a, b) {
        final ma = members.contains(a) ? 0 : 1, mb = members.contains(b) ? 0 : 1;
        return ma != mb ? ma - mb : (names[a] ?? '').compareTo(names[b] ?? '');
      });
    String? who;
    String mode = 'offline';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Add attendee'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              DropdownButtonFormField<String>(
                initialValue: who,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Representative'),
                items: [
                  for (final id in ids)
                    DropdownMenuItem(
                        value: id,
                        child: Text('${names[id]}${members.contains(id) ? '' : '  (not in this council)'}',
                            overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setD(() {
                  who = v;
                  final a = answers.where((a) => a.userId == v).toList();
                  if (a.isNotEmpty) mode = a.first.mode;
                }),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'offline', label: Text('In the room')),
                  ButtonSegment(value: 'online', label: Text('Online')),
                  ButtonSegment(value: 'absent', label: Text('Didn\'t attend')),
                  ButtonSegment(value: 'remove', label: Text('No answer')),
                ],
                selected: {mode},
                onSelectionChanged: (s) => setD(() => mode = s.first),
              ),
              const SizedBox(height: 8),
              Text('People in the room or online can log time for this meeting.',
                  style: Theme.of(ctx).textTheme.bodySmall),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || who == null || !mounted) return;
    if (await runAction(
        context, () => Repo.setAttendanceFor(widget.meeting.id, who!, mode == 'remove' ? null : mode),
        success: 'Saved')) {
      setState(() => _f = _load());
      widget.onChanged();
    }
  }

  Widget _attendance(List<Attendance> answers, Set<String> members) {
    final byMode = <String, List<String>>{'offline': [], 'online': [], 'absent': []};
    final foodOf = <String, String>{}; // name → food text, for people in the room
    for (final a in answers) {
      final n = widget.names[a.userId] ?? '?';
      byMode[a.mode]?.add(n);
      if (a.mode == 'offline') foodOf[n] = a.foodText;
    }
    final answered = answers.map((a) => a.userId).toSet();
    final missing = [for (final id in members) if (!answered.contains(id)) widget.names[id] ?? '?'];
    for (final l in [...byMode.values, missing]) {
      l.sort();
    }
    Widget group(String label, IconData icon, Color color, List<String> people) => SizedBox(
          width: 170,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text('$label (${people.length})', style: TextStyle(fontWeight: FontWeight.bold, color: color)),
            ]),
            const SizedBox(height: 4),
            if (people.isEmpty) const Text('–'),
            for (final n in people)
              _food && label == 'In the room'
                  ? Text.rich(TextSpan(children: [
                      TextSpan(text: n),
                      if ((foodOf[n] ?? '').isNotEmpty && foodOf[n] != 'None')
                        TextSpan(
                            text: '\n  🍽 ${foodOf[n]}',
                            style: TextStyle(fontSize: 12, color: Colors.orange.shade900)),
                      if ((foodOf[n] ?? '').isEmpty)
                        const TextSpan(text: '\n  🍽 not answered', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ]))
                  : Text(n),
          ]),
        );
    // food counts for the people in the room
    final inRoom = answers.where((a) => a.mode == 'offline').toList();
    final counts = <String, int>{};
    final others = <String>[];
    for (final a in inRoom) {
      for (final f in a.food) {
        counts[f] = (counts[f] ?? 0) + 1;
      }
      if (a.food.contains('other') && (a.foodOther ?? '').isNotEmpty) {
        others.add('${a.foodOther} (${widget.names[a.userId] ?? '?'})');
      }
    }
    final noFood = inRoom.where((a) => a.food.isEmpty).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(spacing: 16, runSpacing: 16, children: [
          group('In the room', Icons.meeting_room_outlined, Colors.green.shade700, byMode['offline']!),
          group('Online', Icons.videocam_outlined, Colors.blue.shade700, byMode['online']!),
          group('Can\'t attend', Icons.event_busy_outlined, Colors.red.shade700, byMode['absent']!),
          group('No answer', Icons.help_outline, Colors.grey.shade700, missing),
          if (_food && inRoom.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.restaurant_outlined, size: 18, color: Colors.orange.shade900),
                  const SizedBox(width: 6),
                  Text('Food for ${inRoom.length} in the room',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Colors.orange.shade900)),
                ]),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final e in foodLabels.entries)
                    if ((counts[e.key] ?? 0) > 0 && e.key != 'other') Chip(label: Text('${e.value}: ${counts[e.key]}')),
                  if (noFood > 0)
                    Chip(label: Text('Not answered: $noFood'), backgroundColor: Colors.grey.withValues(alpha: 0.15)),
                ]),
                if (others.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('Other: ${others.join(' · ')}'),
                ],
              ]),
            ),
        ]),
      ),
    );
  }

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
    return Loader<(List<OpenIssue>, List<AgendaItem>, List<Attendance>, Set<String>, Set<String>)>(
      future: _f,
      onRetry: () => setState(() => _f = _load()),
      builder: (context, data) {
        final (fol, items, answers, members, noInput) = data;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${m.title} · ${widget.data.council(m.councilId)?.name ?? ''}',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 2),
              Text('${fmtDateTime(m.startsAt)} · ${m.location ?? ''} · input closes ${fmtDate(m.inputDeadline)}'),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (m.isPast)
                  StatusChip('Held ${fmtDateY(m.startsAt)}', Colors.blueGrey)
                else if (m.inputRequested)
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
                FilterChip(
                  avatar: const Icon(Icons.restaurant_outlined, size: 18),
                  label: const Text('Food served'),
                  tooltip: 'Ask reps in the room for food preferences',
                  selected: _food,
                  onSelected: (v) async {
                    setState(() => _food = v);
                    final ok = await runAction(context, () => Repo.setServesFood(m.id, v),
                        success: v ? 'Reps in the room will be asked for food preferences' : 'No food at this meeting');
                    if (!ok && mounted) setState(() => _food = !v);
                    if (ok) widget.onChanged();
                  },
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
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.publish_outlined),
                  label: const Text('Add final agenda'),
                  onPressed: () => showNewPostDialog(context, councils: widget.data.councils, meeting: m),
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
                      widget.onDeleted();
                    }
                  },
                ),
              ]),
              ]),
            ),
          ),
          SectionTitle('Attendance',
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                TextButton.icon(
                    onPressed: () => _addAttendee(members, answers),
                    icon: const Icon(Icons.person_add_alt),
                    label: const Text('Add attendee')),
                IconButton(
                    tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => setState(() => _f = _load())),
              ])),
          _attendance(answers, members),
          if (noInput.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                'No topics this time: ${([for (final id in noInput) widget.names[id] ?? '?']..sort()).join(', ')}',
                style: Theme.of(context).textTheme.bodySmall,
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
          if (items.isEmpty) const EmptyState('No topics from the reps yet. Use "Ask reps for input" to remind them.'),
          for (final a in items)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(a.title, style: Theme.of(context).textTheme.titleSmall)),
                  const SizedBox(width: 8),
                  StatusChip.agenda(a.status),
                ]),
                const SizedBox(height: 4),
                Text('${a.details}\n${widget.names[a.userId] ?? ''} · ${a.source} · ${a.studentCount} students'),
                const SizedBox(height: 8),
                Wrap(spacing: 6, children: [
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
                ]),
              ),
            ),
        ]);
      },
    );
  }
}
