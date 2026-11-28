import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../push/push_service.dart';
import '../push/web_push_card.dart';
import '../shared/posts.dart';
import '../shared/badges.dart';
import '../shared/channels_page.dart';
import '../shared/format.dart';
import '../shared/theme.dart';
import '../shared/tour.dart';
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
  String? _openChannel, _focusMessage; // chat/<channel>/<message> link
  int _refresh = 0;
  RepData? _data;

  @override
  void initState() {
    super.initState();
    PushService.instance.onOpenLink = (link) {
      if (_data != null && mounted) _openLink(link, _data!);
    };
    Badges.instance.start();
    // first time here: a short welcome tour
    if (widget.me.uiPrefs['onboarded'] != true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showTour(context, repTour);
      });
    }
  }

  @override
  void dispose() {
    Badges.instance.stop();
    super.dispose();
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
    if (link.startsWith('chat/')) {
      final parts = link.split('/');
      return setState(() {
        _tab = 3;
        _openChannel = parts[1];
        _focusMessage = parts.length > 2 ? parts[2] : null;
        _refresh++;
      });
    }
    if (link.startsWith('posts')) {
      final parts = link.split('/');
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => PostsPage(
                  councils: d.councils, standalone: true, focusId: parts.length > 1 ? parts[1] : null)));
      return;
    }
    if (link == 'more') return setState(() => _tab = 4);
    if (link == 'followups' || link.startsWith('followups/')) {
      final parts = link.split('/');
      setState(() => _tab = 4);
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Follow-ups')),
                  body: RepFollowUpsPage(data: d, openIssueId: parts.length > 1 ? parts[1] : null))));
      return;
    }
    if (link == 'tutoring' || link.startsWith('tutoring/')) {
      final parts = link.split('/');
      setState(() => _tab = 4);
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Tutoring board')),
                  body: TutoringBoard(me: d.me, focusId: parts.length > 1 ? parts[1] : null))));
      return;
    }
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
          ChannelsPage(
              key: ValueKey('ch$_refresh'), me: d.me, openChannelId: _openChannel, focusId: _focusMessage),
          MorePage(data: d, onChanged: _reload),
        ];
        const titles = ['Rep Hub', 'My hours', 'Meetings', 'Channels', 'More'];
        return Scaffold(
          appBar: AppBar(
            leading: Padding(padding: const EdgeInsets.all(12), child: Image.asset('assets/logo_symbol.png')),
            title: Text(titles[_tab]),
            actions: [NotificationBell(onOpen: (l) => _openLink(l, d))],
          ),
          body: SafeArea(child: pageSwitch(_tab, pages[_tab])),
          bottomNavigationBar: ListenableBuilder(
            listenable: Badges.instance,
            builder: (context, _) => NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: (i) {
                setState(() {
                  _tab = i;
                  if (i != 2) _openMeeting = null;
                  if (i != 3) _openChannel = _focusMessage = null;
                });
                Badges.instance.refresh();
              },
              destinations: [
                const NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
                const NavigationDestination(icon: Icon(Icons.schedule), label: 'Hours'),
                NavigationDestination(
                    icon: badgeIcon(Icons.event_note_outlined, Badges.instance.of('meetings')), label: 'Meetings'),
                NavigationDestination(
                    icon: badgeIcon(Icons.forum_outlined, Badges.instance.of('channels')), label: 'Channels'),
                const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
              ],
            ),
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
  final Map<String, String> attendance; // meeting id → offline | online | absent
  final List<Post> posts; // latest from the Head of Education
  _HomeData(this.report, this.meetings, this.loggedMeetingIds, this.agendaMeetingIds, this.unreadAnnouncements,
      this.posts, this.attendance);
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
      await Repo.myAttendance(),
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
                'Open Channels to read them', 'Read', () => widget.goTo(3)));
          }
          bool attends(Meeting m) => h.attendance[m.id] == 'offline' || h.attendance[m.id] == 'online';
          // Only meetings you said you attend (or the Head of Education added you to) can be logged
          for (final m in h.meetings.where((m) =>
              m.isPast && attends(m) && now.difference(m.startsAt).inDays <= 30 && !h.loggedMeetingIds.contains(m.id))) {
            todos.add(_todo(context, Icons.timer_outlined, 'Log time for ${m.title}',
                '${fmtDate(m.startsAt)} · upload your notes too', 'Log now', () async {
              await showLogTimeSheet(context, d, meetingId: m.id);
              widget.onChanged();
            }));
          }
          for (final m in h.meetings.where((m) => !m.isPast && m.startsAt.difference(now).inDays <= 21)) {
            if (h.attendance[m.id] == null) {
              todos.add(_todo(context, Icons.how_to_reg_outlined, 'Will you attend ${m.title}?',
                  '${fmtDateTime(m.startsAt)} · in the room, online or not', 'Answer', () => widget.openMeeting(m.id)));
            } else if (attends(m) && !h.agendaMeetingIds.contains(m.id)) {
              todos.add(_todo(context, Icons.record_voice_over_outlined, 'Collect input for ${m.title}',
                  'Send topics by ${fmtDate(m.inputDeadline)}', 'Open', () => widget.openMeeting(m.id)));
            }
          }
          // the report deadline is coming and the report is not sent yet
          final sem = d.semester;
          if (sem != null && (r?.status ?? 'draft') == 'draft') {
            final left = daysUntil(sem.reportDeadline);
            if (left >= 0 && left <= 14) {
              todos.insert(0, _todo(context, Icons.send_outlined, 'Send your time report',
                  '$left day${left == 1 ? '' : 's'} left · ${fmtHours(minutes)} h logged', 'Open', () => widget.goTo(1),
                  urgent: left <= 3));
            }
          }
          if (!d.me.quizPassed) {
            todos.add(_todo(context, Icons.quiz_outlined, 'Pass this semester\'s quiz',
                'Needed to be paid · ask the Head of Education for the link', 'OK', () {}, showAction: false));
          }
          if (!d.me.isMember) {
            todos.add(_todo(context, Icons.card_membership_outlined, 'Become a union member',
                'Only members are paid for their hours', 'OK', () {}, showAction: false));
          }
          final upcoming = h.meetings.where((m) => !m.isPast).take(4).toList();
          final next = upcoming.isEmpty ? null : upcoming.first;

          final first = widget.data.me.fullName.trim().split(' ').first;
          return CenteredList(children: [
            BannerHeader(
              height: 110,
              title: first.isEmpty ? 'Hi!' : 'Hi, $first',
              subtitle: [fmtDateY(DateTime.now()), if (upcoming.isNotEmpty) 'next meeting ${fmtDate(upcoming.first.startsAt)}']
                  .join(' · '),
            ),
            const SizedBox(height: 12),
            // ---- what needs me now ----
            if (todos.isEmpty)
              Card(
                color: Color.alphaBlend(softBg(context, Colors.green), t.cardColor),
                child: const ListTile(
                  leading: Icon(Icons.task_alt, color: Colors.green),
                  title: Text('You\'re all caught up'),
                  subtitle: Text('Nothing needs you right now'),
                ),
              )
            else ...[
              SectionTitle('Needs your attention (${todos.length})'),
              ...todos.take(_showAllTodos ? todos.length : 3),
              if (todos.length > 3)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                      onPressed: () => setState(() => _showAllTodos = !_showAllTodos),
                      child: Text(_showAllTodos ? 'Show less' : 'Show all ${todos.length}')),
                ),
            ],
            if (next != null) ...[const SizedBox(height: 4), _nextMeeting(context, next, h.attendance[next.id])],
            const SizedBox(height: 8),
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
            if (upcoming.isEmpty) const EmptyState('No upcoming meetings', icon: Icons.event_available_outlined),
            for (final m in upcoming.skip(1))
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

  bool _showAllTodos = false;

  Widget _todo(BuildContext context, IconData icon, String title, String sub, String action, VoidCallback onTap,
      {bool urgent = false, bool showAction = true}) {
    final c = urgent ? Colors.red.shade700 : Colors.orange.shade800;
    return Card(
      child: ListTile(
        leading: CircleAvatar(backgroundColor: c.withValues(alpha: 0.12), child: Icon(icon, color: c, size: 20)),
        title: Text(title),
        subtitle: Text(sub),
        onTap: showAction ? onTap : null,
        trailing: showAction ? TextButton(onPressed: onTap, child: Text(action)) : null,
      ),
    );
  }

  /// The next meeting, with a countdown and my answer
  Widget _nextMeeting(BuildContext context, Meeting m, String? mode) {
    final t = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(m.startsAt.year, m.startsAt.month, m.startsAt.day);
    final days = day.difference(today).inDays;
    final when = days == 0 ? 'Today' : days == 1 ? 'Tomorrow' : 'In $days days';
    final (label, color) = switch (mode) {
      'offline' => ('In the room', Colors.green),
      'online' => ('Online', Colors.blue),
      'absent' => ('Not attending', Colors.grey),
      _ => ('Not answered', Colors.orange),
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => widget.openMeeting(m.id),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              width: 58,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                  color: t.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Text(fmtMonth(m.startsAt), style: t.textTheme.labelSmall),
                Text('${m.startsAt.day}',
                    style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              ]),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('NEXT MEETING · ${when.toUpperCase()}',
                    style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.primary, letterSpacing: 0.6)),
                const SizedBox(height: 2),
                Text(m.title, style: t.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text('${fmtTime(m.startsAt)}${m.location == null ? '' : ' · ${m.location}'}',
                    style: t.textTheme.bodySmall),
                const SizedBox(height: 6),
                StatusChip(label, color),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}
