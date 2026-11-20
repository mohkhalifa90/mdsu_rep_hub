import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/format.dart';
import '../shared/posts.dart';
import '../shared/widgets.dart';
import 'officer_shell.dart' show OfficerData;

class _Today {
  final List<ReportRow> reports;
  final List<Meeting> meetings;
  final List<Issue> issues;
  final List<AgendaItem> agenda;
  final List<Attendance> attendance;
  final List<Profile> people;
  final List<Post> posts;
  _Today(this.reports, this.meetings, this.issues, this.agenda, this.attendance, this.people, this.posts);
}

/// The officer's start page: what needs attention today, quick actions, next meetings
/// and the latest posts. The numbers live on the Statistics page.
class TodayPage extends StatefulWidget {
  final OfficerData data;
  final void Function(String page) goTo;
  const TodayPage({super.key, required this.data, required this.goTo});
  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  late Future<_Today> _f = _load();
  Future<_Today> _load() async => _Today(
        await Repo.reportOverview(),
        await Repo.meetings(),
        await Repo.issues(),
        await Repo.agendaItems(),
        await Repo.attendance(),
        await Repo.profiles(),
        await Repo.posts(limit: 3),
      );
  void _reload() => setState(() => _f = _load());

  Future<void> _remind() async {
    if (!await confirm(context, 'Send reminder?',
        'Every representative who has not submitted their time report gets a notification.',
        ok: 'Send')) {
      return;
    }
    try {
      final n = await Repo.remindUnsubmitted();
      if (mounted) showSnack(context, 'Reminder sent to $n representatives');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  String _greeting() {
    final h = DateTime.now().hour;
    final first = widget.data.me.fullName.trim().split(' ').first;
    final hello = h < 10 ? 'Good morning' : (h < 17 ? 'Hi' : 'Good evening');
    return first.isEmpty ? hello : '$hello, $first';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.data.semester;
    final narrow = isNarrow(context);
    return Loader<_Today>(
      future: _f,
      onRetry: _reload,
      builder: (context, o) {
        final upcoming = o.meetings.where((m) => !m.isPast).toList()..sort((a, b) => a.startsAt.compareTo(b.startsAt));
        final upcomingIds = {for (final m in upcoming) m.id};
        final notSubmitted = o.reports.where((r) => !r.isDone).length;
        final toReview = o.reports.where((r) => r.status == 'submitted').length;
        final waiting = o.people.where((p) => !p.active).length;
        final escalated = o.issues.where((i) => i.status == 'escalated').length;
        final newItems = o.agenda.where((a) => a.status == 'new' && upcomingIds.contains(a.meetingId)).length;
        final soon = upcoming
            .where((m) => !m.inputRequested && m.startsAt.difference(DateTime.now()).inDays <= 14)
            .toList();
        final days = s == null ? null : daysUntil(s.reportDeadline);

        // ---- what needs Dania's attention, most urgent first
        final todo = <Widget>[
          if (toReview > 0)
            _Todo(Icons.fact_check_outlined, Colors.orange.shade800, '$toReview time reports to review',
                'Approve them or send them back with a comment.', 'Open', () => widget.goTo('reports')),
          if (days != null && days >= 0 && days <= 14 && notSubmitted > 0)
            _Todo(Icons.alarm, Colors.red.shade700, 'Deadline in $days days – $notSubmitted not submitted',
                'A reminder usually helps.', 'Send reminder', _remind),
          if (escalated > 0)
            _Todo(Icons.priority_high, Colors.red.shade700, '$escalated escalated follow-ups',
                'The university has not answered for several meetings.', 'Open', () => widget.goTo('followups')),
          for (final m in soon)
            _Todo(Icons.record_voice_over_outlined, Colors.blue.shade700,
                'Ask for topics: ${m.title}', '${fmtDateTime(m.startsAt)} · reps have not been asked yet.',
                'Open', () => widget.goTo('agenda')),
          if (newItems > 0)
            _Todo(Icons.inbox_outlined, Colors.blue.shade700, '$newItems new topics from reps',
                'Include or decline them in the Agenda builder.', 'Open', () => widget.goTo('agenda')),
          if (waiting > 0)
            _Todo(Icons.person_add_alt, Colors.teal.shade700, '$waiting accounts not active',
                'New sign-ups wait here until you switch them on.', 'Open', () => widget.goTo('reps')),
        ];

        final actions = Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
              onPressed: () => widget.goTo('agenda'), icon: const Icon(Icons.event), label: const Text('New meeting')),
          FilledButton.tonalIcon(
              onPressed: () async {
                if (await showNewPostDialog(context, councils: widget.data.councils)) _reload();
              },
              icon: const Icon(Icons.campaign_outlined),
              label: const Text('New post')),
          OutlinedButton.icon(
              onPressed: () => widget.goTo('reports'),
              icon: const Icon(Icons.download),
              label: const Text('Time reports (Excel)')),
          OutlinedButton.icon(
              onPressed: _remind,
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Remind unsubmitted')),
        ]);

        final attention = Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SectionTitle('Needs your attention'),
              if (todo.isEmpty) const EmptyState('Nothing needs you right now 🎉'),
              ...todo,
            ]),
          ),
        );

        final meetings = Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SectionTitle('Next meetings'),
              if (upcoming.isEmpty) const EmptyState('No meetings planned'),
              for (final m in upcoming.take(5)) _meetingTile(m, o),
            ]),
          ),
        );

        final posts = Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SectionTitle('Latest posts',
                  trailing: TextButton(onPressed: () => widget.goTo('posts'), child: const Text('See all'))),
              if (o.posts.isEmpty) const EmptyState('No posts yet'),
              for (final p in o.posts)
                PostCard(post: p, audience: p.councilId == null ? 'All representatives' : widget.data.council(p.councilId)?.name),
            ]),
          ),
        );

        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(padding: EdgeInsets.all(narrow ? 12 : 24), children: [
            Text(_greeting(), style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 2),
            Text([fmtDateY(DateTime.now()), if (s != null) s.name, if (days != null && days >= 0) 'report deadline in $days days']
                .join(' · ')),
            const SizedBox(height: 16),
            actions,
            const SizedBox(height: 16),
            LayoutBuilder(builder: (context, c) {
              if (c.maxWidth < 900) return Column(children: [attention, meetings, posts]);
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(children: [attention, posts])),
                const SizedBox(width: 12),
                Expanded(child: meetings),
              ]);
            }),
          ]),
        );
      },
    );
  }

  Widget _meetingTile(Meeting m, _Today o) {
    final topics = o.agenda.where((a) => a.meetingId == m.id && a.status != 'declined').length;
    final att = o.attendance.where((a) => a.meetingId == m.id);
    final room = att.where((a) => a.mode == 'offline').length;
    final online = att.where((a) => a.mode == 'online').length;
    final absent = att.where((a) => a.mode == 'absent').length;
    Widget chip(IconData i, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 16),
          const SizedBox(width: 4),
          Text(t, style: Theme.of(context).textTheme.bodySmall),
        ]);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('${m.title} · ${widget.data.council(m.councilId)?.name ?? ''}'),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(fmtDateTime(m.startsAt)),
        const SizedBox(height: 4),
        Wrap(spacing: 12, runSpacing: 4, children: [
          chip(Icons.topic_outlined, '$topics topics'),
          chip(Icons.meeting_room_outlined, '$room in room'),
          chip(Icons.videocam_outlined, '$online online'),
          chip(Icons.event_busy_outlined, '$absent can\'t'),
          if (!m.inputRequested) chip(Icons.schedule, 'not asked yet'),
        ]),
      ]),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => widget.goTo('agenda'),
    );
  }
}

class _Todo extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String sub;
  final String action;
  final VoidCallback onTap;
  const _Todo(this.icon, this.color, this.title, this.sub, this.action, this.onTap);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(radius: 18, backgroundColor: color.withValues(alpha: 0.12), child: Icon(icon, color: color, size: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(sub, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onTap, child: Text(action)),
        ]),
      );
}
