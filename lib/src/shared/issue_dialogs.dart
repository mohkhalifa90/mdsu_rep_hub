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
              const SizedBox(height: 8),
              for (final e in events)
                Text('${fmtDateTime(DateTime.parse(e['at'] as String).toLocal())} – ${e['event']}',
                    style: Theme.of(ctx).textTheme.bodySmall),
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
  return runAction(
    context,
    () => Repo.setIssueStatus(issue.id, status, response: response.text.trim().isEmpty ? null : response.text.trim()),
    success: 'Updated – council members are notified',
  );
}
