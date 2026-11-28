import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../push/push_service.dart';
import '../rep/more_page.dart' show TutoringBoard;
import '../shared/posts.dart';
import '../shared/badges.dart';
import '../shared/channels_page.dart';
import '../shared/theme.dart';
import '../shared/tour.dart';
import '../shared/widgets.dart';
import 'admin_pages.dart';
import 'quick_search.dart';
import 'agenda_builder_page.dart';
import 'reports_page.dart';
import 'programmes_page.dart';
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

  static Future<OfficerData> load(Profile me) async {
    // study years move up with the date (Aug/Jan): bring them up to date when the panel opens
    await Repo.refreshStudyYears();
    return OfficerData(me, await Repo.semester(), await Repo.councils());
  }
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
  String? _linkArg; // from a notification: meeting, channel, post or tutoring id
  String? _linkArg2; // the message inside a channel
  int _refresh = 0;
  final _scaffold = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    PushService.instance.onOpenLink = (link) {
      if (mounted) _openLink(link);
    };
    Badges.instance.start();
    if (widget.me.uiPrefs['onboarded'] != true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showTour(context, officerTour);
      });
    }
  }

  @override
  void dispose() {
    Badges.instance.stop();
    super.dispose();
  }

  /// Tab icon with the number of things waiting there
  Widget _icon(String key, IconData icon) => badgeIcon(
      icon,
      switch (key) {
        'reports' => Badges.instance.of('reports'),
        'reps' => Badges.instance.of('signups'),
        'chat' => Badges.instance.of('channels'),
        'followups' => Badges.instance.of('followups'),
        _ => 0,
      });

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
    ('programmes', Icons.event_seat_outlined, 'Programmes & seats'),
    ('tutoring', Icons.school_outlined, 'Tutoring board'),
    ('settings', Icons.settings_outlined, 'Automations & settings'),
  ];

  int get _index => _dest.indexWhere((d) => d.$1 == _tab);

  void _goTo(String page) => setState(() {
        Badges.instance.refresh();
        if (page != _tab) {
          _linkArg = null;
          _linkArg2 = null;
        }
        _tab = page;
      });

  void _openLink(String link) {
    final parts = link.split('/');
    final page = parts.first;
    if (_dest.any((d) => d.$1 == page)) _goTo(page);
    if (parts.length > 1) {
      setState(() {
        _linkArg = parts[1];
        _linkArg2 = parts.length > 2 ? parts[2] : null;
        _refresh++; // rebuild the page so it opens the item
      });
    }
  }

  Widget _page(OfficerData d) => switch (_tab) {
        'reports' => ReportsPage(key: ValueKey('rp$_refresh'), data: d),
        'chat' => ChannelsPage(
            key: ValueKey('ch$_refresh'),
            me: d.me,
            wide: MediaQuery.of(context).size.width > 800,
            openChannelId: _linkArg,
            focusId: _linkArg2),
        'posts' => PostsPage(key: ValueKey('po$_refresh'), officer: true, councils: d.councils, focusId: _linkArg),
        'agenda' => AgendaBuilderPage(key: ValueKey('ag$_refresh'), data: d, openMeetingId: _linkArg),
        'followups' => OfficerFollowUpsPage(key: ValueKey('fu$_refresh'), data: d, openIssueId: _linkArg),
        'reps' => RepsPage(key: ValueKey('re$_refresh'), data: d, initialSearch: _linkArg),
        'programmes' =>
          ProgrammesPage(key: ValueKey('pr$_refresh'), data: d, onChanged: _reload, openCouncilId: _linkArg),
        'tutoring' => TutoringBoard(key: ValueKey('tu$_refresh'), me: d.me, focusId: _linkArg),
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
        Widget rail() => NavigationRail(
          scrollable: true,
          extended: extended,
          selectedIndex: _index,
          labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
          onDestinationSelected: (i) => _goTo(_dest[i].$1),
          destinations: [
            for (final (key, icon, label) in _dest) NavigationRailDestination(icon: _icon(key, icon), label: Text(label)),
          ],
        );
        // Ctrl+K (Cmd+K on Mac): quick search
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
                showQuickSearch(context, councils: d.councils, open: _openLink),
            const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
                showQuickSearch(context, councils: d.councils, open: _openLink),
          },
          child: Focus(
            autofocus: true,
            child: ListenableBuilder(
          listenable: Badges.instance,
          builder: (context, _) => Scaffold(
          key: _scaffold,
          appBar: AppBar(
            leading: phone
                ? IconButton(
                    tooltip: 'Menu', icon: const Icon(Icons.menu), onPressed: () => _scaffold.currentState?.openDrawer())
                : Padding(padding: const EdgeInsets.all(10), child: Image.asset('assets/logo_symbol.png')),
            title: Text(phone ? _dest[_index].$3 : 'Rep Hub · ${_dest[_index].$3}'),
            actions: [
              IconButton(
                  tooltip: 'Search (Ctrl+K)',
                  icon: const Icon(Icons.search),
                  onPressed: () => showQuickSearch(context, councils: d.councils, open: _openLink)),
              if (d.semester != null && !phone)
                Center(child: Padding(padding: const EdgeInsets.only(right: 12), child: Text(d.semester!.name))),
              NotificationBell(onOpen: _openLink),
              if (!phone) ...[
                IconButton(
                    tooltip: 'Appearance', onPressed: () => showAppearanceSheet(context), icon: const Icon(Icons.palette_outlined)),
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
                    if (v == 'look') showAppearanceSheet(context);
                    if (v == 'password') showChangePasswordDialog(context);
                    if (v == 'out') Repo.signOut();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'look', child: Text('Appearance')),
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
                    for (final (key, icon, label) in _dest)
                      NavigationDrawerDestination(icon: _icon(key, icon), label: Text(label)),
                  ],
                )
              : null,
          body: phone
              ? pageSwitch(_tab, _page(d))
              : Row(children: [
                  rail(),
                  const VerticalDivider(width: 1),
                  Expanded(child: pageSwitch(_tab, _page(d))),
                ]),
          ),
            ),
          ),
        );
      },
    );
  }
}
