import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/charts.dart';
import '../shared/format.dart';
import '../shared/send_message.dart';
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
  String _filter = 'all'; // all | notyet | submitted | approved | paid
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static bool _inFilter(ReportRow r, String f) => switch (f) {
        'notyet' => r.status == 'draft' || r.status == 'returned',
        'done' => r.isDone, // submitted, approved or paid
        'submitted' => r.status == 'submitted',
        'approved' => r.status == 'approved',
        'paid' => r.status == 'paid',
        _ => true,
      };

  void _setFilter(String f) => setState(() => _filter = _filter == f ? 'all' : f);

  /// Everyone who has not submitted gets a notification
  Future<void> _remind() async {
    if (!await confirm(context, 'Send reminder?',
        'Every representative who has not submitted their time report gets a notification.',
        ok: 'Send')) {
      return;
    }
    if (!mounted) return;
    await runAction(context, () async {
      final n = await Repo.remindUnsubmitted();
      if (mounted) showSnack(context, 'Reminder sent to $n representatives');
    });
  }

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
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
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
    if (action == 'paid_message') return _paidMessage(r); // only the message again
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
      if (action == 'paid' && mounted) await _paidMessage(r);
    }
  }

  /// "Your report is paid" with the payslip link – ready to copy, email (Outlook) or send in Teams.
  Future<void> _paidMessage(ReportRow r) async {
    final (url, label) = await Repo.payslipLink();
    final email = await Repo.emailOf(r.userId);
    if (!mounted) return;
    final sem = widget.data.semester?.name ?? '';
    await showSendMessage(
      context,
      title: 'Paid ✓ – tell ${r.fullName.split(' ').first}',
      intro: '${r.fullName} got a notification in the app. You can also send this:',
      email: email,
      subject: 'MDSU – your time report is paid',
      message: 'Hi ${r.fullName.split(' ').first}! Your time report${sem.isEmpty ? '' : ' for $sem'} has been paid'
          '${r.amount > 0 ? ' (${sek(r.amount)})' : ''}. Thank you for your work as a student representative!'
          '${url == null ? '' : '\nYou can see your payslip in $label: $url'}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader<List<ReportRow>>(
      future: _f,
      onRetry: _reload,
      builder: (context, rows) {
        final submitted = rows.where((r) => r.isDone).toList();
        int count(String f) => rows.where((r) => _inFilter(r, f)).length;
        final q = _search.text.trim().toLowerCase();
        final shown = rows.where((r) => _inFilter(r, _filter) && (q.isEmpty || r.fullName.toLowerCase().contains(q))).toList();
        return ListView(padding: EdgeInsets.all(isNarrow(context) ? 12 : 24), children: [
          PageIntro(
            text: 'Reps log hours in the app and press Submit. Reports arrive here by name; pay is calculated automatically.',
            actions: [
              TextButton.icon(
                  onPressed: _exportPayroll, icon: const Icon(Icons.copy), label: const Text('Copy for Excel')),
              FilledButton.icon(
                  onPressed: _downloadExcel,
                  icon: const Icon(Icons.download),
                  label: const Text('Download Excel (.xlsx)')),
            ],
          ),
          const SizedBox(height: 12),
          _Steps(rows: rows, selected: _filter, onTap: _setFilter),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DonutCard(
              title: 'Time reports',
              center: '${submitted.length}\nof ${rows.length}',
              slices: [
                Slice('Not submitted', count('notyet'), Colors.grey.shade400),
                Slice('To review', count('submitted'), Colors.orange.shade600),
                Slice('Approved', count('approved'), Colors.blue.shade500),
                Slice('Paid', count('paid'), Colors.green.shade600),
              ],
            ),
            if (widget.data.semester != null)
              Kpi(
                  icon: Icons.alarm,
                  color: Colors.red.shade700,
                  label: 'Days to deadline',
                  value: '${daysUntil(widget.data.semester!.reportDeadline)}',
                  sub: fmtDateY(widget.data.semester!.reportDeadline)),
            Kpi(
                icon: Icons.edit_note,
                color: Colors.blueGrey,
                label: 'Draft – not submitted yet',
                value: '${count('notyet')}',
                sub: 'Tap to list them',
                selected: _filter == 'notyet',
                onTap: () => _setFilter('notyet')),
            Kpi(
                icon: Icons.send_outlined,
                color: Colors.blue.shade700,
                label: 'Submitted',
                value: '${submitted.length} of ${rows.length}',
                sub: 'incl. approved and paid',
                selected: _filter == 'done',
                onTap: () => _setFilter('done')),
            Kpi(
                icon: Icons.fact_check_outlined,
                color: Colors.orange.shade800,
                label: 'Awaiting your review',
                value: '${count('submitted')}',
                selected: _filter == 'submitted',
                onTap: () => _setFilter('submitted')),
            Kpi(icon: Icons.schedule, color: Colors.indigo, label: 'Hours submitted',
                value: '${fmtHours(submitted.fold<int>(0, (a, r) => a + r.minutes))} h'),
            Kpi(icon: Icons.payments_outlined, color: Colors.teal, label: 'Amount submitted', value: sek(submitted.fold<int>(0, (a, r) => a + r.amount))),
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SizedBox(
              width: 260,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search representative',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _search.clear())),
                ),
              ),
            ),
            for (final (f, label) in const [
              ('all', 'All'),
              ('notyet', 'Draft / returned'),
              ('done', 'Submitted (all)'),
              ('submitted', 'To review'),
              ('approved', 'Approved'),
              ('paid', 'Paid'),
            ])
              ChoiceChip(
                label: Text('$label (${count(f)})'),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
            if (count('notyet') > 0)
              FilledButton.tonalIcon(
                onPressed: _remind,
                icon: const Icon(Icons.notifications_active_outlined),
                label: Text('Send reminder to ${count('notyet')}'),
              ),
          ]),
          const SizedBox(height: 8),
          Card(
            child: shown.isEmpty
                ? const Padding(padding: EdgeInsets.all(24), child: EmptyState('Nobody matches'))
                : SingleChildScrollView(
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
                  DataColumn(label: Text('Next step')),
                ],
                rows: [
                  for (final r in shown)
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
                        DataCell(_nextStep(r.status)),
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
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('${row.fullName} – time report', style: Theme.of(context).textTheme.titleMedium),
              StatusChip.report(row.status),
              if (row.status == 'submitted') ...[
                OutlinedButton.icon(
                    onPressed: () => onReview(row, 'return'),
                    icon: const Icon(Icons.undo),
                    label: const Text('Return with comment')),
                FilledButton.icon(
                    onPressed: () => onReview(row, 'approve'), icon: const Icon(Icons.check), label: const Text('Approve')),
              ],
              if (row.status == 'approved')
                FilledButton(onPressed: () => onReview(row, 'paid'), child: const Text('Mark as paid')),
              if (row.status == 'paid')
                OutlinedButton.icon(
                    onPressed: () => onReview(row, 'paid_message'),
                    icon: const Icon(Icons.forward_to_inbox_outlined),
                    label: const Text('Payment message')),
            ]),
            if (row.status == 'draft' || row.status == 'returned')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    row.status == 'draft'
                        ? 'Draft – the representative is still logging hours. You can follow along here; '
                            'nothing to do until they press Submit.'
                        : 'Returned – waiting for the representative to fix it and submit again.',
                    style: TextStyle(color: Colors.blueGrey.shade700)),
              ),
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


