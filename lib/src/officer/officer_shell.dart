import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../push/push_service.dart';
import '../rep/more_page.dart' show TutoringBoard;
import '../shared/channels_page.dart';
import '../shared/format.dart';
import '../shared/widgets.dart';
import 'admin_pages.dart';
import 'agenda_builder_page.dart';
import 'councils_page.dart';
import 'reports_page.dart';

class OfficerData {
  final Profile me;
  final Semester? semester;
  final List<Council> councils;
  OfficerData(this.me, this.semester, this.councils);
  Council? council(String? id) {
    for (final c in councils) {
      if (c.id == id) return c;
    }
    return null;
  }

  static Future<OfficerData> load(Profile me) async => OfficerData(me, await Repo.semester(), await Repo.councils());
}

/// Desktop control panel for the Head of Education.
class OfficerShell extends StatefulWidget {
  final Profile me;
  const OfficerShell({super.key, required this.me});
  @override
  State<OfficerShell> createState() => _OfficerShellState();
}

class _OfficerShellState extends State<OfficerShell> {
  late Future<OfficerData> _f = OfficerData.load(widget.me);
  int _tab = 0;
  int _refresh = 0;

  @override
  void initState() {
    super.initState();
    PushService.instance.onOpenLink = (link) {
      if (mounted) _openLink(link);
    };
  }

  void _reload() => setState(() {
        _f = OfficerData.load(widget.me);
        _refresh++;
      });

  static const _dest = [
    (Icons.dashboard_outlined, 'Overview'),
    (Icons.schedule, 'Time reports'),
    (Icons.forum_outlined, 'Channels'),
    (Icons.list_alt, 'Agenda builder'),
    (Icons.loop, 'Follow-ups'),
    (Icons.people_outline, 'Representatives'),
    (Icons.account_balance_outlined, 'Councils'),
    (Icons.school_outlined, 'Tutoring board'),
    (Icons.settings_outlined, 'Automations & settings'),
  ];

  void _openLink(String link) {
    if (link == 'reports') setState(() => _tab = 1);
    if (link.startsWith('chat/')) setState(() => _tab = 2);
    if (link.startsWith('agenda/')) setState(() => _tab = 3);
    if (link == 'followups') setState(() => _tab = 4);
  }

