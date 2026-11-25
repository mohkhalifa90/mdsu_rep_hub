import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/posts.dart';
import '../shared/food_picker.dart';
import '../shared/format.dart';
import '../shared/attendance_picker.dart';
import '../shared/widgets.dart';
import 'hours_page.dart';
import 'rep_shell.dart';

/// Meetings: reps say how they attend and send topics before each meeting, and can look
/// back at every earlier meeting (final agenda, their attendance, their topics).
class RepAgendaPage extends StatefulWidget {
  final RepData data;
  final String? openMeetingId;
  const RepAgendaPage({super.key, required this.data, this.openMeetingId});
  @override
  State<RepAgendaPage> createState() => _RepAgendaPageState();
}

class _RepAgendaPageState extends State<RepAgendaPage> {
  late Future<_AgendaData> _f = _load();
  String? _open;
  bool _showPast = false;
  final _foodRev = <String, int>{}; // reload the food picker after the attendance is saved

  @override
  void initState() {
    super.initState();
    _open = widget.openMeetingId;
  }

  @override
  void didUpdateWidget(RepAgendaPage old) {
    super.didUpdateWidget(old);
    // opened from a notification or the Home page while this tab was already showing
    if (widget.openMeetingId != null && widget.openMeetingId != old.openMeetingId) {
      setState(() => _open = widget.openMeetingId);
    }
  }

  Future<_AgendaData> _load() async {
    final all = await Repo.meetings();
    final sem = widget.data.semester;
    final entries = sem == null ? <TimeEntry>[] : await Repo.entries(userId: widget.data.me.id, semesterId: sem.id);
    return _AgendaData(
      all.where((m) => !m.isPast).toList(),
      all.where((m) => m.isPast).toList().reversed.toList(),
      await Repo.agendaItems(),
      await Repo.myAttendance(),
      await Repo.myNoInput(),
      entries.map((e) => e.meetingId).whereType<String>().toSet(),
    );
  }

  void _reload() => setState(() => _f = _load());

  @override
  Widget build(BuildContext context) {
    return Loader<_AgendaData>(
      future: _f,
      onRetry: _reload,
      builder: (context, d) {
        final past = d.past.where((m) => m.id == _open).toList();
        if (past.isNotEmpty) {
          return _PastMeeting(
            meeting: past.first,
            data: widget.data,
            myItems: d.items.where((a) => a.meetingId == past.first.id).toList(),
            attendance: d.attendance[past.first.id],
            onBack: () => setState(() => _open = null),
          );
        }
        final open = d.upcoming.where((m) => m.id == _open).toList();
        if (open.isNotEmpty) {
          return _MeetingInput(
            meeting: open.first,
            data: widget.data,
            myItems: d.items.where((a) => a.meetingId == open.first.id).toList(),
            attendance: d.attendance[open.first.id],
            noInput: d.noInput.contains(open.first.id),
            onBack: () => setState(() => _open = null),
            onChanged: _reload,
          );
        }
        return CenteredList(children: [
          Text('Say how you will attend and send your topics before each meeting.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          if (d.upcoming.isEmpty)
            const EmptyState(
                'No upcoming meetings in your councils. When the Head of Education adds one, you get a notification.',
                icon: Icons.event_available_outlined),
          for (final (i, m) in d.upcoming.indexed)
            _UpcomingCard(
              meeting: m,
              color: listColor(i),
              next: i == 0,
              council: widget.data.council(m.councilId)?.name ?? '',
              topics: d.items.where((a) => a.meetingId == m.id).length,
              noInput: d.noInput.contains(m.id),
              attendance: d.attendance[m.id],
              foodKey: _foodRev[m.id] ?? 0,
              onOpen: () => setState(() => _open = m.id),
              onAttend: (mode) async {
                final before = d.attendance[m.id];
                void put(String? v) {
                  if (v == null) {
                    d.attendance.remove(m.id);
                  } else {
                    d.attendance[m.id] = v;
                  }
                }

                setState(() => put(mode));
                final ok = await runAction(context, () => Repo.setAttendance(m.id, mode));
                if (!ok && mounted) {
                  setState(() => put(before));
                } else if (mounted) {
                  setState(() => _foodRev[m.id] = (_foodRev[m.id] ?? 0) + 1);
                }
                return ok;
              },
            ),
          if (d.past.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _showPast = !_showPast),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(children: [
                  Text('Earlier meetings (${d.past.length})', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _showPast ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more),
                  ),
                ]),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: !_showPast
                  ? const SizedBox(width: double.infinity)
                  : Column(children: [
                      for (final m in d.past)
                        _PastTile(
                          meeting: m,
                          council: widget.data.council(m.councilId)?.name ?? '',
                          attendance: d.attendance[m.id],
                          logged: d.logged.contains(m.id),
                          onOpen: () => setState(() => _open = m.id),
                          onLog: () async {
                            if (await showLogTimeSheet(context, widget.data, meetingId: m.id)) _reload();
                          },
                        ),
                    ]),
            ),
          ],
        ]);
      },
    );
  }
}