/// What the Head of Education does next with a report in this status.
Widget _nextStep(String status) {
  final (text, color) = switch (status) {
    'submitted' => ('Review: open it, then approve or return', Colors.orange.shade900),
    'approved' => ('Send to payroll, then mark as paid', Colors.blue.shade800),
    'paid' => ('Done ✓', Colors.green.shade700),
    'returned' => ('Waiting for the rep to fix it', Colors.grey.shade700),
    _ => ('Waiting for the rep to submit', Colors.grey.shade700),
  };
  return Text(text, style: TextStyle(color: color, fontWeight: status == 'submitted' ? FontWeight.bold : null));
}

/// The way a time report goes, with how many reports are at each step.
class _Steps extends StatelessWidget {
  final List<ReportRow> rows;
  final String selected;
  final void Function(String filter) onTap;
  const _Steps({required this.rows, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    int n(String s) => rows.where((r) => r.status == s).length;
    final notYet = rows.where((r) => r.status == 'draft' || r.status == 'returned').length;
    // number, title, count text, icon, colour, filter, how many are waiting at this step
    final steps = [
      ('1', 'Reps submit', '$notYet not yet', Icons.send_outlined, Colors.blueGrey, 'notyet', notYet),
      ('2', 'You review', '${n('submitted')} waiting', Icons.fact_check_outlined, Colors.orange.shade800, 'submitted',
          n('submitted')),
      ('3', 'Download Excel for payroll', '${n('approved')} approved', Icons.download, Colors.blue.shade700, 'approved',
          n('approved')),
      ('4', 'Mark as paid', '${n('paid')} paid', Icons.payments_outlined, Colors.green.shade700, 'paid', n('paid')),
    ];
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 6, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (var i = 0; i < steps.length; i++) ...[
              Builder(builder: (context) {
                final (no, title, sub, icon, color, filter, waiting) = steps[i];
                final on = selected == filter;
                // a step with reports at it is coloured; the last step is "done" (green) rather than work to do
                final busy = waiting > 0;
                return InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onTap(filter),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: busy ? color.withValues(alpha: on ? 0.25 : 0.12) : t.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: on ? color : Colors.transparent, width: 2),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(icon, size: 18, color: busy ? color : t.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('$no. $title',
                            style: TextStyle(fontWeight: FontWeight.w600, color: busy ? color : null)),
                        Text(sub, style: t.textTheme.bodySmall),
                      ]),
                    ]),
                  ),
                );
              }),
              if (i < steps.length - 1) Icon(Icons.arrow_forward, size: 16, color: t.colorScheme.onSurfaceVariant),
            ],
          ]),
          const SizedBox(height: 8),
          Text('Click a step to show only those reports. Click a name in the table to see the hours and notes, then '
              'Approve or Return with a comment. '
              'After approving, download the Excel file for payroll and mark the reports as paid when the money is sent.',
              style: t.textTheme.bodySmall),
        ]),
      ),
    );
  }
}
