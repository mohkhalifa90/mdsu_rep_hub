import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import 'format.dart';
import 'interactions.dart';
import 'widgets.dart';

/// Log an issue raised in a council meeting (SIEC protocol 4.4).
Future<bool> showAddIssueDialog(BuildContext context, {required List<Council> councils}) async {
  // SIEC first (most meetings are SIEC), then A–Z
  councils = [...councils]..sort((a, b) {
      if (a.isSiec != b.isSiec) return a.isSiec ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  if (councils.isEmpty) {
    showSnack(context, 'You are not a member of any council yet');
    return false;
  }
  final meetings = await Repo.meetings();
  if (!context.mounted) return false;
  String council = councils.first.id;
  String? meeting;
  final title = TextEditingController(), details = TextEditingController(), resp = TextEditingController();
  // the dialog closes with: true = post update, 'edit' / 'delete' = change the issue itself
  final ok = await showDialog<Object>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      final past = meetings.where((m) => m.isPast && m.councilId == council).toList().reversed.toList();
      return AlertDialog(
        title: const Text('Log an issue raised in a meeting'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // type a few letters to filter the list
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
                onSelected: (v) => setD(() {
                  if (v == null) return;
                  council = v;
                  meeting = null;
                }),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String?>(
                value: meeting,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Raised at meeting'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('—')),
                  for (final m in past)
                    DropdownMenuItem<String?>(value: m.id, child: Text('${m.title} · ${fmtDate(m.startsAt)}')),
                ],
                onChanged: (v) => setD(() => meeting = v),
              ),
              const SizedBox(height: 10),
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Issue')),
              const SizedBox(height: 10),
              TextField(
                  controller: details,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Details / what was promised')),
              const SizedBox(height: 10),
              TextField(
                  controller: resp,
                  decoration: const InputDecoration(labelText: 'Responsible at the university (e.g. program coordinator)')),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      );
    }),
  );
  if (ok != true || title.text.trim().isEmpty || !context.mounted) return false;
  return runAction(
    context,
    () => Repo.addIssue(
      councilId: council,
      meetingId: meeting,
      title: title.text.trim(),
      details: details.text.trim(),
      responsible: resp.text.trim().isEmpty ? null : resp.text.trim(),
    ),
    success: 'Tracked – it will be on the next agenda automatically',
  );
}

/// Record the university's answer or change status. Reps may only set "answered".
/// A follow-up as a thread: the issue as it was written (never changed), every update under it
/// (who, status, note), and a box at the bottom to add a new update.
bool _issueDialogBusy = false; // a second tap while it loads must not open a second dialog

Future<bool> showIssueUpdateDialog(BuildContext context, Issue issue, {required bool officer}) async {
  if (_issueDialogBusy) return false;
  _issueDialogBusy = true;
  try {
    return await _issueDialog(context, issue, officer: officer);
  } finally {
    _issueDialogBusy = false;
  }
}