/// An upcoming meeting: date, attendance buttons and where your topics stand.
class _UpcomingCard extends StatefulWidget {
  final Meeting meeting;
  final bool next;
  final String council;
  final int topics;
  final bool noInput;
  final String? attendance;
  final int foodKey;
  final Color color;
  final VoidCallback onOpen;
  final Future<bool> Function(String? mode) onAttend;
  const _UpcomingCard(
      {required this.meeting,
      required this.color,
      required this.foodKey,
      required this.next,
      required this.council,
      required this.topics,
      required this.noInput,
      required this.attendance,
      required this.onOpen,
      required this.onAttend});
  @override
  State<_UpcomingCard> createState() => _UpcomingCardState();
}

/// An upcoming meeting. Answered: a short summary (attendance, food, topics) with one "Change".
/// Changing (or answering the first time): pick attendance and food, then one "Save changes".
class _UpcomingCardState extends State<_UpcomingCard> {
  bool _editing = false, _saving = false;
  // saved food
  String? _food;
  String _foodOther = '';
  bool _foodLoaded = false;
  // while changing
  String? _pMode;
  String? _pFood;
  final _pOther = TextEditingController();

  Meeting get m => widget.meeting;
  bool get _room => m.servesFood;

  /// food changes close after the agenda input deadline (only once answered)
  bool get _foodClosed {
    final now = DateTime.now();
    final d = m.inputDeadline;
    return _food != null && DateTime(now.year, now.month, now.day).isAfter(DateTime(d.year, d.month, d.day));
  }

  @override
  void initState() {
    super.initState();
    _pMode = widget.attendance;
    _loadFood();
  }

  @override
  void didUpdateWidget(_UpcomingCard old) {
    super.didUpdateWidget(old);
    if (old.foodKey != widget.foodKey) _loadFood(); // attendance saved – the last food may be filled in
  }

  @override
  void dispose() {
    _pOther.dispose();
    super.dispose();
  }

  Future<void> _loadFood() async {
    if (!_room || widget.attendance != 'offline') {
      if (mounted) setState(() => _foodLoaded = true);
      return;
    }
    try {
      final (food, other) = await Repo.myFood(m.id);
      if (!mounted) return;
      setState(() {
        _food = food.isEmpty ? null : food.first;
        _foodOther = other ?? '';
        _foodLoaded = true;
        if (!_editing) {
          _pFood = _food;
          _pOther.text = _foodOther;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _foodLoaded = true);
    }
  }

  void _startEditing() => setState(() {
        _editing = true;
        _pMode = widget.attendance;
        _pFood = _food;
        _pOther.text = _foodOther;
      });

  Future<void> _save() async {
    final mode = _pMode;
    if (mode == null) {
      showSnack(context, 'Choose how you will attend');
      return;
    }
    final needFood = mode == 'offline' && _room && !_foodClosed;
    if (needFood && _pFood == null) {
      showSnack(context, 'Choose your food preference');
      return;
    }
    if (needFood && _pFood == 'other' && _pOther.text.trim().isEmpty) {
      showSnack(context, 'Write what "Other" means (e.g. nut allergy)');
      return;
    }
    setState(() => _saving = true);
    var ok = true;
    if (mode != widget.attendance) ok = await widget.onAttend(mode);
    final foodChanged = _pFood != _food || (_pFood == 'other' && _pOther.text.trim() != _foodOther);
    if (ok && needFood && foodChanged && mounted) {
      ok = await runAction(
          context, () => Repo.setFood(m.id, [_pFood!], _pFood == 'other' ? _pOther.text.trim() : null));
      if (ok) {
        _food = _pFood;
        _foodOther = _pFood == 'other' ? _pOther.text.trim() : '';
      }
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _editing = false;
    });
    if (ok) {
      showSnack(context, 'Saved');
      _loadFood(); // read back what is saved
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final attendance = widget.attendance;
    final topics = widget.topics;
    final deadlinePassed = daysUntilDate(m.inputDeadline) < 0;
    final (IconData icon, Color color, String text, String action) = topics > 0
        ? (Icons.check_circle, Colors.green.shade700, '$topics topic${topics == 1 ? '' : 's'} sent', 'Add topics')
        : widget.noInput
            ? (Icons.check_circle_outline, Colors.blueGrey, 'No topics this time', 'Add topics')
            : deadlinePassed
                ? (Icons.schedule, Colors.grey, 'Topic deadline passed (${fmtDate(m.inputDeadline)})', 'Open')
                : (Icons.record_voice_over_outlined, Colors.orange.shade800,
                    'Send your topics by ${fmtDate(m.inputDeadline)}', 'Add topics');
    final sameName = m.title.trim().toLowerCase() == widget.council.trim().toLowerCase();
    final editing = attendance == null || _editing;

    final (IconData aIcon, Color aColor) = switch (attendance) {
      'offline' => (Icons.meeting_room_outlined, Colors.green.shade700),
      'online' => (Icons.videocam_outlined, Colors.blue.shade700),
      _ => (Icons.event_busy_outlined, Colors.red.shade700),
    };

    Widget line(IconData i, Color c, String s, {bool bold = false, VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Icon(i, size: 16, color: c),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(s,
                      style: t.textTheme.bodyMedium?.copyWith(color: c, fontWeight: bold ? FontWeight.w600 : null))),
            ]),
          ),
        );

