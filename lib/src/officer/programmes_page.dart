import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../data/roster.dart';
import '../shared/charts.dart';
import '../shared/widgets.dart';
import 'officer_shell.dart';
import 'roster_excel.dart';

class _RosterData {
  final List<Council> councils;
  final List<RosterEntry> roster;
  final Map<String, Profile> byEmail;
  _RosterData(this.councils, this.roster, this.byEmail);
}

Future<_RosterData> _loadRoster() async {
  final people = await Repo.profiles();
  return _RosterData(await Repo.councils(), await Repo.roster(),
      {for (final p in people) if (p.email != null) p.email!.trim().toLowerCase(): p});
}

String councilDetails(Council c) => [
      if (c.city != null) c.city!,
      if (c.studyMode != null) modeLabels[c.studyMode] ?? c.studyMode!,
      if (c.intake != null) c.intake == 'HT_VT' ? 'HT & VT' : c.intake!,
      if (c.lengthYears != null) '${_num(c.lengthYears!)} years',
      if (c.directorName != null && c.directorName!.isNotEmpty) c.directorName!,
    ].join(' · ');

/// SIEC, or a council set to 0 seats: it is for everyone, so it has no seats to fill or count
bool forAllReps(Council c) => c.isSiec || c.seats == 0;

String _num(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Programmes and central councils: how many seats each has, who sits where, what is vacant.
class ProgrammesPage extends StatefulWidget {
  final OfficerData data;
  final VoidCallback onChanged;
  final String? openCouncilId; // from the quick search
  const ProgrammesPage({super.key, required this.data, required this.onChanged, this.openCouncilId});
  @override
  State<ProgrammesPage> createState() => _ProgrammesPageState();
}

class _ProgrammesPageState extends State<ProgrammesPage> {
  late Future<_RosterData> _f = _loadRoster();
  String _group = 'programmes'; // programmes | central | other (SIEC, academy councils)
  String? _city;
  String? _kpi; // filter from a number card: full | vacant | nobody | extra | finished

  bool get _central => _group != 'programmes';
  void _setKpi(String k) => setState(() => _kpi = _kpi == k ? null : k);
  final _search = TextEditingController();

  void _reload() => setState(() => _f = _loadRoster());

  @override
  void initState() {
    super.initState();
    final id = widget.openCouncilId;
    if (id != null) {
      final hit = widget.data.councils.where((c) => c.id == id).toList();
      if (hit.isNotEmpty) {
        final c = hit.first;
        _group = c.isProgramme ? 'programmes' : (c.type == 'general' ? 'central' : 'other');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _open(c);
        });
      }
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(Council c) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ProgrammeDetailPage(councilId: c.id)));
    if (mounted) _reload(); // keeps the filters
  }

  Future<void> _import() async {
    if (await importRosterXlsx(context)) {
      _reload();
      widget.onChanged();
    }
  }

  Future<void> _export(_RosterData d) async {
    try {
      final where = await exportRosterXlsx(d.councils, d.roster, d.byEmail);
      if (where != null && mounted) showSnack(context, 'Saved: $where');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Loader<_RosterData>(
      future: _f,
      onRetry: _reload,
      builder: (context, d) {
        final now = DateTime.now();
        final relevant = d.councils
            .where((c) => switch (_group) {
                  'central' => c.type == 'general',
                  'other' => c.type == 'academy' || c.isSiec,
                  _ => c.isProgramme,
                })
            .toList();
        final plans = {for (final c in relevant) c.id: SeatPlan(c, d.roster, now)};
        final live = relevant.where((c) => !c.cancelled && !forAllReps(c));
        final seats = live.fold<int>(0, (a, c) => a + plans[c.id]!.seats);
        final filled = live.fold<int>(0, (a, c) => a + plans[c.id]!.filled);
        final empty = live.where((c) => plans[c.id]!.seats > 0 && plans[c.id]!.filled == 0).length;
        final extra = live.fold<int>(0, (a, c) => a + plans[c.id]!.extra);
        final finished = live.fold<int>(0, (a, c) => a + plans[c.id]!.finished.length);

        final q = _search.text.trim().toLowerCase();
        final shown = relevant.where((c) {
          final p = plans[c.id]!;
          if (_city != null && c.city != _city) return false;
          if (_kpi != null && forAllReps(c)) return false;
          final ok = switch (_kpi) {
            'full' => !c.cancelled && p.seats > 0 && p.vacant == 0,
            'vacant' => !c.cancelled && p.vacant > 0,
            'nobody' => !c.cancelled && p.seats > 0 && p.filled == 0,
            'extra' => p.extra > 0,
            'finished' => p.finished.isNotEmpty,
            _ => true,
          };
          if (!ok) return false;
          if (q.isEmpty) return true;
          final emails = p.all.map((r) => r.email).join(' ');
          final names = p.all.map((r) => d.byEmail[r.email]?.fullName ?? '').join(' ');
          return '${c.name} ${c.directorName ?? ''} ${c.institution ?? ''} $emails $names'.toLowerCase().contains(q);
        }).toList()
          ..sort((a, b) {
            if (a.cancelled != b.cancelled) return a.cancelled ? 1 : -1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });

        return ListView(padding: EdgeInsets.all(isNarrow(context) ? 12 : 24), children: [
          PageIntro(
            text: 'Every programme has one seat per running cohort (intake every term: one per term; once a year: '
                'one per year). Central councils have a set number of seats. More representatives than seats is '
                'allowed – they are marked as extra.',
            actions: [
              OutlinedButton.icon(onPressed: _import, icon: const Icon(Icons.upload_file), label: const Text('Import Excel')),
              OutlinedButton.icon(
                  onPressed: () => _export(d), icon: const Icon(Icons.download), label: const Text('Download Excel')),
              FilledButton.icon(
                onPressed: () async {
                  final id = await showCouncilDialog(context,
                      type: switch (_group) { 'central' => 'general', 'other' => 'academy', _ => 'program' });
                  if (id != null) {
                    _reload();
                    widget.onChanged();
                  }
                },
                icon: const Icon(Icons.add),
                label: Text(_central ? 'New council' : 'New programme'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            DonutCard(
              title: 'Seats',
              center: '$filled\nof $seats',
              slices: [
                Slice('Filled', filled, Colors.green.shade600),
                Slice('Vacant', seats - filled, Colors.red.shade400),
                Slice('Extra', extra, Colors.purple.shade300),
              ],
              selected: switch (_kpi) { 'full' => 0, 'vacant' => 1, 'extra' => 2, _ => null },
              onSlice: (i) => _setKpi(const ['full', 'vacant', 'extra'][i]),
            ),
            Kpi(
                icon: Icons.event_seat,
                color: Colors.green.shade700,
                label: 'Seats filled',
                value: '$filled of $seats',
                sub: 'tap: the full ones',
                selected: _kpi == 'full',
                onTap: () => _setKpi('full')),
            Kpi(
                icon: Icons.event_seat_outlined,
                color: Colors.red.shade700,
                label: 'Vacant seats',
                value: '${seats - filled}',
                sub: 'tap: where they are',
                selected: _kpi == 'vacant',
                onTap: () => _setKpi('vacant')),
            Kpi(
                icon: Icons.person_off_outlined,
                color: Colors.orange.shade800,
                label: _central ? 'Councils with nobody' : 'Programmes with nobody',
                value: '$empty',
                selected: _kpi == 'nobody',
                onTap: () => _setKpi('nobody')),
            Kpi(
                icon: Icons.group_add_outlined,
                color: Colors.purple,
                label: 'Extra representatives',
                value: '$extra',
                selected: _kpi == 'extra',
                onTap: () => _setKpi('extra')),
            if (!_central)
              Kpi(
                  icon: Icons.school_outlined,
                  color: Colors.blueGrey,
                  label: 'Finished their programme',
                  value: '$finished',
                  selected: _kpi == 'finished',
                  onTap: () => _setKpi('finished')),
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'programmes', label: Text('Programmes')),
                ButtonSegment(value: 'central', label: Text('Central councils')),
                ButtonSegment(value: 'other', label: Text('Other')),
              ],
              selected: {_group},
              onSelectionChanged: (s) => setState(() {
                _group = s.first;
                _kpi = null;
              }),
            ),
            if (!_central)
              for (final (v, l) in const [(null, 'Both cities'), ('ESK', 'Eskilstuna'), ('VÄS', 'Västerås')])
                ChoiceChip(label: Text(l), selected: _city == v, onSelected: (_) => setState(() => _city = v)),
            if (_kpi != null)
              InputChip(
                avatar: const Icon(Icons.filter_alt, size: 16),
                label: Text(const {
                  'full': 'Full',
                  'vacant': 'With vacant seats',
                  'nobody': 'With nobody',
                  'extra': 'With extra reps',
                  'finished': 'With finished reps',
                }[_kpi]!),
                onDeleted: () => setState(() => _kpi = null),
              ),
            SizedBox(
              width: 280,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search name, email, director…',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(() => _search.clear()),
                        ),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text('${shown.length} shown', style: Theme.of(context).textTheme.bodySmall),
          if (shown.isEmpty)
            EmptyState(_kpi != null ? 'Nothing matches this filter' : 'Nothing here. Import Dania\'s Excel file or add one.'),
          for (final c in shown) _ProgrammeTile(council: c, plan: plans[c.id]!, onTap: () => _open(c)),
        ]);
      },
    );
  }
}

class _ProgrammeTile extends StatelessWidget {
  final Council council;
  final SeatPlan plan;
  final VoidCallback onTap;
  const _ProgrammeTile({required this.council, required this.plan, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = council;
    final p = plan;
    final ratio = p.seats == 0 ? 0.0 : p.filled / p.seats;
    final color = c.cancelled
        ? Colors.grey
        : (ratio >= 1 ? Colors.green.shade700 : (ratio == 0 ? Colors.red.shade700 : Colors.orange.shade800));
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(c.name,
                    style: t.textTheme.titleSmall?.copyWith(
                        decoration: c.cancelled ? TextDecoration.lineThrough : null)),
                const SizedBox(height: 2),
                Text(c.cancelled ? 'Cancelled' : councilDetails(c), style: t.textTheme.bodySmall),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 4, children: [
                  if (p.extra > 0 && !forAllReps(c)) StatusChip('+${p.extra} extra', Colors.red.shade700),
                  if (p.finished.isNotEmpty) StatusChip('${p.finished.length} finished', Colors.blueGrey),
                  if (p.unplaced.isNotEmpty && p.usesCohorts) StatusChip('${p.unplaced.length} without cohort', Colors.orange.shade800),
                  if (c.isProgramme && !p.usesCohorts && c.seats == null)
                    StatusChip('Set intake and length', Colors.orange.shade800),
                ]),
              ]),
            ),
            const SizedBox(width: 12),
            if (forAllReps(c))
              Text('For all representatives', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant))
            else
            SizedBox(
              width: 90,
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(p.summary, style: t.textTheme.titleLarge?.copyWith(color: color, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                      value: ratio.clamp(0, 1).toDouble(), minHeight: 6, color: color, backgroundColor: color.withValues(alpha: 0.15)),
                ),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// One programme / council
// ---------------------------------------------------------------------------

class ProgrammeDetailPage extends StatefulWidget {
  final String councilId;
  const ProgrammeDetailPage({super.key, required this.councilId});
  @override
  State<ProgrammeDetailPage> createState() => _ProgrammeDetailPageState();
}

class _ProgrammeDetailPageState extends State<ProgrammeDetailPage> {
  late Future<_RosterData> _f = _loadRoster();
  void _reload() => setState(() => _f = _loadRoster());

  Future<void> _addOrEdit(Council c, _RosterData d, {RosterEntry? entry, Cohort? cohort}) async {
    final saved = await showRosterDialog(context, council: c, byEmail: d.byEmail, entry: entry, cohort: cohort);
    if (saved) _reload();
  }

  final _hidden = <String>{}; // removed, waiting for Undo to run out

  void _remove(RosterEntry r, String who) => deleteWithUndo(context, '$who removed from this council', () async {
        await Repo.removeFromRoster(r.id);
        if (mounted) _reload();
      }, hide: () => setState(() => _hidden.add(r.id)), restore: () => setState(() => _hidden.remove(r.id)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Seats')),
      body: Loader<_RosterData>(
      future: _f,
      onRetry: _reload,
      builder: (context, d) {
        final hits = d.councils.where((c) => c.id == widget.councilId).toList();
        if (hits.isEmpty) return const EmptyState('This council was deleted');
        final c = hits.first;
        final p = SeatPlan(c, d.roster.where((r) => !_hidden.contains(r.id)).toList());
        final now = DateTime.now();
        final t = Theme.of(context);
        final emails = p.all.map((r) => r.email).toList();

        Widget rep(RosterEntry r, {bool extra = false, bool finished = false}) {
          final person = d.byEmail[r.email];
          final k = Cohort.parse(r.cohort);
          return ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 8),
            shape: extra ? Border(left: BorderSide(color: Colors.red.shade700, width: 4)) : null,
            leading: Icon(person == null ? Icons.person_outline : Icons.person,
                color: person?.active == true ? t.colorScheme.primary : Colors.grey),
            title: Text(person?.fullName ?? r.email),
            subtitle: Text([
              if (person != null) r.email,
              if (person == null) 'No account yet',
              if (person != null && !person.active) 'account not active',
              if (k != null) '${k.label} · year ${k.studyYear(now)}',
              if (r.note != null) r.note!,
            ].join(' · ')),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (extra) StatusChip('Extra', Colors.red.shade700),
              if (finished) StatusChip('Finished', Colors.blueGrey),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (v) {
                  if (v == 'mail') launchUrl(Uri.parse('mailto:${r.email}'));
                  if (v == 'edit') _addOrEdit(c, d, entry: r);
                  if (v == 'remove') _remove(r, person?.fullName ?? r.email);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Change cohort / note')),
                  PopupMenuItem(value: 'mail', child: Text('Send email')),
                  PopupMenuItem(value: 'remove', child: Text('Remove from this council')),
                ],
              ),
            ]),
          );
        }

        final seatCards = <Widget>[];
        if (p.usesCohorts) {
          for (final k in p.cohorts) {
            final list = p.bySeat[k]!;
            seatCards.add(Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text('${k.label} · year ${k.studyYear(now)} · term ${k.termNumber(now)}',
                          style: t.textTheme.titleSmall),
                    ),
                    if (list.isEmpty) StatusChip('Vacant', Colors.red.shade700),
                    TextButton.icon(
                        onPressed: () => _addOrEdit(c, d, cohort: k),
                        icon: const Icon(Icons.person_add_alt, size: 18),
                        label: const Text('Add')),
                  ]),
                  for (var i = 0; i < list.length; i++) rep(list[i], extra: i > 0),
                ]),
              ),
            ));
          }
        } else {
          final current = p.all.where((r) => !p.finished.contains(r)).toList();
          seatCards.add(Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${p.seats} seat${p.seats == 1 ? '' : 's'}', style: t.textTheme.titleSmall)),
                  if (p.vacant > 0) StatusChip('${p.vacant} vacant', Colors.red.shade700),
                  TextButton.icon(
                      onPressed: () => _addOrEdit(c, d),
                      icon: const Icon(Icons.person_add_alt, size: 18),
                      label: const Text('Add')),
                ]),
                if (current.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nobody yet')),
                for (var i = 0; i < current.length; i++) rep(current[i], extra: i >= p.seats),
              ]),
            ),
          ));
        }

        return ListView(padding: EdgeInsets.all(isNarrow(context) ? 12 : 24), children: [
            Text(c.name, style: t.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text('${p.summary} seats filled${p.extra > 0 ? ' · +${p.extra} extra' : ''}',
                          style: t.textTheme.titleLarge),
                    ),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final r = await showCouncilDialog(context, council: c);
                        if (r == '' && context.mounted) {
                          Navigator.pop(context); // deleted: back to the list
                        } else if (r != null) {
                          _reload();
                        }
                      },
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit details'),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 24, runSpacing: 8, children: [
                    if (c.city != null) _Info('City', cityLabels[c.city] ?? c.city!),
                    if (c.studyMode != null) _Info('Teaching', modeLabels[c.studyMode] ?? c.studyMode!),
                    if (c.intake != null) _Info('New students', intakeLabels[c.intake] ?? c.intake!),
                    if (c.lengthYears != null) _Info('Length', '${_num(c.lengthYears!)} years'),
                    _Info('Seats', c.seats == null ? '${p.seats} (automatic)' : '${c.seats} (set by hand)'),
                    if (c.institution != null && c.institution!.isNotEmpty) _Info('Institution', c.institution!),
                    if (c.directorName != null && c.directorName!.isNotEmpty)
                      _Info('Programme director',
                          '${c.directorName}${c.directorEmail == null || c.directorEmail!.isEmpty ? '' : '\n${c.directorEmail}'}'),
                  ]),
                  if (c.notes != null && c.notes!.isNotEmpty) ...[const SizedBox(height: 8), Text(c.notes!)],
                  if (c.isProgramme && !p.usesCohorts && c.seats == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('Set "New students" and "Length" (Edit details) so the seats can be worked out.',
                          style: TextStyle(color: Colors.orange.shade900)),
                    ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, children: [
                    if (emails.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => launchUrl(Uri.parse('mailto:?bcc=${emails.join(',')}')),
                        icon: const Icon(Icons.forward_to_inbox),
                        label: Text('Email all ${emails.length}'),
                      ),
                    if (c.directorEmail != null && c.directorEmail!.isNotEmpty)
                      TextButton.icon(
                        onPressed: () => launchUrl(Uri.parse('mailto:${c.directorEmail}')),
                        icon: const Icon(Icons.mail_outline),
                        label: const Text('Email the director'),
                      ),
                  ]),
                ]),
              ),
            ),
            SectionTitle(p.usesCohorts ? 'Seats – one per cohort (newest first)' : 'Seats'),
            ...seatCards,
            if (p.usesCohorts && p.unplaced.isNotEmpty) ...[
              const SectionTitle('Without a running cohort – choose their cohort'),
              Card(child: Column(children: [for (final r in p.unplaced) rep(r, extra: true)])),
            ],
            if (p.finished.isNotEmpty) ...[
              SectionTitle('Finished their programme (${p.finished.length})',
                  trailing: TextButton(
                    onPressed: () async {
                      if (await confirm(context, 'Remove all who finished?',
                              'They leave this council. Their accounts are not deleted.', ok: 'Remove all') &&
                          context.mounted &&
                          await runAction(context, () async {
                            for (final r in p.finished) {
                              await Repo.removeFromRoster(r.id);
                            }
                          }, success: 'Removed')) {
                        _reload();
                      }
                    },
                    child: const Text('Remove all'),
                  )),
              Card(child: Column(children: [for (final r in p.finished) rep(r, finished: true)])),
            ],
          ]);
      },
      ),
    );
  }
}

