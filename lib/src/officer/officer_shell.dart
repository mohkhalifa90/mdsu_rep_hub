import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../push/push_service.dart';
import '../rep/more_page.dart' show TutoringBoard;
import '../shared/posts.dart';
import '../shared/channels_page.dart';
import '../shared/format.dart';
import '../shared/widgets.dart';
import 'admin_pages.dart';
import 'agenda_builder_page.dart';
import 'councils_page.dart';
import 'reports_page.dart';
import 'today_page.dart';

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

/// Control panel for the Head of Education: side rail on a computer, menu on a phone.
class OfficerShell extends StatefulWidget {
  final Profile me;
  const OfficerShell({super.key, required this.me});
  @override
  State<OfficerShell> createState() => _OfficerShellState();
}

class _OfficerShellState extends State<OfficerShell> {
  late Future<OfficerData> _f = OfficerData.load(widget.me);
  String _tab = 'today';
  String? _openMeeting; // agenda/<id> link
  int _refresh = 0;
  final _scaffold = GlobalKey<ScaffoldState>();

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
    ('today', Icons.today_outlined, 'Today'),
    ('reports', Icons.schedule, 'Time reports'),
    ('chat', Icons.forum_outlined, 'Channels'),
    ('posts', Icons.campaign_outlined, 'Posts'),
    ('agenda', Icons.event_note_outlined, 'Meetings'),
    ('followups', Icons.loop, 'Follow-ups'),
    ('reps', Icons.people_outline, 'Representatives'),
    ('councils', Icons.account_balance_outlined, 'Councils'),
    ('stats', Icons.insights_outlined, 'Statistics'),
    ('tutoring', Icons.school_outlined, 'Tutoring board'),
    ('settings', Icons.settings_outlined, 'Automations & settings'),
  ];

  int get _index => _dest.indexWhere((d) => d.$1 == _tab);

  void _goTo(String page) => setState(() {
        if (page != _tab) _openMeeting = null;
        _tab = page;
      });

  void _openLink(String link) {
    final parts = link.split('/');
    final page = parts.first;
    if (_dest.any((d) => d.$1 == page)) _goTo(page);
    if (page == 'agenda' && parts.length > 1) {
      setState(() {
        _openMeeting = parts[1];
        _refresh++; // rebuild the page so it opens the meeting
      });
    }
  }

  Widget _page(OfficerData d) => switch (_tab) {
        'reports' => ReportsPage(key: ValueKey('rp$_refresh'), data: d),
        'chat' => ChannelsPage(me: d.me, wide: MediaQuery.of(context).size.width > 800),
        'posts' => PostsPage(key: ValueKey('po$_refresh'), officer: true, councils: d.councils),
        'agenda' => AgendaBuilderPage(key: ValueKey('ag$_refresh'), data: d, openMeetingId: _openMeeting),
        'followups' => OfficerFollowUpsPage(key: ValueKey('fu$_refresh'), data: d),
        'reps' => RepsPage(key: ValueKey('re$_refresh'), data: d),
        'councils' => CouncilsPage(key: ValueKey('co$_refresh'), data: d, onChanged: _reload),
        'stats' => StatisticsPage(key: ValueKey('st$_refresh'), data: d, goTo: _openLink),
        'tutoring' => TutoringBoard(me: d.me),
        'settings' => SettingsPage(key: ValueKey('se$_refresh'), data: d, onChanged: _reload),
        _ => TodayPage(key: ValueKey('to$_refresh'), data: d, goTo: _openLink),
      };

  @override
  Widget build(BuildContext context) {
    return Loader<OfficerData>(
      future: _f,
      onRetry: _reload,
      builder: (context, d) {
        final width = MediaQuery.of(context).size.width;
        final phone = width < 720;
        final extended = width > 1100;
        final rail = NavigationRail(
          scrollable: true,
          extended: extended,
          selectedIndex: _index,
          labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
          onDestinationSelected: (i) => _goTo(_dest[i].$1),
          destinations: [
            for (final (_, icon, label) in _dest) NavigationRailDestination(icon: Icon(icon), label: Text(label)),
          ],
        );
        return Scaffold(
          key: _scaffold,
          appBar: AppBar(
            leading: phone
                ? IconButton(
                    tooltip: 'Menu', icon: const Icon(Icons.menu), onPressed: () => _scaffold.currentState?.openDrawer())
                : Padding(padding: const EdgeInsets.all(10), child: Image.asset('assets/logo_symbol.png')),
            title: Text(phone ? _dest[_index].$3 : 'Rep Hub · ${_dest[_index].$3}'),
            actions: [
              if (d.semester != null && !phone)
                Center(child: Padding(padding: const EdgeInsets.only(right: 12), child: Text(d.semester!.name))),
              NotificationBell(onOpen: _openLink),
              if (!phone) ...[
                IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh)),
                IconButton(
                    tooltip: 'Change my password',
                    onPressed: () => showChangePasswordDialog(context),
                    icon: const Icon(Icons.key_outlined)),
                IconButton(tooltip: 'Sign out', onPressed: Repo.signOut, icon: const Icon(Icons.logout)),
              ] else
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'refresh') _reload();
                    if (v == 'password') showChangePasswordDialog(context);
                    if (v == 'out') Repo.signOut();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'refresh', child: Text('Refresh')),
                    PopupMenuItem(value: 'password', child: Text('Change my password')),
                    PopupMenuItem(value: 'out', child: Text('Sign out')),
                  ],
                ),
            ],
          ),
          drawer: phone
              ? NavigationDrawer(
                  selectedIndex: _index,
                  onDestinationSelected: (i) {
                    _scaffold.currentState?.closeDrawer();
                    _goTo(_dest[i].$1);
                  },
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
                      child: Row(children: [
                        SizedBox(height: 32, child: Image.asset('assets/logo_symbol.png')),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(d.semester == null ? 'Rep Hub' : 'Rep Hub · ${d.semester!.name}',
                              style: Theme.of(context).textTheme.titleMedium),
                        ),
                      ]),
                    ),
                    for (final (_, icon, label) in _dest)
                      NavigationDrawerDestination(icon: Icon(icon), label: Text(label)),
                  ],
                )
              : null,
          body: phone
              ? _page(d)
              : Row(children: [
                  rail,
                  const VerticalDivider(width: 1),
                  Expanded(child: _page(d)),
                ]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
class _Stats {
  final List<ReportRow> reports;
  final List<Meeting> meetings;
  final List<Issue> issues;
  final List<AgendaItem> agenda;
  _Stats(this.reports, this.meetings, this.issues, this.agenda);
}

/// The numbers: KPIs, who has not submitted, upcoming meetings.
class StatisticsPage extends StatefulWidget {
  final OfficerData data;
  final void Function(String page) goTo;
  const StatisticsPage({super.key, required this.data, required this.goTo});
  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  late Future<_Stats> _f = _load();
  Future<_Stats> _load() async =>
      _Stats(await Repo.reportOverview(), await Repo.meetings(), await Repo.issues(), await Repo.agendaItems());

  @override
  Widget build(BuildContext context) {
    final s = widget.data.semester;
    return Loader<_Stats>(
      future: _f,
      onRetry: () => setState(() => _f = _load()),
      builder: (context, o) {
        final done = o.reports.where((r) => r.isDone).length;
        final minutes = o.reports.fold<int>(0, (a, r) => a + r.minutes);
        final payout = o.reports.fold<int>(0, (a, r) => a + r.amount);
        final notSubmitted = o.reports.where((r) => !r.isDone).toList();
        final openIssues = o.issues.where((i) => i.isOpen).length;
        final upcoming = o.meetings.where((m) => !m.isPast).take(6).toList();
        return ListView(padding: EdgeInsets.all(isNarrow(context) ? 12 : 24), children: [
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
                      onTap: () => widget.goTo('agenda/${m.id}'),
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
