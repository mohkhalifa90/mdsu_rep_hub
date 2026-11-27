import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import 'format.dart';
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
  final ok = await showDialog<bool>(
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
Future<bool> showIssueUpdateDialog(BuildContext context, Issue issue, {required bool officer}) async {
  final events = await Repo.issueEvents(issue.id);
  final names = await Repo.memberNames();
  if (!context.mounted) return false;
  String status = issue.status;
  final response = TextEditingController(text: issue.response ?? '');
  final allowed = officer ? issueStatusLabels.keys.toList() : ['awaiting', 'answered'];
  if (!allowed.contains(status)) allowed.add(status);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(issue.title),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (issue.details.isNotEmpty) Text(issue.details),
              const SizedBox(height: 12),
              Text('History', style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 4),
              for (final e in events) _historyLine(ctx, e, names),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: [
                  for (final s in allowed) DropdownMenuItem(value: s, child: Text(issueStatusLabels[s] ?? s)),
                ],
                onChanged: (v) => setD(() => status = v ?? status),
              ),
              const SizedBox(height: 10),
              TextField(
                  controller: response,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: "University's response (written or verbal)")),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return false;
  final newResponse = response.text.trim().isEmpty ? null : response.text.trim();
  if (status == issue.status && newResponse == (issue.response?.trim().isEmpty ?? true ? null : issue.response!.trim())) {
    return false; // nothing changed – no history line, no notification
  }
  return runAction(
    context,
    () => Repo.setIssueStatus(issue.id, status, response: newResponse),
    success: 'Updated – council members are notified',
  );
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