class _Info extends StatelessWidget {
  final String label;
  final String value;
  const _Info(this.label, this.value);
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Text(value),
      ]);
}

// ---------------------------------------------------------------------------
// Dialogs
// ---------------------------------------------------------------------------

/// Cohorts to choose from: the running ones first, then older/other terms of the last years.
List<Cohort> _cohortChoices(Council c) {
  final now = DateTime.now();
  final list = <Cohort>[...activeCohorts(c, now)];
  var k = now.month >= 8 ? Cohort('HT', now.year) : Cohort('VT', now.year);
  for (var i = 0; i < 14; i++) {
    if (!list.contains(k)) list.add(k);
    k = k.previous();
  }
  return list;
}

/// Add a representative to a council (or change their cohort / note). Returns true when saved.
Future<bool> showRosterDialog(BuildContext context,
    {required Council council, required Map<String, Profile> byEmail, RosterEntry? entry, Cohort? cohort}) async {
  final email = TextEditingController(text: entry?.email ?? '');
  final note = TextEditingController(text: entry?.note ?? '');
  String? code = entry?.cohort ?? cohort?.code;
  final choices = council.isProgramme ? _cohortChoices(council) : <Cohort>[];
  final running = activeCohorts(council).toSet();
  if (code != null && !choices.any((k) => k.code == code)) {
    final k = Cohort.parse(code);
    if (k != null) choices.add(k);
  }
  String? error;
  TextEditingController? typed; // the autocomplete field
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(entry == null ? 'Add representative' : 'Edit representative'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (entry == null)
              Autocomplete<String>(
                optionsBuilder: (v) {
                  final q = v.text.trim().toLowerCase();
                  if (q.length < 2) return const Iterable<String>.empty();
                  return byEmail.entries
                      .where((e) => e.key.contains(q) || e.value.fullName.toLowerCase().contains(q))
                      .map((e) => e.key)
                      .take(8);
                },
                displayStringForOption: (o) => o,
                fieldViewBuilder: (ctx, ctrl, focus, onSubmit) {
                  typed = ctrl;
                  return TextField(
                    controller: ctrl,
                    focusNode: focus,
                    autofocus: true,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(
                        labelText: 'Student email', hintText: 'abc12345@student.mdu.se', helperText: 'Type a name or email'),
                  );
                },
              )
            else
              Text(byEmail[entry.email]?.fullName ?? entry.email, style: Theme.of(ctx).textTheme.titleMedium),
            if (choices.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: code,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Cohort (when they started)'),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('— not known yet')),
                  for (final k in choices)
                    DropdownMenuItem<String?>(
                      value: k.code,
                      child: Text('${k.label} · year ${k.studyYear(DateTime.now())}'
                          '${running.contains(k) ? '' : (k.compareTo(running.isEmpty ? k : running.last) < 0 ? ' (finished)' : ' (no seat)')}'),
                    ),
                ],
                onChanged: (v) => setD(() => code = v),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: note,
              decoration: const InputDecoration(
                  labelText: 'Note (optional)', hintText: 'e.g. also institutional council, campus group'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(error!, style: TextStyle(color: Colors.red.shade800)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (typed != null) email.text = typed!.text;
              final e = email.text.trim().toLowerCase();
              if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) {
                return setD(() => error = 'Write a valid email address');
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted) return false;
  return runAction(
    context,
    () => entry == null
        ? Repo.addToRoster(council.id, email.text, cohort: code, note: note.text)
        : Repo.updateRoster(entry.id, cohort: code, note: note.text),
    success: 'Saved',
  );
}

/// New or edit programme / council details. Returns the council id when saved.
Future<String?> showCouncilDialog(BuildContext context, {Council? council, String type = 'program'}) async {
  final c = council;
  final name = TextEditingController(text: c?.name ?? '');
  final length = TextEditingController(text: c?.lengthYears == null ? '' : _num(c!.lengthYears!));
  final seats = TextEditingController(text: c?.seats?.toString() ?? '');
  final director = TextEditingController(text: c?.directorName ?? '');
  final directorEmail = TextEditingController(text: c?.directorEmail ?? '');
  final institution = TextEditingController(text: c?.institution ?? '');
  final notes = TextEditingController(text: c?.notes ?? '');
  String kind = c?.type ?? type;
  String? city = c?.city, mode = c?.studyMode, intake = c?.intake;
  bool cancelled = c?.cancelled ?? false;
  String? error;

  Widget box(Widget w) => SizedBox(width: 200, child: w);

  final ok = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(c == null ? (kind == 'program' ? 'New programme' : 'New council') : 'Edit ${c.name}'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Ekonomprogrammet · ESK · Campus')),
              const SizedBox(height: 10),
              Wrap(spacing: 12, runSpacing: 10, children: [
                box(DropdownButtonFormField<String>(
                  initialValue: kind,
                  decoration: const InputDecoration(labelText: 'Type'),
                  items: const [
                    DropdownMenuItem(value: 'program', child: Text('Programme')),
                    DropdownMenuItem(value: 'general', child: Text('Central council')),
                    DropdownMenuItem(value: 'academy', child: Text('Academy council')),
                    DropdownMenuItem(value: 'siec', child: Text('SIEC')),
                  ],
                  onChanged: (v) => setD(() => kind = v ?? kind),
                )),
                box(DropdownButtonFormField<String?>(
                  initialValue: city,
                  decoration: const InputDecoration(labelText: 'City'),
                  items: const [
                    DropdownMenuItem<String?>(value: null, child: Text('—')),
                    DropdownMenuItem<String?>(value: 'ESK', child: Text('Eskilstuna')),
                    DropdownMenuItem<String?>(value: 'VÄS', child: Text('Västerås')),
                  ],
                  onChanged: (v) => setD(() => city = v),
                )),
                if (kind == 'program') ...[
                  box(DropdownButtonFormField<String?>(
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: 'Teaching'),
                    items: const [
                      DropdownMenuItem<String?>(value: null, child: Text('—')),
                      DropdownMenuItem<String?>(value: 'campus', child: Text('Campus')),
                      DropdownMenuItem<String?>(value: 'distans', child: Text('Distance')),
                    ],
                    onChanged: (v) => setD(() => mode = v),
                  )),
                  box(DropdownButtonFormField<String?>(
                    initialValue: intake,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'New students start'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('—')),
                      for (final e in intakeLabels.entries)
                        DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setD(() => intake = v),
                  )),
                  box(TextField(
                      controller: length,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Length (years)', hintText: 'e.g. 3 or 3.5'))),
                ],
                box(TextField(
                    controller: seats,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: 'Seats',
                        hintText: kind == 'program' ? 'empty = automatic' : 'e.g. 1',
                        helperText: kind == 'program' ? 'Leave empty to work it out' : null))),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 12, runSpacing: 10, children: [
                box(TextField(controller: director, decoration: const InputDecoration(labelText: 'Programme director / chair'))),
                box(TextField(controller: directorEmail, decoration: const InputDecoration(labelText: 'Their email'))),
                box(TextField(controller: institution, decoration: const InputDecoration(labelText: 'Institution (e.g. IEM)'))),
              ]),
              const SizedBox(height: 10),
              TextField(controller: notes, maxLines: 3, minLines: 1, decoration: const InputDecoration(labelText: 'Notes')),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: cancelled,
                onChanged: (v) => setD(() => cancelled = v ?? false),
                title: const Text('Cancelled (not given any more)'),
              ),
              if (error != null) Text(error!, style: TextStyle(color: Colors.red.shade800)),
            ]),
          ),
        ),
        actions: [
          if (c != null)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              child: Text('Delete', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isEmpty) return setD(() => error = 'Write a name');
              if (length.text.trim().isNotEmpty && double.tryParse(length.text.replaceAll(',', '.')) == null) {
                return setD(() => error = 'Length must be a number, e.g. 3.5');
              }
              if (seats.text.trim().isNotEmpty && int.tryParse(seats.text.trim()) == null) {
                return setD(() => error = 'Seats must be a whole number');
              }
              Navigator.pop(ctx, 'save');
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  // Delete (only when editing)
  if (ok == 'delete' && c != null && context.mounted) {
    if (await confirm(context, 'Delete ${c.name}?',
            'Its seats, representatives on it and ALL its meetings (with attendance and agenda) are deleted. '
            'This cannot be undone.',
            ok: 'Delete') &&
        context.mounted &&
        await runAction(context, () => Repo.deleteCouncil(c.id), success: 'Deleted')) {
      return '';
    }
    return null;
  }
  if (ok != 'save' || !context.mounted) return null;
  String? id;
  String? t(TextEditingController x) => x.text.trim().isEmpty ? null : x.text.trim();
  final saved = await runAction(context, () async {
    id = await Repo.saveCouncil(c?.id, {
      'name': name.text.trim(),
      'type': kind,
      'city': city,
      'study_mode': kind == 'program' ? mode : null,
      'intake': kind == 'program' ? intake : null,
      'length_years': kind == 'program' && t(length) != null ? double.parse(length.text.replaceAll(',', '.')) : null,
      'seats': t(seats) == null ? null : int.parse(seats.text.trim()),
      'director_name': t(director),
      'director_email': t(directorEmail)?.toLowerCase(),
      'institution': t(institution),
      'notes': t(notes),
      'cancelled': cancelled,
    });
  }, success: 'Saved');
  return saved ? id : null;
}
