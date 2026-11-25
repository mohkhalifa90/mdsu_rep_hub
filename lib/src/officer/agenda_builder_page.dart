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
  late Future<(List<Meeting>, Map<String, String>, Map<String, MeetingStats>)> _f = _load();
  bool _deepLinkDone = false;
  bool _calendar = false; // list or month view
  bool _showPast = false;
  String? _councilFilter; // null = all councils
  final _search = TextEditingController();

  Future<(List<Meeting>, Map<String, String>, Map<String, MeetingStats>)> _load() async =>
      (await Repo.meetings(), await Repo.memberNames(), await Repo.meetingOverview());

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

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

  Widget _tile(Meeting m, Map<String, String> names, MeetingStats? st) => _MeetingCard(
        meeting: m,
        council: widget.data.council(m.councilId)?.name ?? '',
        stats: st,
        onOpen: () => _open(m, names),
        onDuplicate: () => _addMeeting(null, m),
        onRemind: () async {
          try {
            final n = await Repo.requestAgendaInput(m.id);
            if (mounted) showSnack(context, 'Reminder sent to $n reps');
            _reload();
          } catch (e) {
            if (mounted) showSnack(context, errorText(e));
          }
        },
      );

  /// [day]: from the calendar. [like]: duplicate this meeting (same council, title, time, place) four weeks later.
  Future<void> _addMeeting([DateTime? day, Meeting? like]) async {
    final d = widget.data;
    // SIEC first (most meetings), then A–Z
    final councils = [...d.councils]..sort((a, b) {
        if (a.isSiec != b.isSiec) return a.isSiec ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    String council = like?.councilId ?? councils.first.id;
    final title = TextEditingController(text: like?.title ?? ''),
        loc = TextEditingController(text: like?.location ?? 'Teams');
    DateTime date = day ?? DateTime.now().add(const Duration(days: 21));
    if (day == null && like != null) {
      date = like.startsAt.add(const Duration(days: 28));
      while (date.isBefore(DateTime.now())) {
        date = date.add(const Duration(days: 28));
      }
    }
    TimeOfDay time = like == null
        ? const TimeOfDay(hour: 13, minute: 15)
        : TimeOfDay(hour: like.startsAt.hour, minute: like.startsAt.minute);
    bool food = like?.servesFood ?? true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(like == null ? 'Add meeting' : 'Duplicate meeting'),
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
    return Loader<(List<Meeting>, Map<String, String>, Map<String, MeetingStats>)>(
      future: _f,
      onRetry: _reload,
      builder: (context, data) {
        final (all, names, stats) = data;
        final q = _search.text.trim().toLowerCase();
        final meetings = all.where((m) {
          if (_councilFilter != null && m.councilId != _councilFilter) return false;
          if (q.isEmpty) return true;
          final c = widget.data.council(m.councilId)?.name.toLowerCase() ?? '';
          return m.title.toLowerCase().contains(q) || c.contains(q) || (m.location ?? '').toLowerCase().contains(q);
        }).toList();
        final upcoming = meetings.where((m) => !m.isPast).toList();
        final past = meetings.where((m) => m.isPast).toList().reversed.toList();
        final usedCouncils = {for (final m in all) m.councilId}.toList()
          ..sort((a, b) => (widget.data.council(a)?.name ?? '').compareTo(widget.data.council(b)?.name ?? ''));
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
          Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, icon: Icon(Icons.view_list_outlined), label: Text('List')),
                ButtonSegment(value: true, icon: Icon(Icons.calendar_month_outlined), label: Text('Month')),
              ],
              selected: {_calendar},
              onSelectionChanged: (v) => setState(() => _calendar = v.first),
            ),
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String?>(
                initialValue: _councilFilter,
                isExpanded: true,
                isDense: true,
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.filter_list), labelText: 'Council', isDense: true),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('All councils')),
                  for (final id in usedCouncils)
                    DropdownMenuItem<String?>(
                        value: id,
                        child: Text(widget.data.council(id)?.name ?? '', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() => _councilFilter = v),
              ),
            ),
            SizedBox(
              width: 240,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search meetings',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _search.clear()),
                        ),
                ),
              ),
            ),
          ]),
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
            SectionTitle('Upcoming (${upcoming.length})'),
            if (upcoming.isEmpty)
              q.isNotEmpty || _councilFilter != null
                  ? const EmptyState('No upcoming meetings match', icon: Icons.search_off)
                  : EmptyState('No upcoming meetings. Add one – its council gets a notification.',
                      icon: Icons.event_outlined, actionLabel: 'Add meeting', onAction: _addMeeting),
            for (final m in upcoming) _tile(m, names, stats[m.id]),
            if (past.isNotEmpty) ...[
              const SizedBox(height: 8),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _showPast = !_showPast),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                  child: Row(children: [
                    Text('Earlier meetings (${past.length})', style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    AnimatedRotation(
                      turns: _showPast ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(Icons.expand_more),
                    ),
                  ]),
                ),
              ),
              if (_showPast) for (final m in past) _tile(m, names, stats[m.id]),
            ],
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


