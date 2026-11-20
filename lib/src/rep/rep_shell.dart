import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../push/push_service.dart';
import '../push/web_push_card.dart';
import '../shared/posts.dart';
import '../shared/channels_page.dart';
import '../shared/format.dart';
import '../shared/widgets.dart';
import 'hours_page.dart';
import 'more_page.dart';
import 'rep_agenda_page.dart';

/// Data every rep page needs, loaded once by the shell.
class RepData {
  final Profile me;
  final Semester? semester;
  final List<Council> councils;
  final Set<String> myCouncilIds;
  RepData(this.me, this.semester, this.councils, this.myCouncilIds);

  List<Council> get myCouncils => councils.where((c) => myCouncilIds.contains(c.id)).toList();
  Council? council(String? id) {
    for (final c in councils) {
      if (c.id == id) return c;
    }
    return null;
  }

  static Future<RepData> load(Profile me) async =>
      RepData(me, await Repo.semester(), await Repo.councils(), await Repo.councilIdsOf(me.id));
}

class RepShell extends StatefulWidget {
  final Profile me;
  const RepShell({super.key, required this.me});
  @override
  State<RepShell> createState() => _RepShellState();
}

class _RepShellState extends State<RepShell> {
  late Future<RepData> _f = RepData.load(widget.me);
  int _tab = 0;
  String? _openMeeting; // agenda deep link
  int _refresh = 0;
  RepData? _data;

  @override
  void initState() {
    super.initState();
    PushService.instance.onOpenLink = (link) {
      if (_data != null && mounted) _openLink(link, _data!);
    };
  }

  void _reload() => setState(() {
        _f = RepData.load(widget.me);
        _refresh++;
      });