Future<bool> _issueDialog(BuildContext context, Issue issue, {required bool officer}) async {
  // load everything at once
  final loaded = await Future.wait<Object>([
    Repo.issueEvents(issue.id),
    Repo.memberNames(),
    Repo.canChangeIssue(issue.id).catchError((_) => false),
  ]);
  final events = (loaded[0] as List<Map<String, dynamic>>).reversed.toList(); // oldest first, like a conversation
  final names = loaded[1] as Map<String, String>;
  final canChange = loaded[2] as bool;
  if (!context.mounted) return false;
  String status = issue.status;
  final note = TextEditingController();
  final allowed = officer ? issueStatusLabels.keys.toList() : ['awaiting', 'answered'];
  if (!allowed.contains(status)) allowed.add(status);
  final t = Theme.of(context);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        final changed = status != issue.status || note.text.trim().isNotEmpty;
        return AlertDialog(
          title: Text(issue.title),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                // ---- the issue, as written ----
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                          'Raised by ${names[issue.raisedBy] ?? '?'} \u00b7 ${fmtDateTime(issue.createdAt)}'
                          '${(issue.responsible ?? '').isEmpty ? '' : ' \u00b7 responsible: ${issue.responsible}'}'
                          '${issue.editedAt != null ? ' \u00b7 edited' : ''}',
                          style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                        ),
                      ),
                      if (canChange)
                        EditDeleteMenu(
                          canEdit: true,
                          canDelete: true,
                          onEdit: () => Navigator.pop(ctx, 'edit'),
                          onDelete: () => Navigator.pop(ctx, 'delete'),
                        ),
                    ]),
                    const SizedBox(height: 4),
                    Text(issue.details.isEmpty ? issue.title : issue.details, style: t.textTheme.bodyMedium),
                  ]),
                ),
                const SizedBox(height: 12),
                Text('Updates', style: t.textTheme.titleSmall),
                const SizedBox(height: 4),
                if (events.where((e) => e['event'] != 'Issue logged').isEmpty)
                  Text('No updates yet', style: t.textTheme.bodySmall)
                else
                  // long histories scroll here, so the update box below stays in view
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: SingleChildScrollView(
                      reverse: true, // start at the newest
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (final e in events)
                          if (e['event'] != 'Issue logged') _historyLine(ctx, e, names),
                      ]),
                    ),
                  ),
                const Divider(height: 24),
                // ---- add an update ----
                Text('Add an update', style: t.textTheme.titleSmall),
                const SizedBox(height: 8),
                TextField(
                  controller: note,
                  maxLines: 3,
                  onChanged: (_) => setD(() {}),
                  decoration: const InputDecoration(
                    labelText: 'What did the university say, or what happened?',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 10),
                Text('Status', style: t.textTheme.labelMedium),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final s in allowed)
                    ChoiceChip(
                      label: Text(issueStatusLabels[s] ?? s),
                      selected: status == s,
                      onSelected: (_) => setD(() => status = s),
                    ),
                ]),
                if (officer && issue.status == 'closed')
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Closed by mistake? Pick another status to open it again.',
                        style: t.textTheme.bodySmall),
                  ),
                if (!officer)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Only the Head of Education can escalate or close a follow-up.',
                        style: t.textTheme.bodySmall),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Close')),
            FilledButton(
              onPressed: changed ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Post update'),
            ),
          ],
        );
      },
    ),
  );
  if (!context.mounted) return false;
  if (ok == 'edit') return _editIssue(context, issue);
  if (ok == 'delete') {
    if (!await confirm(context, 'Delete this follow-up?', '“${issue.title}” and all its updates are deleted.',
        ok: 'Delete')) {
      return false;
    }
    if (!context.mounted) return false;
    return runAction(context, () => Repo.deleteIssue(issue.id), success: 'Follow-up deleted');
  }
  if (ok != true) return false;
  final text = note.text.trim();
  return runAction(
    context,
    // an empty note keeps the last answer; a new note becomes the latest answer shown in the list
    () => Repo.setIssueStatus(issue.id, status, response: text.isEmpty ? null : text),
    success: 'Update posted – council members are notified',
  );
}

/// Change the issue itself (its text, details and who is responsible)
Future<bool> _editIssue(BuildContext context, Issue issue) async {
  final title = TextEditingController(text: issue.title);
  final details = TextEditingController(text: issue.details);
  final resp = TextEditingController(text: issue.responsible ?? '');
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Edit follow-up'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: title, decoration: const InputDecoration(labelText: 'Issue')),
          const SizedBox(height: 10),
          TextField(
              controller: details,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Details / what was promised', alignLabelWithHint: true)),
          const SizedBox(height: 10),
          TextField(controller: resp, decoration: const InputDecoration(labelText: 'Responsible at the university')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  return runAction(
      context,
      () => Repo.editIssue(issue.id,
          title: title.text, details: details.text, responsible: resp.text.trim().isEmpty ? null : resp.text),
      success: 'Follow-up updated');
}

/// One line of a follow-up's history: when, who, the status and the answer
Widget _historyLine(BuildContext context, Map<String, dynamic> e, Map<String, String> names) {
  final t = Theme.of(context);
  // older lines may hold a garbled dash; show it right
  final text = (e['event'] as String? ?? '').replaceAll('\u00e2\u20ac\u201c', '\u2013').replaceAll('\u00e2\u20ac\u0093', '\u2013');
  final who = names[e['actor']] ?? '';
  String? status;
  var answer = '';
  if (text.startsWith('Status: ')) {
    final rest = text.substring(8);
    final i = rest.indexOf(' \u2013 ');
    status = i < 0 ? rest : rest.substring(0, i);
    answer = i < 0 ? '' : rest.substring(i + 3);
  }
  final color = switch (status) {
    'answered' => Colors.green.shade700,
    'escalated' => Colors.red.shade700,
    'closed' => Colors.blueGrey,
    _ => Colors.orange.shade800,
  };
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Icon(Icons.circle, size: 8, color: status == null ? t.colorScheme.outline : color),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            '${fmtDateTime(DateTime.parse(e['at'] as String).toLocal())}${who.isEmpty ? '' : ' \u00b7 $who'}',
            style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
          if (status == null)
            Text(text, style: t.textTheme.bodySmall)
          else
            Text.rich(TextSpan(children: [
              TextSpan(
                  text: issueStatusLabels[status] ?? status,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600)),
              if (answer.isNotEmpty) TextSpan(text: ': $answer'),
            ]), style: t.textTheme.bodySmall),
        ]),
      ),
    ]),
  );
}
