import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../data/roster.dart';
import '../shared/format.dart';
import '../shared/issue_dialogs.dart';
import '../shared/theme.dart';
import '../shared/tour.dart';
import '../shared/widgets.dart';
import 'officer_shell.dart';

// ============================ Follow-ups ===================================
class OfficerFollowUpsPage extends StatefulWidget {
  final OfficerData data;
  const OfficerFollowUpsPage({super.key, required this.data});
  @override
  State<OfficerFollowUpsPage> createState() => _OfficerFollowUpsPageState();
}

class _OfficerFollowUpsPageState extends State<OfficerFollowUpsPage> {
  late Future<(List<Issue>, Map<String, String>)> _f = _load();
  String _filter = 'open';
  Future<(List<Issue>, Map<String, String>)> _load() async => (await Repo.issues(), await Repo.memberNames());
  void _reload() => setState(() => _f = _load());

  @override
  Widget build(BuildContext context) {
    final s = widget.data.semester;
    return Loader<(List<Issue>, Map<String, String>)>(
      future: _f,
      onRetry: _reload,
      builder: (context, data) {
        final (issues, names) = data;
        final list = issues.where((i) => _filter == 'all' || (_filter == 'open' ? i.isOpen : i.status == _filter));
        return ListView(padding: EdgeInsets.all(isNarrow(context) ? 12 : 24), children: [
          PageIntro(
            text: 'Every issue raised in a council is tracked until the university answers. Open issues are '
                'carried to the next meeting and escalated after ${s?.escalateAfter ?? 2} meetings without an answer.',
            actions: [
            FilledButton.icon(
              onPressed: () async {
                if (await showAddIssueDialog(context,
                    councils: widget.data.councils)) {
                  _reload();
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('Log issue'),
            ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            Kpi(
                icon: Icons.loop,
                color: Colors.orange.shade800,
                label: 'Open follow-ups',
                value: '${issues.where((i) => i.isOpen).length}',
                selected: _filter == 'open',
                onTap: () => setState(() => _filter = 'open')),
            Kpi(
                icon: Icons.priority_high,
                color: Colors.red.shade700,
                label: 'Escalated',
                value: '${issues.where((i) => i.status == 'escalated').length}',
                sub: 'no answer for several meetings',
                selected: _filter == 'escalated',
                onTap: () => setState(() => _filter = 'escalated')),
            Kpi(
                icon: Icons.check_circle_outline,
                color: Colors.green.shade700,
                label: 'Answered',
                value: '${issues.where((i) => i.status == 'answered').length}',
                selected: _filter == 'answered',
                onTap: () => setState(() => _filter = 'answered')),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            for (final f in const [
              ('open', 'Open'),
              ('answered', 'Answered'),
              ('escalated', 'Escalated'),
              ('closed', 'Closed'),
              ('all', 'All')
            ])
              ChoiceChip(label: Text(f.$2), selected: _filter == f.$1, onSelected: (_) => setState(() => _filter = f.$1)),
          ]),
          const SizedBox(height: 12),
          if (list.isEmpty) const EmptyState('Nothing here'),
          for (final i in list)
            Card(
              child: ListTile(
                title: Text(i.title),
                subtitle: Text(
                  '${widget.data.council(i.councilId)?.name ?? ''} · responsible: ${i.responsible ?? '—'} · '
                  'raised by ${names[i.raisedBy] ?? ''} on ${fmtDate(i.createdAt)}'
                  '${(i.response ?? '').isEmpty ? '' : '\n↳ ${i.response}'}',
                ),
                isThreeLine: (i.response ?? '').isNotEmpty,
                trailing: StatusChip.issue(i.status),
                onTap: () async {
                  if (await showIssueUpdateDialog(context, i, officer: true)) _reload();
                },
              ),
            ),
        ]);
      },
    );
  }
}

// ============================ Representatives ==============================
class RepsPage extends StatefulWidget {
  final OfficerData data;
  final String? initialSearch; // from the quick search
  const RepsPage({super.key, required this.data, this.initialSearch});
  @override
  State<RepsPage> createState() => _RepsPageState();
}

class _RepsPageState extends State<RepsPage> {
  late Future<List<Profile>> _f = Repo.profiles();
  void _reload() => setState(() => _f = Repo.profiles());
  late final _search = TextEditingController(text: widget.initialSearch ?? '');
  String _filter = 'all'; // all | active | waiting | inactive

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _decide(Profile p, bool approve) async {
    if (await runAction(
        context,
        () => Repo.updateProfile(p.id, approve ? {'active': true} : {'approval': 'rejected'}),
        success: approve ? '${p.fullName} approved – set program and councils next' : '${p.fullName} rejected')) {
      _reload();
      if (approve && mounted) {
        final fresh = (await Repo.profiles()).where((x) => x.id == p.id).toList();
        if (fresh.isNotEmpty && mounted) _edit(fresh.first);
      }
    }
  }

  Future<void> _edit(Profile p) async {
    final d = widget.data;
    final name = TextEditingController(text: p.fullName), program = TextEditingController(text: p.program ?? '');
    String? academy = p.academy;
    int year = p.studyYear ?? 1;
    bool member = p.isMember, quiz = p.quizPassed, active = p.active;
    String role = p.role;
    final councils = await Repo.councilIdsOf(p.id);
    final email = (p.email ?? '').trim().toLowerCase();
    final seats = (await Repo.roster()).where((r) => r.email == email).toList();
    if (!mounted) return;
    final byId = {for (final c in d.councils) c.id: c};
    final now = DateTime.now();
    // the year comes from their programme cohort when there is one (the newest cohort counts)
    final cohorts = [
      for (final r in seats)
        if (byId[r.councilId]?.isProgramme == true && Cohort.parse(r.cohort) != null) Cohort.parse(r.cohort)!
    ]..sort((a, b) => b.compareTo(a));
    final autoYear = cohorts.isEmpty ? null : cohorts.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(p.fullName.isEmpty ? (p.email ?? '') : p.fullName),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                // ---- who is this: email, status, seats ----
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        const Icon(Icons.mail_outline, size: 18),
                        const SizedBox(width: 8),
                        Expanded(child: SelectableText(p.email ?? '—', style: Theme.of(ctx).textTheme.titleSmall)),
                        if (p.email != null) ...[
                          IconButton(
                            tooltip: 'Copy email',
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () async {
                              await Clipboard.setData(ClipboardData(text: p.email!));
                              if (ctx.mounted) showSnack(ctx, 'Email copied');
                            },
                          ),
                          IconButton(
                            tooltip: 'Send email',
                            icon: const Icon(Icons.forward_to_inbox, size: 18),
                            onPressed: () => launchUrl(Uri.parse('mailto:${p.email}')),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        if (p.waitingForApproval)
                          StatusChip('Waiting for approval', Colors.orange.shade800)
                        else if (p.approval == 'rejected')
                          StatusChip('Rejected', Colors.grey)
                        else
                          StatusChip(p.active ? 'Active' : 'Inactive', p.active ? Colors.green.shade700 : Colors.grey),
                        StatusChip(p.isMember ? 'Union member' : 'Not a member',
                            p.isMember ? Colors.green.shade700 : Colors.red.shade700),
                        StatusChip(p.quizPassed ? 'Quiz passed' : 'Quiz not passed',
                            p.quizPassed ? Colors.green.shade700 : Colors.orange.shade800),
                        if (p.createdAt != null) StatusChip('Account since ${fmtDate(p.createdAt!)}', Colors.blueGrey),
                      ]),
                      if (seats.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text('Seats', style: Theme.of(ctx).textTheme.labelLarge),
                        for (final r in seats)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('• ${byId[r.councilId]?.name ?? 'Council'}'
                                '${Cohort.parse(r.cohort) == null ? '' : ' – ${Cohort.parse(r.cohort)!.label}, year ${Cohort.parse(r.cohort)!.studyYear(now)}'}'
                                '${r.note == null ? '' : ' (${r.note})'}'),
                          ),
                      ],
                    ]),
                  ),
                ),
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name')),
                const SizedBox(height: 10),
                TextField(controller: program, decoration: const InputDecoration(labelText: 'Program')),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: academy,
                      decoration: const InputDecoration(labelText: 'Academy'),
                      items: const [
                        DropdownMenuItem<String?>(value: null, child: Text('—')),
                        DropdownMenuItem<String?>(value: 'EST', child: Text('EST')),
                        DropdownMenuItem<String?>(value: 'HVV', child: Text('HVV')),
                        DropdownMenuItem<String?>(value: 'IDT', child: Text('IDT')),
                        DropdownMenuItem<String?>(value: 'UKK', child: Text('UKK')),
                      ],
                      onChanged: (v) => setD(() => academy = v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: autoYear != null
                        // worked out from the cohort – moves up by itself every August (HT) / January (VT)
                        ? InputDecorator(
                            decoration: const InputDecoration(labelText: 'Year (automatic)'),
                            child: Text('${autoYear.studyYear(now)}  ·  ${autoYear.label}'),
                          )
                        : DropdownButtonFormField<int>(
                            value: year,
                            decoration: const InputDecoration(
                                labelText: 'Year', helperText: 'Set a cohort in Programmes & seats to make it automatic'),
                            items: [for (var y = 1; y <= 6; y++) DropdownMenuItem(value: y, child: Text('$y'))],
                            onChanged: (v) => setD(() => year = v ?? year),
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: role,
                      decoration: const InputDecoration(labelText: 'Role'),
                      items: const [
                        DropdownMenuItem(value: 'rep', child: Text('Representative')),
                        DropdownMenuItem(value: 'officer', child: Text('Head of Education')),
                        DropdownMenuItem(value: 'admin', child: Text('Admin')),
                      ],
                      onChanged: (v) => setD(() => role = v ?? role),
                    ),
                  ),
                ]),
                SwitchListTile(
                    title: const Text('Union member (paid)'), value: member, onChanged: (v) => setD(() => member = v)),
                SwitchListTile(
                    title: const Text('Quiz passed this semester'), value: quiz, onChanged: (v) => setD(() => quiz = v)),
                SwitchListTile(title: const Text('Active'), value: active, onChanged: (v) => setD(() => active = v)),
                const SizedBox(height: 8),
                Text('Councils (${councils.where((id) => byId[id]?.isSiec != true).length})',
                    style: Theme.of(ctx).textTheme.labelLarge),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final id in councils)
                    if (byId[id] != null && !byId[id]!.isSiec)
                      InputChip(
                        label: Text(byId[id]!.name, overflow: TextOverflow.ellipsis),
                        onDeleted: () => setD(() => councils.remove(id)),
                      ),
                ]),
                const SizedBox(height: 8),
                Autocomplete<Council>(
                  optionsBuilder: (v) {
                    final q = v.text.trim().toLowerCase();
                    if (q.isEmpty) return const Iterable<Council>.empty();
                    return d.councils
                        .where((c) => !c.isSiec && !councils.contains(c.id) && c.name.toLowerCase().contains(q))
                        .take(12);
                  },
                  displayStringForOption: (c) => c.name,
                  onSelected: (c) => setD(() => councils.add(c.id)),
                  fieldViewBuilder: (ctx, ctrl, focus, _) => TextField(
                    controller: ctrl,
                    focusNode: focus,
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.add), hintText: 'Add a council – type part of its name'),
                    onSubmitted: (_) => ctrl.clear(),
                  ),
                ),
              ]),
            ),
          ),
          actions: [
            if (p.id != widget.data.me.id)
              TextButton.icon(
                icon: const Icon(Icons.key_outlined),
                label: const Text('Reset password…'),
                onPressed: () => showResetPasswordDialog(ctx,
                    userId: p.id, name: p.fullName.isEmpty ? (p.email ?? '') : p.fullName),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final siec = d.councils.where((c) => c.isSiec).map((c) => c.id).toSet();
    if (await runAction(context, () async {
      await Repo.updateProfile(p.id, {
        'full_name': name.text.trim(),
        'program': program.text.trim().isEmpty ? null : program.text.trim(),
        'academy': academy,
        if (autoYear == null) 'study_year': year,
        'is_member': member,
        'quiz_passed': quiz,
        'active': active,
        'role': role,
      });
      await Repo.setCouncils(p.id, councils.difference(siec));
    }, success: 'Saved')) {
      _reload();
    }
  }

  /// Make an account for a representative and show the temporary password to send them.
  Future<void> _createAccount() async {
    final name = TextEditingController(), email = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Create account'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Full name')),
            const SizedBox(height: 10),
            TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Email', hintText: 'abc12345@student.mdu.se')),
            const SizedBox(height: 10),
            const Text('The account is active at once. They must choose their own password the first time they sign in.'),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final pw = await Repo.createAccount(fullName: name.text.trim(), email: email.text.trim());
      if (!mounted) return;
      final message = 'Hi ${name.text.trim().split(' ').first}! Your MDSU Rep Hub account is ready.\n'
          'Open https://mdsu-rep-hub.pages.dev (or the app) and sign in with\n'
          'Email: ${email.text.trim()}\nTemporary password: $pw\n'
          'You will be asked to choose your own password.';
      _reload();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Account created ✓'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Send this to the representative (Teams or email):'),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
                child: SelectableText(message),
              ),
              const SizedBox(height: 8),
              const Text('Next: open them in the list and set program, academy, councils and membership.'),
            ]),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: message));
                if (ctx.mounted) showSnack(ctx, 'Copied');
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy message'),
            ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  List<Profile> _shown(List<Profile> people) {
    final q = _search.text.trim().toLowerCase();
    return people.where((p) {
      final ok = switch (_filter) {
        'active' => p.active,
        'waiting' => p.waitingForApproval,
        'inactive' => !p.active && !p.waitingForApproval,
        'notmember' => p.active && p.role == 'rep' && !p.isMember,
        'noquiz' => p.active && p.role == 'rep' && !p.quizPassed,
        _ => true,
      };
      if (!ok) return false;
      if (q.isEmpty) return true;
      return '${p.fullName} ${p.email ?? ''} ${p.program ?? ''}'.toLowerCase().contains(q);
    }).toList();
  }

  Widget _filters(List<Profile> people) {
    final n = {
      'all': people.length,
      'active': people.where((p) => p.active).length,
      'waiting': people.where((p) => p.waitingForApproval).length,
      'inactive': people.where((p) => !p.active && !p.waitingForApproval).length,
      'notmember': people.where((p) => p.active && p.role == 'rep' && !p.isMember).length,
      'noquiz': people.where((p) => p.active && p.role == 'rep' && !p.quizPassed).length,
    };
    const labels = {
      'all': 'All',
      'active': 'Active',
      'waiting': 'Waiting for approval',
      'inactive': 'Inactive',
      'notmember': 'Not union members',
      'noquiz': 'Quiz not passed',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SizedBox(
          width: 300,
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search name, email or program',
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _search.clear())),
            ),
          ),
        ),
        for (final e in labels.entries)
          ChoiceChip(
            label: Text('${e.value} (${n[e.key]})'),
            selected: _filter == e.key,
            onSelected: (_) => setState(() => _filter = e.key),
          ),
      ]),
    );
  }

  /// New sign-ups first, with Approve / Reject
  List<Widget> _waiting(List<Profile> people) {
    final w = people.where((p) => p.waitingForApproval).toList();
    if (w.isEmpty) return const [];
    return [
      SectionTitle('Waiting for approval (${w.length})'),
      Card(
        color: Color.alphaBlend(softBg(context, Colors.orange), Theme.of(context).cardColor),
        child: Column(children: [
          for (final p in w)
            ListTile(
              leading: const Icon(Icons.person_add_alt),
              title: Text(p.fullName),
              subtitle: Text('${p.email ?? ''}${p.createdAt == null ? '' : ' · signed up ${fmtDate(p.createdAt!)}'}'),
              trailing: Wrap(spacing: 4, children: [
                TextButton(onPressed: () => _decide(p, false), child: const Text('Reject')),
                FilledButton(onPressed: () => _decide(p, true), child: const Text('Approve')),
              ]),
            ),
        ]),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) => Loader<List<Profile>>(
        future: _f,
        onRetry: _reload,
        builder: (context, people) => ListView(padding: EdgeInsets.all(isNarrow(context) ? 12 : 24), children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: PageIntro(
                text: 'Adding a representative: either the student creates an account with their student email '
                    '(they appear here greyed out – open them and switch on Active), or you press Create account '
                    'and send them the temporary password. Then set program, academy, councils and membership.',
                actions: [
                  FilledButton.icon(
                      onPressed: _createAccount,
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Create account')),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Builder(builder: (context) {
            final reps = people.where((p) => p.role == 'rep');
            final active = reps.where((p) => p.active).toList();
            return Wrap(spacing: 12, runSpacing: 12, children: [
              Kpi(
                  icon: Icons.people_outline,
                  label: 'Active representatives',
                  value: '${active.length}',
                  selected: _filter == 'active',
                  onTap: () => setState(() => _filter = _filter == 'active' ? 'all' : 'active')),
              Kpi(
                  icon: Icons.card_membership_outlined,
                  color: Colors.red.shade700,
                  label: 'Not union members',
                  value: '${active.where((p) => !p.isMember).length}',
                  sub: 'tap to see who',
                  selected: _filter == 'notmember',
                  onTap: () => setState(() => _filter = _filter == 'notmember' ? 'all' : 'notmember')),
              Kpi(
                  icon: Icons.quiz_outlined,
                  color: Colors.orange.shade800,
                  label: 'Quiz not passed',
                  value: '${active.where((p) => !p.quizPassed).length}',
                  sub: 'tap to see who',
                  selected: _filter == 'noquiz',
                  onTap: () => setState(() => _filter = _filter == 'noquiz' ? 'all' : 'noquiz')),
              Kpi(
                  icon: Icons.person_add_alt,
                  color: Colors.teal,
                  label: 'Waiting for approval',
                  value: '${people.where((p) => p.waitingForApproval).length}',
                  selected: _filter == 'waiting',
                  onTap: () => setState(() => _filter = _filter == 'waiting' ? 'all' : 'waiting')),
            ]);
          }),
          const SizedBox(height: 8),
          ..._waiting(people),
          _filters(people),
          Card(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                showCheckboxColumn: false,
                columns: const [
                  DataColumn(label: Text('Name')),
                  DataColumn(label: Text('Email')),
                  DataColumn(label: Text('Program')),
                  DataColumn(label: Text('Year')),
                  DataColumn(label: Text('Role')),
                  DataColumn(label: Text('Member')),
                  DataColumn(label: Text('Quiz')),
                  DataColumn(label: Text('Successor task')),
                ],
                rows: [
                  for (final p in _shown(people))
                    DataRow(
                      onSelectChanged: (_) => _edit(p),
                      color: p.active ? null : WidgetStatePropertyAll(Theme.of(context).colorScheme.surfaceContainerHighest),
                      cells: [
                        DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(p.fullName.isEmpty ? (p.email ?? '') : p.fullName),
                          if (p.waitingForApproval) ...[
                            const SizedBox(width: 6),
                            StatusChip('Waiting', Colors.orange.shade800),
                          ],
                          if (p.approval == 'rejected') ...[
                            const SizedBox(width: 6),
                            StatusChip('Rejected', Colors.grey),
                          ],
                        ])),
                        DataCell(Text(p.email ?? '')),
                        DataCell(Text('${p.program ?? ''} ${p.academy == null ? '' : '· ${p.academy}'}')),
                        DataCell(Text('${p.studyYear ?? '-'}')),
                        DataCell(Text(p.role)),
                        DataCell(Icon(p.isMember ? Icons.check : Icons.close, color: p.isMember ? Colors.green : Colors.red)),
                        DataCell(Icon(p.quizPassed ? Icons.check : Icons.close,
                            color: p.quizPassed ? Colors.green : Colors.orange)),
                        DataCell(Text((p.studyYear ?? 1) > 1 && p.role == 'rep'
                            ? 'Help recruit year ${p.studyYear! - 1} rep'
                            : '—')),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ]),
      );
}

// ============================ Settings & automations =======================
class SettingsPage extends StatefulWidget {
  final OfficerData data;
  final VoidCallback onChanged;
  const SettingsPage({super.key, required this.data, required this.onChanged});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Semester? get s => widget.data.semester;
  late final _rate = TextEditingController(text: '${s?.hourlyRate ?? 130}');
  late final _half = TextEditingController(text: '${s?.halfHourRate ?? 65}');
  late final _esc = TextEditingController(text: '${s?.escalateAfter ?? 2}');
  late final _call = TextEditingController(text: '${s?.agendaCallDays ?? 7}');
  late final _deadlineDays = TextEditingController(text: '${s?.agendaDeadlineDays ?? 2}');
  late DateTime? _deadline = s?.reportDeadline;
  late DateTime? _reminder = s?.reminderDate;
  bool? _signupOpen;

  @override
  void initState() {
    super.initState();
    Repo.signupOpen().then((v) {
      if (mounted) setState(() => _signupOpen = v);
    });
  }

  Future<void> _setSignup(bool open) async {
    setState(() => _signupOpen = open);
    if (!await runAction(context, () => Repo.setSignupOpen(open),
        success: open ? 'Sign-up is open' : 'Sign-up is closed – create accounts under Representatives')) {
      if (mounted) setState(() => _signupOpen = !open);
    }
  }

  Future<DateTime?> _pick(DateTime? initial) => showDatePicker(
      context: context,
      initialDate: initial ?? DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime(2035));

  String _d(DateTime d) => d.toIso8601String().substring(0, 10);

  Future<void> _save() async {
    if (s == null) return;
    if (await runAction(
        context,
        () => Repo.updateSemester(s!.id, {
              'hourly_rate': int.tryParse(_rate.text) ?? 130,
              'half_hour_rate': int.tryParse(_half.text) ?? 65,
              'escalate_after': int.tryParse(_esc.text) ?? 2,
              'agenda_call_days': int.tryParse(_call.text) ?? 7,
              'agenda_deadline_days': int.tryParse(_deadlineDays.text) ?? 2,
              if (_deadline != null) 'report_deadline': _d(_deadline!),
              'reminder_date': _reminder == null ? null : _d(_reminder!),
            }),
        success: 'Settings saved')) {
      widget.onChanged();
    }
  }

  Future<void> _newSemester() async {
    final name = TextEditingController();
    DateTime starts = DateTime.now(), ends = DateTime.now().add(const Duration(days: 150));
    DateTime deadline = ends;
    DateTime? reminder;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          Widget dateRow(String label, DateTime? v, void Function(DateTime) set) => ListTile(
                title: Text(label),
                trailing: Text(v == null ? '—' : fmtDateY(v)),
                onTap: () async {
                  final p = await _pick(v);
                  if (p != null) setD(() => set(p));
                },
              );
          return AlertDialog(
            title: const Text('Start new semester'),
            content: SizedBox(
              width: 440,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (e.g. Spring 2027)')),
                dateRow('Starts', starts, (d) => starts = d),
                dateRow('Ends', ends, (d) => ends = d),
                dateRow('Report deadline', deadline, (d) => deadline = d),
                dateRow('Reminder date', reminder, (d) => reminder = d),
                const Text('Old reports stay saved under the old semester. Every rep is asked to redo the quiz.'),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start')),
            ],
          );
        },
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    if (await runAction(
        context,
        () => Repo.startNewSemester(
            name: name.text.trim(), starts: starts, ends: ends, deadline: deadline, reminder: reminder),
        success: 'New semester started')) {
      widget.onChanged();
    }
  }

  Future<void> _runAutomations() async {
    try {
      final r = await Repo.runAutomations();
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Automations ran'),
          content: Text('Agenda input requests: ${r['agenda_calls']}\n'
              'Time-log prompts: ${r['time_prompts']}\n'
              'Issues escalated: ${r['escalated']}\n'
              'Deadline reminders: ${r['reminders']}'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = [
      ('Ask for agenda input', '${_call.text} days before each meeting, reps in that council are asked to collect '
          'input. Items must be sent ${_deadlineDays.text} days before the meeting.'),
      ('Log time after meeting', 'The day after a meeting, reps get a prompt to log hours and upload notes.'),
      ('Carry open issues forward', 'Unanswered issues appear on the next agenda of the same council.'),
      ('Escalate unanswered issues', 'After ${_esc.text} meetings without an answer the issue is marked escalated.'),
      ('Deadline reminders', 'On the reminder date and 3 days before the deadline, to everyone who has not submitted.'),
    ];
    return ListView(padding: EdgeInsets.all(isNarrow(context) ? 12 : 24), children: [
      if (s == null)
        Card(
          child: ListTile(
            title: const Text('No active semester'),
            trailing: FilledButton(onPressed: _newSemester, child: const Text('Create semester')),
          ),
        ),
      const SectionTitle('Appearance'),
      Card(
        child: ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Light or dark, colour and banner'),
          subtitle: const Text('Your own choice – every representative can choose theirs under More → Appearance.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showAppearanceSheet(context),
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.tips_and_updates_outlined),
          title: const Text('Show the welcome tour again'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => showTour(context, officerTour, markSeen: false),
        ),
      ),
      const SectionTitle('Payslips'),
      const _PayslipCard(),
      const SectionTitle('Accounts'),
      Card(
        child: SwitchListTile(
          secondary: const Icon(Icons.how_to_reg_outlined),
          title: const Text('Students can create their own account'),
          subtitle: Text(_signupOpen == false
              ? 'Closed: only you create accounts (Representatives → Create account).'
              : 'Open: anyone with a university email (@student.mdu.se) can sign up. '
                  'New accounts wait until you switch them on.'),
          value: _signupOpen ?? true,
          onChanged: _signupOpen == null ? null : _setSignup,
        ),
      ),
      const SectionTitle('Automations (run every morning at 07:05)'),
      Card(
        child: Column(children: [
          for (final (t, d) in rules) ListTile(leading: const Icon(Icons.bolt), title: Text(t), subtitle: Text(d)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                  onPressed: _runAutomations, icon: const Icon(Icons.play_arrow), label: const Text('Run now')),
            ),
          ),
        ]),
      ),
      if (s != null) ...[
        SectionTitle('Pay & semester – ${s!.name}'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(spacing: 12, runSpacing: 12, children: [
              SizedBox(width: 200, child: TextField(controller: _rate, decoration: const InputDecoration(labelText: 'Hourly rate (SEK)'))),
              SizedBox(width: 200, child: TextField(controller: _half, decoration: const InputDecoration(labelText: 'Per started ½ hour (SEK)'))),
              SizedBox(width: 200, child: TextField(controller: _esc, decoration: const InputDecoration(labelText: 'Escalate after (meetings)'))),
              SizedBox(width: 200, child: TextField(controller: _call, decoration: const InputDecoration(labelText: 'Agenda reminder (days before)'))),
              SizedBox(width: 200, child: TextField(controller: _deadlineDays, decoration: const InputDecoration(labelText: 'Agenda items due (days before)'))),
              OutlinedButton.icon(
                icon: const Icon(Icons.event),
                label: Text('Deadline: ${_deadline == null ? '—' : fmtDateY(_deadline!)}'),
                onPressed: () async {
                  final p = await _pick(_deadline);
                  if (p != null) setState(() => _deadline = p);
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.notifications_outlined),
                label: Text('Reminder: ${_reminder == null ? '—' : fmtDateY(_reminder!)}'),
                onPressed: () async {
                  final p = await _pick(_reminder);
                  if (p != null) setState(() => _reminder = p);
                },
              ),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 8, children: [
          FilledButton(onPressed: _save, child: const Text('Save settings')),
          OutlinedButton(onPressed: _newSemester, child: const Text('Start new semester…')),
        ]),
        const SizedBox(height: 8),
        const Text('Handbook rule: only hours worked while a union member are paid; late reports are paid at the end '
            'of the next semester. Approved reports keep the amount calculated at approval.'),
      ],
    ]);
  }
}


/// Link to where reps see their payslip (e.g. Fortnox). Sent with the "paid" notification.
class _PayslipCard extends StatefulWidget {
  const _PayslipCard();
  @override
  State<_PayslipCard> createState() => _PayslipCardState();
}

class _PayslipCardState extends State<_PayslipCard> {
  final _url = TextEditingController(), _label = TextEditingController(text: 'Fortnox');

  @override
  void initState() {
    super.initState();
    Repo.payslipLink().then((v) {
      if (!mounted) return;
      setState(() {
        _url.text = v.$1 ?? '';
        _label.text = v.$2;
      });
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('When you mark a report as paid, the representative gets a notification. With a link here, '
                'tapping it opens the payroll app where they see their payslip, tax and details. '
                'They also get a "See your payslip" button on their paid report.'),
            const SizedBox(height: 10),
            Wrap(spacing: 12, runSpacing: 10, children: [
              SizedBox(
                width: 380,
                child: TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                      labelText: 'Payslip link', hintText: 'https://… (the page or app link reps use)'),
                ),
              ),
              SizedBox(
                width: 180,
                child: TextField(controller: _label, decoration: const InputDecoration(labelText: 'Name, e.g. Fortnox')),
              ),
              FilledButton(
                onPressed: () {
                  final u = _url.text.trim();
                  if (u.isNotEmpty && !u.startsWith('http')) {
                    return showSnack(context, 'The link must start with https://');
                  }
                  runAction(context, () => Repo.setPayslipLink(u, _label.text.isEmpty ? 'Fortnox' : _label.text),
                      success: u.isEmpty ? 'Link removed' : 'Saved');
                },
                child: const Text('Save'),
              ),
            ]),
          ]),
        ),
      );
}