  /// Handles links from notifications (see notifications.link in the database).
  void _openLink(String link, RepData d) {
    if (link == 'hours') return setState(() => _tab = 1);
    if (link.startsWith('agenda/')) {
      return setState(() {
        _tab = 2;
        _openMeeting = link.substring(7);
      });
    }
    if (link.startsWith('chat/')) return setState(() => _tab = 3);
    if (link.startsWith('posts')) {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => PostsPage(councils: d.councils, standalone: true)));
      return;
    }
    if (link == 'followups' || link == 'more') return setState(() => _tab = 4);
    if (link.startsWith('log/')) {
      setState(() => _tab = 1);
      showLogTimeSheet(context, d, meetingId: link.substring(4)).then((_) => _reload());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Loader<RepData>(
      future: _f,
      onRetry: _reload,
      builder: (context, d) {
        _data = d;
        final pages = [
          RepHomePage(
              key: ValueKey('home$_refresh'),
              data: d,
              goTo: (i) => setState(() => _tab = i),
              openMeeting: (id) => _openLink('agenda/$id', d),
              onChanged: _reload),
          HoursPage(key: ValueKey('hours$_refresh'), data: d),
          RepAgendaPage(key: ValueKey('agenda$_refresh'), data: d, openMeetingId: _openMeeting),
          ChannelsPage(me: d.me),
          MorePage(data: d, onChanged: _reload),
        ];
        const titles = ['Rep Hub', 'My hours', 'Agenda input', 'Channels', 'More'];
        return Scaffold(
          appBar: AppBar(
            leading: Padding(padding: const EdgeInsets.all(12), child: Image.asset('assets/logo_symbol.png')),
            title: Text(titles[_tab]),
            actions: [NotificationBell(onOpen: (l) => _openLink(l, d))],
          ),
          body: SafeArea(child: pages[_tab]),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() {
              _tab = i;
              if (i != 2) _openMeeting = null;
            }),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.schedule), label: 'Hours'),
              NavigationDestination(icon: Icon(Icons.list_alt), label: 'Agenda'),
              NavigationDestination(icon: Icon(Icons.forum_outlined), label: 'Channels'),
              NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
class _HomeData {
  final ReportRow? report;
  final List<Meeting> meetings;
  final Set<String> loggedMeetingIds;
  final Set<String> agendaMeetingIds; // meetings with my topics or my "no topics" answer
  final int unreadAnnouncements;
  final List<Post> posts; // latest from the Head of Education
  _HomeData(this.report, this.meetings, this.loggedMeetingIds, this.agendaMeetingIds, this.unreadAnnouncements,
      this.posts);
}

class RepHomePage extends StatefulWidget {
  final RepData data;
  final void Function(int tab) goTo;
  final void Function(String meetingId) openMeeting;
  final VoidCallback onChanged;
  const RepHomePage(
      {super.key, required this.data, required this.goTo, required this.openMeeting, required this.onChanged});
  @override
  State<RepHomePage> createState() => _RepHomePageState();
}

class _RepHomePageState extends State<RepHomePage> {
  late Future<_HomeData> _f = _load();

  Future<_HomeData> _load() async {
    final d = widget.data;
    final entries =
        d.semester == null ? <TimeEntry>[] : await Repo.entries(userId: d.me.id, semesterId: d.semester!.id);
    final agenda = await Repo.agendaItems();
    return _HomeData(
      await Repo.myReport(),
      await Repo.meetings(),
      entries.map((e) => e.meetingId).whereType<String>().toSet(),
      {...agenda.where((a) => a.userId == d.me.id).map((a) => a.meetingId), ...await Repo.myNoInput()},
      await Repo.unreadAnnouncements(),
      await Repo.posts(limit: 3),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final t = Theme.of(context);
    return RefreshIndicator(
      onRefresh: () async => setState(() => _f = _load()),
      child: Loader<_HomeData>(
        future: _f,
        onRetry: () => setState(() => _f = _load()),
        builder: (context, h) {
          final r = h.report;
          final minutes = r?.minutes ?? 0;
          final now = DateTime.now();
          final todos = <Widget>[];

          if (r?.status == 'returned') {
            todos.add(_todo(context, Icons.undo, 'Your report was returned', r?.reviewerComment ?? '',
                'Fix & resubmit', () => widget.goTo(1)));
          }
          if (h.unreadAnnouncements > 0) {
            todos.add(_todo(context, Icons.campaign_outlined, '${h.unreadAnnouncements} unread announcement(s)',
                'Confirm you have read them', 'Read', () => widget.goTo(3)));
          }
          for (final m in h.meetings.where((m) =>
              m.isPast && now.difference(m.startsAt).inDays <= 30 && !h.loggedMeetingIds.contains(m.id))) {
            todos.add(_todo(context, Icons.timer_outlined, 'Log time for ${m.title}',
                '${fmtDate(m.startsAt)} · upload your notes too', 'Log now', () async {
              await showLogTimeSheet(context, d, meetingId: m.id);
              widget.onChanged();
            }));
          }
          for (final m in h.meetings.where((m) =>
              !m.isPast && m.startsAt.difference(now).inDays <= 21 && !h.agendaMeetingIds.contains(m.id))) {
            todos.add(_todo(context, Icons.record_voice_over_outlined, 'Collect input for ${m.title}',
                'Send topics by ${fmtDate(m.inputDeadline)}', 'Open', () => widget.openMeeting(m.id)));
          }
          final upcoming = h.meetings.where((m) => !m.isPast).take(4).toList();

          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              color: t.colorScheme.primary,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: DefaultTextStyle(
                  style: TextStyle(color: t.colorScheme.onPrimary),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${d.semester?.name ?? 'No active semester'} · time report'),
                    const SizedBox(height: 6),
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text('${fmtHours(minutes)} h',
                          style: TextStyle(
                              fontSize: 32, fontWeight: FontWeight.bold, color: t.colorScheme.onPrimary)),
                      const Spacer(),
                      Text(reportStatusLabels[r?.status ?? 'draft'] ?? ''),
                    ]),
                    Text('≈ ${sek(r?.amount ?? 0)}${d.me.isMember ? '' : ' (not a union member – unpaid)'}'),
                    if (d.semester != null)
                      Text('${daysUntil(d.semester!.reportDeadline)} days to deadline '
                          '(${fmtDateY(d.semester!.reportDeadline)})'),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: (minutes / 60 / 25).clamp(0, 1).toDouble(),
                      backgroundColor: Colors.white24,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 4),
                    const Text('Typical semester: 20–25 hours', style: TextStyle(fontSize: 12)),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (d.semester != null)
              FilledButton.icon(
                onPressed: () async {
                  if (await showLogTimeSheet(context, d)) widget.onChanged();
                },
                icon: const Icon(Icons.add),
                label: const Padding(
                    padding: EdgeInsets.all(10), child: Text('Log time – meeting, task, material…')),
              ),
            const WebPushCard(),
            if (todos.isNotEmpty) ...[const SectionTitle('To do'), ...todos],
            if (h.posts.isNotEmpty) ...[
              SectionTitle('From the Head of Education',
                  trailing: TextButton(
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => PostsPage(councils: d.councils, standalone: true))),
                    child: const Text('See all'),
                  )),
              for (final p in h.posts.take(2)) PostCard(post: p),
            ],
            const SectionTitle('Upcoming meetings'),
            if (upcoming.isEmpty) const EmptyState('No upcoming meetings'),
            for (final m in upcoming)
              Card(
                child: ListTile(
                  title: Text(m.title),
                  subtitle: Text('${fmtDateTime(m.startsAt)} · ${m.location ?? ''}\n'
                      '${d.council(m.councilId)?.name ?? ''}'),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => widget.openMeeting(m.id),
                ),
              ),
          ]);
        },
      ),
    );
  }

  Widget _todo(BuildContext context, IconData icon, String title, String sub, String action, VoidCallback onTap) =>
      Card(
        child: ListTile(
          leading: Icon(icon, color: Colors.orange.shade800),
          title: Text(title),
          subtitle: Text(sub),
          trailing: TextButton(onPressed: onTap, child: Text(action)),
        ),
      );
}
