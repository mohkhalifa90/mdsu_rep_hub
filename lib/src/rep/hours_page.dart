import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/format.dart';
import '../shared/widgets.dart';
import 'rep_shell.dart';

/// Replaces the Excel time report: log as you go, submit at the end of the semester.
class HoursPage extends StatefulWidget {
  final RepData data;
  const HoursPage({super.key, required this.data});
  @override
  State<HoursPage> createState() => _HoursPageState();
}

class _HoursPageState extends State<HoursPage> {
  late Future<(ReportRow?, List<TimeEntry>, Set<String>)> _f = _load();

  Future<(ReportRow?, List<TimeEntry>, Set<String>)> _load() async {
    final d = widget.data;
    if (d.semester == null) return (null, <TimeEntry>[], <String>{});
    final entries = await Repo.entries(userId: d.me.id, semesterId: d.semester!.id);
    final notes = await Repo.attachments(entries.map((e) => e.id).toList());
    return (await Repo.myReport(), entries, notes.map((a) => a.entryId).toSet());
  }

  void _reload() => setState(() => _f = _load());

  Future<void> _submit(ReportRow r, int withoutNotes) async {
    final ok = await confirm(
      context,
      'Submit time report?',
      '${fmtMinutes(r.minutes)} · ${sek(r.amount)}\n\n'
          '${withoutNotes > 0 ? '$withoutNotes entries have no notes attached. Reports without documentation may be returned.\n\n' : ''}'
          'It goes to the Head of Education under your name. You cannot edit it unless it is returned.',
      ok: 'Submit',
    );
    if (!ok) return;
    if (await runAction(context, Repo.submitReport, success: 'Submitted ✓')) _reload();
  }