    // ---- answered: the summary ----
    final summary = Container(
      key: const ValueKey('summary'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(aIcon, size: 18, color: aColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(attendanceLabels[attendance] ?? '',
                style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: aColor)),
          ),
          FilledButton.tonalIcon(
            onPressed: _startEditing,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Change'),
          ),
        ]),
        if (attendance == 'offline' && _room && _foodLoaded)
          _food == null
              ? line(Icons.restaurant_outlined, Colors.orange.shade900, 'Food: not chosen yet – tap to choose',
                  bold: true, onTap: _startEditing)
              : line(Icons.restaurant_outlined, t.colorScheme.onSurface,
                  'Food: ${foodSummary([_food!], _foodOther)}${_foodClosed ? '  (closed)' : ''}'),
        line(icon, color, text, onTap: widget.onOpen),
      ]),
    );

    // ---- answering / changing ----
    final foodLocked = _foodClosed;
    final choices = Column(
      key: const ValueKey('choices'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Will you attend?', style: t.textTheme.labelMedium),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: AttendancePicker(value: _pMode, onChanged: (v) => setState(() => _pMode = v)),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _pMode == 'offline' && _room
              ? Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: t.colorScheme.outlineVariant),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.restaurant_outlined, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text.rich(
                            TextSpan(children: [
                              const TextSpan(text: 'Special food preference (allergies)'),
                              TextSpan(text: ' *', style: TextStyle(color: Colors.red.shade700)),
                            ]),
                            style: t.textTheme.titleSmall),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Text(
                      foodLocked
                          ? 'Closed on ${fmtDate(m.inputDeadline)} – the food is ordered. Ask the Head of Education to change it.'
                          : 'Choose one. You can change it until ${fmtDate(m.inputDeadline)}.',
                      style: t.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final e in foodLabels.entries)
                        ChoiceChip(
                          label: Text(e.value),
                          selected: _pFood == e.key,
                          onSelected: foodLocked ? null : (on) => setState(() => _pFood = on ? e.key : null),
                        ),
                    ]),
                    if (_pFood == 'other') ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: _pOther,
                        enabled: !foodLocked,
                        maxLength: 200,
                        decoration: const InputDecoration(
                            labelText: 'Other – what should we know?',
                            hintText: 'e.g. nut allergy, halal',
                            counterText: ''),
                      ),
                    ],
                  ]),
                )
              : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: t.textTheme.bodyMedium?.copyWith(color: color))),
          TextButton.icon(
              onPressed: widget.onOpen,
              icon: Icon(action == 'Open' ? Icons.open_in_new : Icons.add, size: 18),
              label: Text(action)),
        ]),
        const SizedBox(height: 4),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (attendance != null)
            TextButton(onPressed: _saving ? null : () => setState(() => _editing = false), child: const Text('Cancel')),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save changes'),
          ),
        ]),
      ],
    );

    final mc = widget.color; // every meeting its own colour
    return Card(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: widget.next ? BorderSide(color: mc, width: 1.5) : BorderSide.none),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: mc, width: 5))),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          InkWell(
            onTap: widget.onOpen,
            borderRadius: BorderRadius.circular(10),
            child: Row(children: [
              DateTile(m.startsAt, color: mc),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    '${widget.next ? 'NEXT · ' : ''}${relativeDay(m.startsAt).toUpperCase()} · ${fmtTime(m.startsAt)}',
                    style: t.textTheme.labelSmall?.copyWith(color: mc, letterSpacing: 0.6),
                  ),
                  const SizedBox(height: 2),
                  Text(m.title, style: t.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (!sameName && widget.council.isNotEmpty) Text(widget.council, style: t.textTheme.bodySmall),
                  if (m.location != null && m.location!.isNotEmpty)
                    Row(children: [
                      Icon(Icons.place_outlined, size: 14, color: t.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 3),
                      Flexible(child: Text(m.location!, style: t.textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
                    ]),
                ]),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
          const SizedBox(height: 12),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: editing ? choices : summary,
          ),
        ]),
      ),
    );
  }
}