/// One meeting in the Head of Education's list: date, answers bar, what still needs doing, quick actions.
class _MeetingCard extends StatelessWidget {
  final Meeting meeting;
  final String council;
  final MeetingStats? stats;
  final VoidCallback onOpen, onDuplicate, onRemind;
  const _MeetingCard(
      {required this.meeting,
      required this.council,
      required this.stats,
      required this.onOpen,
      required this.onDuplicate,
      required this.onRemind});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = meeting;
    final st = stats;
    final past = m.isPast;
    final sameName = m.title.trim().toLowerCase() == council.trim().toLowerCase();
    final soon = !past && daysUntilDate(m.startsAt) <= 7;

    // what still needs doing
    final todo = <Widget>[
      if (st != null && st.newTopics > 0)
        StatusChip('${st.newTopics} new topic${st.newTopics == 1 ? '' : 's'}', Colors.orange.shade800),
      if (st != null && !past && m.servesFood && st.foodMissing > 0)
        StatusChip('🍽 ${st.foodMissing} food not answered', Colors.orange.shade800),
      if (st != null && !past && st.agendaPosted) StatusChip('Agenda posted ✓', Colors.green.shade700),
      if (st != null && soon && !st.agendaPosted) StatusChip('Agenda not posted', Colors.red.shade700),
      if (!past && !m.inputRequested && !soon) StatusChip('Reps not asked for topics', Colors.blueGrey),
    ];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DateTile(m.startsAt, muted: past, color: meetingColor(m.id)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  past
                      ? fmtDateY(m.startsAt).toUpperCase()
                      : '${relativeDay(m.startsAt).toUpperCase()} · ${fmtTime(m.startsAt)}',
                  style: t.textTheme.labelSmall?.copyWith(
                      color: past ? t.colorScheme.onSurfaceVariant : t.colorScheme.primary, letterSpacing: 0.6),
                ),
                const SizedBox(height: 2),
                Text(m.title, style: t.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  [if (!sameName) council, if ((m.location ?? '').isNotEmpty) m.location!].join(' · '),
                  style: t.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (st != null) ...[
                  const SizedBox(height: 10),
                  _AnswersBar(stats: st),
                  const SizedBox(height: 6),
                  Wrap(spacing: 12, runSpacing: 4, children: [
                    _legend(context, Colors.green.shade600, '${st.room} in the room'),
                    _legend(context, Colors.blue.shade600, '${st.online} online'),
                    _legend(context, Colors.grey.shade500, '${st.absent} can\'t'),
                    if (!past) _legend(context, t.colorScheme.outlineVariant, '${st.noAnswer} no answer'),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.record_voice_over_outlined, size: 14, color: t.colorScheme.onSurfaceVariant),
                      Text(' ${st.topics} topic${st.topics == 1 ? '' : 's'}', style: t.textTheme.labelSmall),
                    ]),
                  ]),
                ],
                if (todo.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: todo),
                ],
              ]),
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) {
                if (v == 'open') {
                  onOpen();
                } else if (v == 'remind') {
                  onRemind();
                } else {
                  onDuplicate();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'open', child: ListTile(leading: Icon(Icons.open_in_new), title: Text('Open'))),
                if (!past)
                  PopupMenuItem(
                      value: 'remind',
                      child: ListTile(
                          leading: const Icon(Icons.campaign_outlined),
                          title: Text(m.inputRequested ? 'Remind reps again' : 'Ask reps for topics'))),
                const PopupMenuItem(
                    value: 'duplicate',
                    child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Duplicate (4 weeks later)'))),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  Widget _legend(BuildContext context, Color c, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.labelSmall),
      ]);
}

/// Room / online / can't / no answer as one coloured bar
class _AnswersBar extends StatelessWidget {
  final MeetingStats stats;
  const _AnswersBar({required this.stats});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final parts = [
      (stats.room, Colors.green.shade600),
      (stats.online, Colors.blue.shade600),
      (stats.absent, Colors.grey.shade500),
      (stats.noAnswer, t.colorScheme.surfaceContainerHighest),
    ].where((p) => p.$1 > 0).toList();
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 8,
        child: parts.isEmpty
            ? Container(color: t.colorScheme.surfaceContainerHighest)
            : Row(children: [
                for (final (n, c) in parts) Expanded(flex: n, child: Container(color: c)),
              ]),
      ),
    );
  }
}