  Widget _note(BuildContext context, IconData icon, Color color, String text) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(color: color))),
        ]),
      );

  Widget _entry(BuildContext context, TimeEntry e, bool hasNotes, bool locked) {
    final t = Theme.of(context);
    final (icon, color) = activityLook(e.activity);
    final d = widget.data;
    return ListTile(
      leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.14), child: Icon(icon, color: color, size: 20)),
      title: Text(activityLabels[e.activity] ?? e.activity, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${fmtDate(e.workDate)}${e.fromText == null ? '' : ' · ${e.fromText}–${e.toText}'}'
            '${d.council(e.councilId) == null ? '' : ' · ${d.council(e.councilId)!.name}'}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        if (e.description.isNotEmpty) Text(e.description, maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        hasNotes
            ? Row(children: [
                Icon(Icons.attach_file, size: 14, color: Colors.green.shade700),
                Text(' Notes attached', style: t.textTheme.labelSmall?.copyWith(color: Colors.green.shade700)),
              ])
            : Row(children: [
                Icon(Icons.warning_amber_rounded, size: 14, color: Colors.orange.shade800),
                Text(locked ? ' No notes' : ' Tap to attach notes',
                    style: t.textTheme.labelSmall?.copyWith(color: Colors.orange.shade800)),
              ]),
      ]),
      isThreeLine: true,
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(fmtMinutes(e.minutes), style: const TextStyle(fontWeight: FontWeight.bold)),
        if (!locked)
          InkWell(
            onTap: () async {
              if (await confirm(context, 'Delete entry?', e.description, ok: 'Delete') &&
                  await runAction(context, () => Repo.deleteEntry(e.id))) {
                _reload();
              }
            },
            child: Icon(Icons.delete_outline, size: 18, color: t.colorScheme.onSurfaceVariant),
          ),
      ]),
      onTap: locked || hasNotes
          ? null
          : () async {
              if (await pickAndUploadNote(context, e.id)) _reload();
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    if (d.semester == null) return const EmptyState('No active semester yet. Ask the Head of Education.');
    return Loader<(ReportRow?, List<TimeEntry>, Set<String>)>(
      future: _f,
      onRetry: _reload,
      builder: (context, data) {
        final (r, entries, withNotes) = data;
        final locked = r?.isLocked ?? false;
        final minutes = entries.fold<int>(0, (a, e) => a + e.minutes);
        final halves = entries.fold<int>(0, (a, e) => a + e.halfHours);
        final withoutNotes = entries.where((e) => !withNotes.contains(e.id)).length;
        final t = Theme.of(context);
        final status = r?.status ?? 'draft';
        final left = daysUntil(d.semester!.reportDeadline);
        // group the entries by month, newest month first
        final byMonth = <DateTime, List<TimeEntry>>{};
        for (final e in [...entries]..sort((a, b) => b.workDate.compareTo(a.workDate))) {
          byMonth.putIfAbsent(DateTime(e.workDate.year, e.workDate.month), () => []).add(e);
        }
        return Stack(children: [
          CenteredList(children: [
            Card(
              color: t.colorScheme.primary,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: DefaultTextStyle(
                  style: TextStyle(color: t.colorScheme.onPrimary),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${d.semester!.name} · time report', style: TextStyle(color: t.colorScheme.onPrimary.withValues(alpha: 0.85))),
                    const SizedBox(height: 4),
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text('${fmtHours(minutes)} h',
                          style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold, color: t.colorScheme.onPrimary)),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('≈ ${sek(d.me.isMember ? halves * d.semester!.halfHourRate : 0)}'),
                      ),
                    ]),
                    Text('$halves started half hours × ${d.semester!.halfHourRate} SEK',
                        style: TextStyle(fontSize: 12, color: t.colorScheme.onPrimary.withValues(alpha: 0.8))),
                    if (!locked && left >= 0)
                      Text('$left day${left == 1 ? '' : 's'} to the deadline (${fmtDateY(d.semester!.reportDeadline)})',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ReportSteps(status: status),
                  if (r?.status == 'paid')
                    FutureBuilder<(String?, String)>(
                      future: Repo.payslipLink(),
                      builder: (context, s) => s.data?.$1 == null
                          ? const SizedBox.shrink()
                          : Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: FilledButton.tonalIcon(
                                onPressed: () =>
                                    launchUrl(Uri.parse(s.data!.$1!), mode: LaunchMode.externalApplication),
                                icon: const Icon(Icons.receipt_long_outlined),
                                label: Text('See your payslip in ${s.data!.$2}'),
                              ),
                            ),
                    ),
                  if (r?.status == 'returned' && (r?.reviewerComment ?? '').isNotEmpty)
                    _note(context, Icons.undo, Colors.orange.shade900, 'Returned: ${r!.reviewerComment}'),
                  if (locked)
                    _note(context, Icons.lock_outline, t.colorScheme.onSurfaceVariant,
                        'Submitted and locked until it is returned or the next semester starts.'),
                  if (!d.me.isMember)
                    _note(context, Icons.error_outline, Colors.red,
                        'You are not a union member, so hours are not paid. Become a member at mdsu.se.'),
                  if (r != null && !r.hasPersonalNumber)
                    _note(context, Icons.error_outline, Colors.red,
                        'Add your personal number (or samordningsnummer) under More → My profile to get paid.'),
                  if (withoutNotes > 0 && !locked)
                    _note(context, Icons.attach_file, Colors.orange.shade800,
                        '$withoutNotes entr${withoutNotes == 1 ? 'y has' : 'ies have'} no notes – tap one to attach them.'),
                ]),
              ),
            ),
            if (entries.isEmpty)
              const EmptyState('No time logged yet. Tap “Log time” after each meeting or task.', icon: Icons.timer_outlined),
            for (final month in byMonth.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                child: Row(children: [
                  Text(fmtMonthYear(month.key), style: t.textTheme.titleSmall),
                  const Spacer(),
                  Text('${fmtHours(month.value.fold<int>(0, (a, e) => a + e.minutes))} h',
                      style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary)),
                ]),
              ),
              Card(
                child: Column(children: [
                  for (final (i, e) in month.value.indexed) ...[
                    if (i > 0) const Divider(height: 1, indent: 64),
                    _entry(context, e, withNotes.contains(e.id), locked),
                  ],
                ]),
              ),
            ],
            if (!locked && entries.isNotEmpty && r != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _submit(r, withoutNotes),
                icon: const Icon(Icons.send),
                label: const Padding(padding: EdgeInsets.all(12), child: Text('Submit report to Head of Education')),
              ),
              const SizedBox(height: 6),
              Text('Due ${fmtDateY(d.semester!.reportDeadline)}. Late reports are paid at the end of next semester.',
                  textAlign: TextAlign.center, style: t.textTheme.bodySmall),
            ],
            const SizedBox(height: 72),
          ]),
          if (!locked)
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.extended(
                onPressed: () async {
                  if (await showLogTimeSheet(context, d)) _reload();
                },
                icon: const Icon(Icons.add),
                label: const Text('Log time'),
              ),
            ),
        ]);
      },
    );
  }
}

/// Icon and colour for each kind of activity
(IconData, Color) activityLook(String a) => switch (a) {
      'council_meeting' => (Icons.account_balance_outlined, Colors.indigo),
      'siec_meeting' => (Icons.groups_outlined, Colors.purple),
      'preparation' => (Icons.menu_book_outlined, Colors.teal),
      'student_input' => (Icons.record_voice_over_outlined, Colors.orange.shade800),
      'class_visit' => (Icons.co_present_outlined, Colors.blue),
      'teams_email' => (Icons.mail_outline, Colors.cyan.shade700),
      'materials' => (Icons.slideshow_outlined, Colors.pink),
      'task' => (Icons.assignment_outlined, Colors.brown),
      _ => (Icons.more_horiz, Colors.blueGrey),
    };