/// An earlier meeting in the folded list.
class _PastTile extends StatelessWidget {
  final Meeting meeting;
  final String council;
  final String? attendance;
  final bool logged;
  final VoidCallback onOpen;
  final VoidCallback onLog;
  const _PastTile(
      {required this.meeting,
      required this.council,
      required this.attendance,
      required this.logged,
      required this.onOpen,
      required this.onLog});

  @override
  Widget build(BuildContext context) {
    final m = meeting;
    final attended = attendance == 'offline' || attendance == 'online';
    final Widget trailing = attended
        ? (logged
            ? StatusChip('Time logged', Colors.green.shade700)
            : FilledButton.tonal(onPressed: onLog, child: const Text('Log time')))
        : attendance == 'absent'
            ? StatusChip('Didn\'t attend', Colors.grey)
            : const SizedBox.shrink();
    final sameName = m.title.trim().toLowerCase() == council.trim().toLowerCase();
    return Card(
      child: ListTile(
        leading: DateTile(m.startsAt, muted: true, width: 44),
        title: Text(m.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${fmtDateY(m.startsAt)}${sameName ? '' : ' · $council'}'),
        trailing: trailing,
        onTap: onOpen,
      ),
    );
  }
}

/// An earlier meeting: final agenda, how you attended and the topics you sent.
class _PastMeeting extends StatelessWidget {
  final Meeting meeting;
  final RepData data;
  final List<AgendaItem> myItems;
  final String? attendance;
  final VoidCallback onBack;
  const _PastMeeting(
      {required this.meeting, required this.data, required this.myItems, required this.attendance, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final m = meeting;
    final attended = attendance == 'offline' || attendance == 'online';
    return ListView(padding: const EdgeInsets.all(16), children: [
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(onPressed: onBack, icon: const Icon(Icons.arrow_back), label: const Text('Back')),
      ),
      Text(m.title, style: Theme.of(context).textTheme.titleLarge),
      Text('${fmtDateTime(m.startsAt)} · ${data.council(m.councilId)?.name ?? ''}'),
      if (m.location != null && m.location!.isNotEmpty) Text(m.location!),
      FutureBuilder<Post?>(
        future: Repo.finalAgenda(m.id),
        builder: (context, s) => s.data == null
            ? const SizedBox.shrink()
            : Padding(padding: const EdgeInsets.only(top: 12), child: PostCard(post: s.data!)),
      ),
      const SectionTitle('Your attendance'),
      Card(
        child: ListTile(
          leading: Icon(attended ? Icons.check_circle : Icons.info_outline,
              color: attended ? Colors.green.shade700 : Colors.grey),
          title: Text(attendance == null ? 'You did not answer' : (attendanceLabels[attendance] ?? '')),
          subtitle: Text(attended
              ? 'You can log time for this meeting.'
              : 'Were you there anyway? Ask the Head of Education to add you, then you can log your time.'),
        ),
      ),
      const SectionTitle('Topics you sent'),
      if (myItems.isEmpty) const EmptyState('No topics'),
      for (final a in myItems)
        Card(child: ListTile(title: Text(a.title), subtitle: Text(a.details), trailing: StatusChip.agenda(a.status))),
    ]);
  }
}

class _AgendaData {
  final List<Meeting> upcoming;
  final List<Meeting> past;
  final List<AgendaItem> items;
  final Map<String, String> attendance;
  final Set<String> noInput;
  final Set<String> logged; // meetings I logged time for
  _AgendaData(this.upcoming, this.past, this.items, this.attendance, this.noInput, this.logged);
}

class _MeetingInput extends StatefulWidget {
  final Meeting meeting;
  final RepData data;
  final List<AgendaItem> myItems;
  final String? attendance;
  final bool noInput;
  final VoidCallback onBack;
  final VoidCallback onChanged;
  const _MeetingInput(
      {required this.meeting,
      required this.data,
      required this.myItems,
      required this.attendance,
      required this.noInput,
      required this.onBack,
      required this.onChanged});
  @override
  State<_MeetingInput> createState() => _MeetingInputState();
}

class _MeetingInputState extends State<_MeetingInput> {
  final _title = TextEditingController();
  final _details = TextEditingController();
  final _count = TextEditingController(text: '5');
  String _source = agendaSources.first;
  late final Future<List<OpenIssue>> _issues = Repo.openIssuesForMeeting(widget.meeting.id);
  late final Future<Post?> _finalAgenda = Repo.finalAgenda(widget.meeting.id);
  late String? _attendance = widget.attendance;
  int _foodRev = 0;
  // null = not answered yet; true = has topics; false = nothing to add this time
  late bool? _hasTopics = widget.myItems.isNotEmpty ? true : (widget.noInput ? false : null);

