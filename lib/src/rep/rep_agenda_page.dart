import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/posts.dart';
import '../shared/format.dart';
import '../shared/attendance_picker.dart';
import '../shared/widgets.dart';
import 'rep_shell.dart';

/// Reps send agenda topics before each meeting and say how they attend.
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
    return _AgendaData(
      all.where((m) => !m.isPast).toList(),
      await Repo.agendaItems(),
      await Repo.myAttendance(),
      await Repo.myNoInput(),
    );
  }

  void _reload() => setState(() => _f = _load());

  @override
  Widget build(BuildContext context) {
    return Loader<_AgendaData>(
      future: _f,
      onRetry: _reload,
      builder: (context, d) {
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
        if (d.upcoming.isEmpty) return const EmptyState('No upcoming meetings in your councils');
        return ListView(padding: const EdgeInsets.all(16), children: [
          Text('Send topics before each meeting and say how you will attend. Ask your classmates as early as you can.',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          for (final m in d.upcoming)
            Card(
              child: ListTile(
                title: Text(m.title),
                subtitle: Text('${fmtDateTime(m.startsAt)} · send by ${fmtDate(m.inputDeadline)}\n'
                    '${widget.data.council(m.councilId)?.name ?? ''}'),
                isThreeLine: true,
                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Builder(builder: (_) {
                    final n = d.items.where((a) => a.meetingId == m.id).length;
                    if (n > 0) return StatusChip('$n sent', Colors.green.shade700);
                    if (d.noInput.contains(m.id)) return StatusChip('No topics', Colors.blueGrey);
                    return StatusChip('Topics?', Colors.orange.shade800);
                  }),
                  const SizedBox(height: 4),
                  d.attendance[m.id] == null
                      ? StatusChip('Attending?', Colors.orange.shade800)
                      : StatusChip(attendanceLabels[d.attendance[m.id]] ?? '', Colors.blueGrey),
                ]),
                onTap: () => setState(() => _open = m.id),
              ),
            ),
        ]);
      },
    );
  }
}

class _AgendaData {
  final List<Meeting> upcoming;
  final List<AgendaItem> items;
  final Map<String, String> attendance;
  final Set<String> noInput;
  _AgendaData(this.upcoming, this.items, this.attendance, this.noInput);
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