/// Draft → Submitted → Approved → Paid, with "Returned" shown on the second step.
class ReportSteps extends StatelessWidget {
  final String status;
  const ReportSteps({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final returned = status == 'returned';
    final at = switch (status) { 'submitted' || 'returned' => 1, 'approved' => 2, 'paid' => 3, _ => 0 };
    final steps = ['Draft', returned ? 'Returned' : 'Submitted', 'Approved', 'Paid'];
    Widget dot(int i) {
      final done = i < at || (i == at && i == 3);
      final current = i == at && !done;
      final color = returned && i == 1 ? Colors.orange.shade800 : t.colorScheme.primary;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done || current ? color : t.colorScheme.surfaceContainerHighest,
          border: current ? Border.all(color: color.withValues(alpha: 0.35), width: 4) : null,
        ),
        child: Icon(
          done ? Icons.check : (returned && i == 1 ? Icons.undo : Icons.circle),
          size: done || (returned && i == 1) ? 16 : 7,
          color: done || current ? Colors.white : t.colorScheme.outline,
        ),
      );
    }

    return Column(children: [
      Row(children: [
        for (var i = 0; i < 4; i++) ...[
          dot(i),
          if (i < 3)
            Expanded(
              child: Container(
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: i < at ? t.colorScheme.primary : t.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ]),
      const SizedBox(height: 6),
      Row(children: [
        for (var i = 0; i < 4; i++)
          Expanded(
            child: Text(steps[i],
                textAlign: i == 0 ? TextAlign.start : (i == 3 ? TextAlign.end : TextAlign.center),
                style: t.textTheme.labelSmall?.copyWith(
                    fontWeight: i == at ? FontWeight.bold : null,
                    color: returned && i == 1 ? Colors.orange.shade800 : null)),
          ),
      ]),
    ]);
  }
}

/// Lets the user pick a file (photo, PDF, Word) and attaches it to an entry.
Future<bool> pickAndUploadNote(BuildContext context, String entryId) async {
  final res = await FilePicker.platform.pickFiles(withData: true);
  final f = res?.files.single;
  if (f == null || f.bytes == null) return false;
  return runAction(context, () => Repo.uploadNote(entryId: entryId, fileName: f.name, bytes: f.bytes!),
      success: 'Notes attached');
}

/// Bottom sheet to log an activity. Returns true when saved.
Future<bool> showLogTimeSheet(BuildContext context, RepData d, {String? meetingId}) async {
  // A submitted report is locked: explain instead of opening a form that cannot be saved
  final report = await Repo.myReport();
  if (!context.mounted) return false;
  if (report != null && report.isLocked) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your time report is already sent'),
        content: Text('Your report for ${d.semester?.name ?? 'this semester'} is '
            '${(reportStatusLabels[report.status] ?? report.status).toLowerCase()}, so new hours cannot be added. '
            'If you forgot something, ask the Head of Education to return the report to you.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
    return false;
  }
  // Only meetings the rep said they attend (or was added to by the Head of Education)
  final attending = (await Repo.myAttendance())..removeWhere((_, mode) => mode == 'absent');
  final meetings = (await Repo.meetings()).where((m) => attending.containsKey(m.id)).toList();
  if (!context.mounted) return false;
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _LogTimeForm(data: d, meetings: meetings, meetingId: meetingId),
    ),
  );
  return saved ?? false;
}

class _LogTimeForm extends StatefulWidget {
  final RepData data;
  final List<Meeting> meetings;
  final String? meetingId;
  const _LogTimeForm({required this.data, required this.meetings, this.meetingId});
  @override
  State<_LogTimeForm> createState() => _LogTimeFormState();
}

class _LogTimeFormState extends State<_LogTimeForm> {
  late DateTime _date = DateTime.now();
  TimeOfDay _start = const TimeOfDay(hour: 9, minute: 0);
  String _activity = 'council_meeting';
  String? _council;
  String? _meeting;
  int _minutes = 60;
  final _desc = TextEditingController();
  PlatformFile? _file;
  bool _busy = false;
  String? _error; // shown inside the sheet (a snackbar would be hidden behind it)

  @override
  void initState() {
    super.initState();
    _council = null; // optional: not all work belongs to a council
    final m = widget.meetings.where((m) => m.id == widget.meetingId).toList();
    if (m.isNotEmpty) {
      _meeting = m.first.id;
      _council = m.first.councilId;
      _date = m.first.startsAt;
      _start = TimeOfDay.fromDateTime(m.first.startsAt);
      _desc.text = m.first.title;
      _minutes = 120;
      _activity = (widget.data.council(m.first.councilId)?.isSiec ?? false) ? 'siec_meeting' : 'council_meeting';
    }
  }

