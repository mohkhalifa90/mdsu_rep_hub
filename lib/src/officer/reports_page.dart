import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/format.dart';
import '../shared/widgets.dart';
import 'excel_export.dart';
import 'officer_shell.dart';

/// All time reports by name, with pay calculated by the database.
class ReportsPage extends StatefulWidget {
  final OfficerData data;
  const ReportsPage({super.key, required this.data});
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  late Future<List<ReportRow>> _f = Repo.reportOverview();
  ReportRow? _sel;

  void _reload() => setState(() {
        _f = Repo.reportOverview();
        _sel = null;
      });

  Future<void> _downloadExcel() async {
    final s = widget.data.semester;
    if (s == null) return showSnack(context, 'No active semester');
    try {
      final where = await exportPayrollXlsx(semester: s, councils: widget.data.councils);
      if (mounted && where != null) showSnack(context, 'Saved: $where');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _exportPayroll() async {
    try {
      final rows = await Repo.payroll();
      final header = 'Name;Personal number;Program;Member;Status;Hours;Started half hours;Amount SEK';
      final lines = rows.map((r) => [
            r['full_name'],
            r['personal_number'] ?? 'MISSING',
            r['program'] ?? '',
            r['is_member'] == true ? 'yes' : 'no',
            r['status'],
            r['hours'],
            r['started_half_hours'],
            r['amount'],
          ].join(';'));
      final csv = [header, ...lines].join('\n');
      await Clipboard.setData(ClipboardData(text: csv));
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Payroll export'),
          content: SizedBox(
            width: 640,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Copied to the clipboard. Paste into Excel (cell A1) – columns split on “;”.'),
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxHeight: 320),
                padding: const EdgeInsets.all(8),
                color: const Color(0xFFF4F4F7),
                child: SingleChildScrollView(child: SelectableText(csv, style: const TextStyle(fontFamily: 'monospace'))),
              ),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ),
      );
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _review(ReportRow r, String action) async {
    String? comment;
    if (action == 'return') {
      comment = await promptText(context,
          title: 'Return report to ${r.fullName}',
          label: 'Comment',
          initial: 'Please attach your meeting notes for all council meetings.',
          maxLines: 3);
      if (comment == null) return;
    }
    if (await runAction(context, () => Repo.reviewReport(r.reportId!, action, comment: comment),
        success: 'Updated – ${r.fullName} is notified')) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Loader<List<ReportRow>>(
      future: _f,
      onRetry: _reload,
      builder: (context, rows) {
        final submitted = rows.where((r) => r.isDone).toList();
        return ListView(padding: const EdgeInsets.all(24), children: [
          Row(children: [
            Expanded(
              child: Text(
                  'Reps log hours in the app and press Submit. Reports arrive here by name; pay is calculated automatically.',
                  style: Theme.of(context).textTheme.bodyMedium),
            ),
            TextButton.icon(
                onPressed: _exportPayroll, icon: const Icon(Icons.copy), label: const Text('Copy for Excel')),
            const SizedBox(width: 8),
            FilledButton.icon(
                onPressed: _downloadExcel,
                icon: const Icon(Icons.download),
                label: const Text('Download Excel (.xlsx)')),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            Kpi(label: 'Awaiting your review', value: '${rows.where((r) => r.status == 'submitted').length}'),
            Kpi(label: 'Hours in submitted reports',
                value: '${fmtHours(submitted.fold<int>(0, (a, r) => a + r.minutes))} h'),
            Kpi(label: 'Amount in submitted reports', value: sek(submitted.fold<int>(0, (a, r) => a + r.amount))),
          ]),
          const SizedBox(height: 12),
          Card(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                showCheckboxColumn: false,
                columns: const [
                  DataColumn(label: Text('Representative')),
                  DataColumn(label: Text('Status')),
                  DataColumn(label: Text('Member')),
                  DataColumn(label: Text('Entries'), numeric: true),
                  DataColumn(label: Text('Hours'), numeric: true),
                  DataColumn(label: Text('Amount'), numeric: true),
                  DataColumn(label: Text('Documentation')),
                ],
                rows: [
                  for (final r in rows)
                    DataRow(
                      selected: _sel?.userId == r.userId,
                      onSelectChanged: (_) => setState(() => _sel = r),
                      cells: [
                        DataCell(Text(r.fullName)),
                        DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                          StatusChip.report(r.status),
                          if (r.isLate) const Padding(padding: EdgeInsets.only(left: 6), child: Text('late')),
                        ])),
                        DataCell(Text(r.isMember ? (r.hasPersonalNumber ? 'yes' : 'yes – no pers. no.') : 'NOT member')),
                        DataCell(Text('${r.entries}')),
                        DataCell(Text(fmtHours(r.minutes))),
                        DataCell(Text(sek(r.amount))),
                        DataCell(r.entriesWithoutNotes == 0
                            ? const Text('Notes ✓')
                            : Text('${r.entriesWithoutNotes} without notes',
                                style: TextStyle(color: Colors.orange.shade900))),
                      ],
                    ),
                ],
              ),
            ),
          ),
          if (_sel != null) _ReportDetail(key: ValueKey(_sel!.userId), row: _sel!, data: widget.data, onReview: _review),
        ]);
      },
    );
  }
}