  Future<void> _setHasTopics(bool hasTopics) async {
    final before = _hasTopics;
    setState(() => _hasTopics = hasTopics);
    final ok = await runAction(context, () => Repo.setNoInput(widget.meeting.id, !hasTopics),
        success: hasTopics ? null : 'Saved: no topics this time');
    if (!ok && mounted) {
      setState(() => _hasTopics = before);
    } else if (!hasTopics) {
      widget.onChanged();
    }
  }

  Future<void> _setAttendance(String? mode) async {
    final before = _attendance;
    setState(() => _attendance = mode);
    final ok = await runAction(context, () => Repo.setAttendance(widget.meeting.id, mode),
        success: mode == null ? null : 'Saved: ${attendanceLabels[mode]}');
    if (!ok && mounted) {
      setState(() => _attendance = before);
    } else {
      if (mounted) setState(() => _foodRev++);
      widget.onChanged();
    }
  }

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
      if (widget.noInput) await Repo.setNoInput(widget.meeting.id, false).catchError((_) {});
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
      if (m.location != null && m.location!.isNotEmpty) Text(m.location!),
      FutureBuilder<Post?>(
        future: _finalAgenda,
        builder: (context, s) => s.data == null
            ? const SizedBox.shrink()
            : Padding(padding: const EdgeInsets.only(top: 12), child: PostCard(post: s.data!)),
      ),
      const SectionTitle('How will you attend?'),
      AttendancePicker(value: _attendance, onChanged: _setAttendance),
      AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _attendance == 'offline' && m.servesFood
            ? FoodPicker(key: ValueKey('${m.id}-$_foodRev'), meetingId: m.id, deadline: m.inputDeadline, locked: m.isPast)
            : const SizedBox(width: double.infinity),
      ),
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
      const SectionTitle('Do you have topics for this meeting?'),
      SegmentedButton<bool>(
        emptySelectionAllowed: true,
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: true, icon: Icon(Icons.record_voice_over_outlined), label: Text('Yes, add topics')),
          ButtonSegment(value: false, icon: Icon(Icons.do_not_disturb_alt_outlined), label: Text('No topics')),
        ],
        selected: _hasTopics == null ? <bool>{} : {_hasTopics!},
        onSelectionChanged: (s) {
          if (s.isNotEmpty) _setHasTopics(s.first);
        },
      ),
      if (_hasTopics == false)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('OK – the Head of Education can see you have nothing to add this time. '
              'If something comes up, choose "Yes, add topics".',
              style: Theme.of(context).textTheme.bodySmall),
        ),
      if (_hasTopics == true) ...[
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
      ],
      if (widget.myItems.isNotEmpty || _hasTopics == true) const SectionTitle('My items for this meeting'),
      if (widget.myItems.isEmpty && _hasTopics == true) const EmptyState('Nothing sent yet'),
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