  @override
  Widget build(BuildContext context) {
    return Loader<OfficerData>(
      future: _f,
      onRetry: _reload,
      builder: (context, d) {
        final pages = <Widget>[
          OverviewPage(key: ValueKey('ov$_refresh'), data: d, goTo: (i) => setState(() => _tab = i)),
          ReportsPage(key: ValueKey('rp$_refresh'), data: d),
          ChannelsPage(me: d.me, wide: MediaQuery.of(context).size.width > 800),
          AgendaBuilderPage(key: ValueKey('ag$_refresh'), data: d),
          OfficerFollowUpsPage(key: ValueKey('fu$_refresh'), data: d),
          RepsPage(key: ValueKey('re$_refresh'), data: d),
          CouncilsPage(key: ValueKey('co$_refresh'), data: d, onChanged: _reload),
          TutoringBoard(me: d.me),
          SettingsPage(key: ValueKey('se$_refresh'), data: d, onChanged: _reload),
        ];
        final extended = MediaQuery.of(context).size.width > 1100;
        return Scaffold(
          appBar: AppBar(
            leading: Padding(padding: const EdgeInsets.all(10), child: Image.asset('assets/logo_symbol.png')),
            title: Text('Rep Hub · ${_dest[_tab].$2}'),
            actions: [
              if (d.semester != null)
                Center(child: Padding(padding: const EdgeInsets.only(right: 12), child: Text(d.semester!.name))),
              NotificationBell(onOpen: _openLink),
              IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh)),
              IconButton(
                  tooltip: 'Change my password',
                  onPressed: () => showChangePasswordDialog(context),
                  icon: const Icon(Icons.key_outlined)),
              IconButton(tooltip: 'Sign out', onPressed: Repo.signOut, icon: const Icon(Icons.logout)),
            ],
          ),
          body: Row(children: [
            NavigationRail(
              extended: extended,
              selectedIndex: _tab,
              labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
              onDestinationSelected: (i) => setState(() => _tab = i),
              destinations: [
                for (final (icon, label) in _dest) NavigationRailDestination(icon: Icon(icon), label: Text(label)),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: pages[_tab]),
          ]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
class _Overview {
  final List<ReportRow> reports;
  final List<Meeting> meetings;
  final List<Issue> issues;
  final List<AgendaItem> agenda;
  _Overview(this.reports, this.meetings, this.issues, this.agenda);
}

class OverviewPage extends StatefulWidget {
  final OfficerData data;
  final void Function(int) goTo;
  const OverviewPage({super.key, required this.data, required this.goTo});
  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  late Future<_Overview> _f = _load();
  Future<_Overview> _load() async =>
      _Overview(await Repo.reportOverview(), await Repo.meetings(), await Repo.issues(), await Repo.agendaItems());

  @override
  Widget build(BuildContext context) {
    final s = widget.data.semester;
    return Loader<_Overview>(
      future: _f,
      onRetry: () => setState(() => _f = _load()),
      builder: (context, o) {
        final done = o.reports.where((r) => r.isDone).length;
        final minutes = o.reports.fold<int>(0, (a, r) => a + r.minutes);
        final payout = o.reports.fold<int>(0, (a, r) => a + r.amount);
        final notSubmitted = o.reports.where((r) => !r.isDone).toList();
        final openIssues = o.issues.where((i) => i.isOpen).length;
        final upcoming = o.meetings.where((m) => !m.isPast).take(6).toList();
        return ListView(padding: const EdgeInsets.all(24), children: [
          Wrap(spacing: 12, runSpacing: 12, children: [
            Kpi(label: 'Active representatives', value: '${o.reports.length}',
                sub: '${o.reports.where((r) => !r.isMember).length} not union members'),
            Kpi(label: 'Time reports submitted', value: '$done/${o.reports.length}'),
            Kpi(label: 'Hours logged', value: '${fmtHours(minutes)} h', sub: 'live, incl. drafts'),
            Kpi(label: 'Estimated payout', value: sek(payout),
                sub: s == null ? null : '${s.hourlyRate} SEK/h · ${s.halfHourRate} per started ½ h'),
            if (s != null)
              Kpi(label: 'Days to deadline', value: '${daysUntil(s.reportDeadline)}', sub: fmtDateY(s.reportDeadline)),
            Kpi(label: 'Open follow-ups', value: '$openIssues',
                sub: '${o.issues.where((i) => i.status == 'escalated').length} escalated'),
          ]),
          LayoutBuilder(builder: (context, c) {
            final left = Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SectionTitle('Not submitted yet',
                      trailing: FilledButton.tonalIcon(
                        onPressed: () async {
                          try {
                            final n = await Repo.remindUnsubmitted();
                            if (context.mounted) showSnack(context, 'Reminder sent to $n representatives');
                          } catch (e) {
                            if (context.mounted) showSnack(context, errorText(e));
                          }
                        },
                        icon: const Icon(Icons.notifications_active_outlined),
                        label: const Text('Send reminder'),
                      )),
                  if (o.reports.isEmpty)
                    const EmptyState('No active representatives yet')
                  else if (notSubmitted.isEmpty)
                    const EmptyState('Everyone has submitted 🎉'),
                  for (final r in notSubmitted)
                    ListTile(
                      dense: true,
                      title: Text(r.fullName),
                      subtitle: Text(r.program ?? ''),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        StatusChip.report(r.status),
                        const SizedBox(width: 12),
                        Text(fmtMinutes(r.minutes)),
                      ]),
                    ),
                ]),
              ),
            );
            final right = Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SectionTitle('Upcoming meetings'),
                  if (upcoming.isEmpty) const EmptyState('No meetings planned'),
                  for (final m in upcoming)
                    ListTile(
                      dense: true,
                      title: Text(m.title),
                      subtitle: Text('${fmtDateTime(m.startsAt)} · ${widget.data.council(m.councilId)?.name ?? ''}'),
                      trailing: Text('${o.agenda.where((a) => a.meetingId == m.id).length} rep items'),
                      onTap: () => widget.goTo(3),
                    ),
                ]),
              ),
            );
            return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: c.maxWidth > 900
                  ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: left),
                      const SizedBox(width: 12),
                      Expanded(child: right),
                    ])
                  : Column(children: [left, right]),
            );
          }),
        ]);
      },
    );
  }
}