class _ReportDetail extends StatelessWidget {
  final ReportRow row;
  final OfficerData data;
  final Future<void> Function(ReportRow, String) onReview;
  const _ReportDetail({super.key, required this.row, required this.data, required this.onReview});

  Future<(List<TimeEntry>, List<Attachment>)> _load() async {
    final e = await Repo.entries(userId: row.userId, semesterId: data.semester!.id);
    return (e, await Repo.attachments(e.map((x) => x.id).toList()));
  }

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(top: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('${row.fullName} – time report', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 12),
              StatusChip.report(row.status),
              const Spacer(),
              if (row.status == 'submitted') ...[
                OutlinedButton.icon(
                    onPressed: () => onReview(row, 'return'),
                    icon: const Icon(Icons.undo),
                    label: const Text('Return with comment')),
                const SizedBox(width: 8),
                FilledButton.icon(
                    onPressed: () => onReview(row, 'approve'), icon: const Icon(Icons.check), label: const Text('Approve')),
              ],
              if (row.status == 'approved')
                FilledButton(onPressed: () => onReview(row, 'paid'), child: const Text('Mark as paid')),
            ]),
            if (!row.isMember)
              const Text('Not a union member – hours are recorded but not paid (Handbook §5).',
                  style: TextStyle(color: Colors.red)),
            if (data.semester == null)
              const EmptyState('No active semester')
            else
              Loader<(List<TimeEntry>, List<Attachment>)>(
                future: _load(),
                builder: (context, d) {
                  final (entries, notes) = d;
                  if (entries.isEmpty) return const EmptyState('No entries');
                  return Column(children: [
                    for (final e in entries)
                      ListTile(
                        dense: true,
                        title: Text('${fmtDate(e.workDate)} · ${activityLabels[e.activity] ?? e.activity}'),
                        subtitle: Text('${data.council(e.councilId)?.name ?? ''} · ${e.description}'),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          for (final n in notes.where((n) => n.entryId == e.id))
                            IconButton(
                              tooltip: n.fileName,
                              icon: const Icon(Icons.attach_file),
                              onPressed: () async {
                                final url = await Repo.noteUrl(n.storagePath);
                                await launchUrl(Uri.parse(url));
                              },
                            ),
                          const SizedBox(width: 8),
                          Text(fmtMinutes(e.minutes), style: const TextStyle(fontWeight: FontWeight.bold)),
                        ]),
                      ),
                    const Divider(),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        'Total ${fmtHours(row.minutes)} h → ${row.halfHours} started half hours (per activity) × '
                        '${data.semester!.halfHourRate} SEK = ${sek(row.amount)}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ]);
                },
              ),
          ]),
        ),
      );
}
