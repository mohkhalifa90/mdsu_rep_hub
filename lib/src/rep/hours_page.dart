import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

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
        return Stack(children: [
          ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('${fmtHours(minutes)} h',
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    StatusChip.report(r?.status ?? 'draft'),
                  ]),
                  Text('$halves started half hours × ${d.semester!.halfHourRate} SEK = '
                      '${sek(d.me.isMember ? halves * d.semester!.halfHourRate : 0)}'),
                  Text('Each activity is rounded up to started half hours, like the Excel time report.',
                      style: Theme.of(context).textTheme.bodySmall),
                  if (r?.status == 'returned' && (r?.reviewerComment ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('Returned: ${r!.reviewerComment}', style: TextStyle(color: Colors.orange.shade900)),
                    ),
                  if (!d.me.isMember)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('You are not a union member, so hours are not paid. Become a member at mdsu.se.',
                          style: TextStyle(color: Colors.red)),
                    ),
                  if (r != null && !r.hasPersonalNumber)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('Add your personal number (or samordningsnummer) under More → My profile to get paid.',
                          style: TextStyle(color: Colors.red)),
                    ),
                ]),
              ),
            ),
            if (locked)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Your report is submitted and locked until it is returned or the next semester starts.',
                    textAlign: TextAlign.center),
              ),
            if (entries.isEmpty) const EmptyState('No time logged yet. Tap “Log time” after each meeting.'),
            for (final e in entries)
              Card(
                child: ListTile(
                  title: Text(activityLabels[e.activity] ?? e.activity),
                  subtitle: Text('${fmtDate(e.workDate)}${e.fromText == null ? '' : ' · ${e.fromText}–${e.toText}'}'
                      ' · ${d.council(e.councilId)?.name ?? ''}\n${e.description}'),
                  isThreeLine: true,
                  leading: Icon(withNotes.contains(e.id) ? Icons.attach_file : Icons.warning_amber_outlined,
                      color: withNotes.contains(e.id) ? Colors.green : Colors.orange),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(fmtMinutes(e.minutes), style: const TextStyle(fontWeight: FontWeight.bold)),
                    if (!locked)
                      InkWell(
                        onTap: () async {
                          if (await confirm(context, 'Delete entry?', e.description, ok: 'Delete') &&
                              await runAction(context, () => Repo.deleteEntry(e.id))) {
                            _reload();
                          }
                        },
                        child: const Icon(Icons.delete_outline, size: 18),
                      ),
                  ]),
                  onTap: locked || withNotes.contains(e.id)
                      ? null
                      : () async {
                          if (await pickAndUploadNote(context, e.id)) _reload();
                        },
                ),
              ),
            if (!locked && entries.isNotEmpty && r != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _submit(r, withoutNotes),
                icon: const Icon(Icons.send),
                label: const Padding(padding: EdgeInsets.all(12), child: Text('Submit report to Head of Education')),
              ),
              const SizedBox(height: 6),
              Text('Due ${fmtDateY(d.semester!.reportDeadline)}. Late reports are paid at the end of next semester.',
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ],
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
  final meetings = await Repo.meetings();
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

  @override
  void initState() {
    super.initState();
    final mine = widget.data.myCouncils;
    _council = mine.isEmpty ? null : mine.first.id;
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

  Future<void> _save() async {
    setState(() => _busy = true);
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
      if (mounted) showSnack(context, errorText(e));
      setState(() => _busy = false);
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
        DropdownButtonFormField<String>(
          value: _council,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Council'),
          items: [for (final c in d.myCouncils) DropdownMenuItem(value: c.id, child: Text(c.name))],
          onChanged: (v) => setState(() {
            _council = v;
            _meeting = null;
          }),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          value: _meeting,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Meeting (optional)'),
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
        ]),
        const SizedBox(height: 12),
        TextField(controller: _desc, decoration: const InputDecoration(labelText: 'Description')),
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
          'Does not count: chats not about education, travel time without work, '
          'association meetings not about student influence.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Padding(padding: EdgeInsets.all(12), child: Text('Save')),
        ),
      ]),
    );
  }
}