  Future<void> _customDuration() async {
    final h = TextEditingController(text: '${_minutes ~/ 60}');
    final m = TextEditingController(text: '${_minutes % 60}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('How long?'),
        content: Row(children: [
          Expanded(
              child: TextField(
                  controller: h, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Hours'))),
          const SizedBox(width: 10),
          Expanded(
              child: TextField(
                  controller: m,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Minutes'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    if (ok != true) return;
    final total = (int.tryParse(h.text) ?? 0) * 60 + (int.tryParse(m.text) ?? 0);
    if (total <= 0 || total > 720) return setState(() => _error = 'Enter between 1 minute and 12 hours');
    setState(() => _minutes = total);
  }

  Future<void> _save() async {
    if (_activity == 'other' && _desc.text.trim().isEmpty) {
      return setState(() => _error = 'Describe what you did');
    }
    if ((_activity == 'council_meeting' || _activity == 'siec_meeting') && _meeting == null) {
      return setState(() => _error = 'Choose the meeting. Only meetings you signed up for are listed – '
          'if you were there without signing up, ask the Head of Education to add you.');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await Repo.addEntry(
        date: _date,
        activity: _activity,
        councilId: _council,
        meetingId: _meeting,
        minutes: _minutes,
        description: _desc.text.trim(),
        startTime: '${_start.hour.toString().padLeft(2, '0')}:${_start.minute.toString().padLeft(2, '0')}',
      );
      if (_file?.bytes != null) {
        await Repo.uploadNote(entryId: id, fileName: _file!.name, bytes: Uint8List.fromList(_file!.bytes!));
      }
      if (mounted) {
        showSnack(context, '${fmtMinutes(_minutes)} logged');
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final pastMeetings =
        widget.meetings.where((m) => m.isPast && (_council == null || m.councilId == _council)).toList().reversed;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Log time', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.event),
              label: Text(fmtDateY(_date)),
              onPressed: () async {
                final first = d.semester?.startsOn ?? DateTime(2020);
                final p = await showDatePicker(
                    context: context,
                    initialDate: _date.isBefore(first) ? first : _date,
                    firstDate: first,
                    lastDate: DateTime.now());
                if (p != null) setState(() => _date = p);
              },
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.schedule),
            label: Text('From ${_start.format(context)}'),
            onPressed: () async {
              final p = await showTimePicker(context: context, initialTime: _start);
              if (p != null) setState(() => _start = p);
            },
          ),
        ]),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _activity,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'What did you do?'),
          items: [
            for (final e in activityLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) => setState(() => _activity = v ?? _activity),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          value: _council,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Council (optional)'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('No specific council')),
            for (final c in d.myCouncils) DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
          ],
          onChanged: (v) => setState(() {
            _council = v;
            _meeting = null;
          }),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          value: _meeting,
          isExpanded: true,
          decoration: InputDecoration(
              labelText: _activity == 'council_meeting' || _activity == 'siec_meeting' ? 'Meeting' : 'Meeting (optional)',
              helperText: 'Only meetings you signed up for',
          ),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('—')),
            for (final m in pastMeetings)
              DropdownMenuItem<String?>(value: m.id, child: Text('${m.title} · ${fmtDate(m.startsAt)}')),
          ],
          onChanged: (v) => setState(() => _meeting = v),
        ),
        const SizedBox(height: 12),
        Text('Duration: ${fmtMinutes(_minutes)}'),
        Wrap(spacing: 6, children: [
          for (final m in const [15, 30, 60, 90, 120, 150, 180, 240])
            ChoiceChip(
              label: Text(fmtMinutes(m)),
              selected: _minutes == m,
              onSelected: (_) => setState(() => _minutes = m),
            ),
          ActionChip(
            avatar: const Icon(Icons.edit, size: 16),
            label: const Text('Other…'),
            onPressed: _customDuration,
          ),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _desc,
          maxLines: 2,
          decoration: InputDecoration(
            labelText: _activity == 'other' ? 'Description (required)' : 'Description',
            hintText: 'e.g. Made a survey about the exam schedule',
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.attach_file),
          label: Text(_file?.name ?? 'Attach meeting notes (needed for payment)'),
          onPressed: () async {
            final r = await FilePicker.platform.pickFiles(withData: true);
            if (r != null) setState(() => _file = r.files.single);
          },
        ),
        const SizedBox(height: 8),
        Text(
          'Log any work for your role – meetings, preparing material, tasks, student input. '
          'Does not count: chats not about education, travel time without work, '
          'association meetings not about student influence.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
            child: Text(_error!, style: TextStyle(color: Colors.red.shade900)),
          ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _busy
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save'),
          ),
        ),
      ]),
    );
  }
}
