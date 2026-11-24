import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/posts.dart';
import '../shared/format.dart';
import '../shared/interactions.dart';
import '../shared/issue_dialogs.dart';
import '../shared/theme.dart';
import '../shared/tour.dart';
import '../shared/widgets.dart';
import 'rep_shell.dart';

class MorePage extends StatelessWidget {
  final RepData data;
  final VoidCallback onChanged;
  const MorePage({super.key, required this.data, required this.onChanged});

  void _push(BuildContext context, String title, Widget body) => Navigator.push(
      context, MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: body)));

  @override
  Widget build(BuildContext context) => ListView(children: [
        ListTile(
          leading: const Icon(Icons.campaign_outlined),
          title: const Text('From the Head of Education'),
          subtitle: const Text('News, instructions and final agendas'),
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => PostsPage(councils: data.councils, standalone: true))),
        ),
        ListTile(
          leading: const Icon(Icons.loop),
          title: const Text('Follow-ups'),
          subtitle: const Text('Issues raised in your councils and the university\'s answers'),
          onTap: () => _push(context, 'Follow-ups', RepFollowUpsPage(data: data)),
        ),
        ListTile(
          leading: const Icon(Icons.school_outlined),
          title: const Text('Tutoring board'),
          subtitle: const Text('Students helping students'),
          onTap: () => _push(context, 'Tutoring board', TutoringBoard(me: data.me)),
        ),
        ListTile(
          leading: const Icon(Icons.people_outline),
          title: const Text('Rep directory'),
          onTap: () => _push(context, 'Rep directory', const DirectoryPage()),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('My profile & payment details'),
          onTap: () => _push(context, 'My profile', ProfilePage(data: data, onChanged: onChanged)),
        ),
        ListTile(
          leading: const Icon(Icons.tips_and_updates_outlined),
          title: const Text('Show the welcome tour'),
          onTap: () => showTour(context, repTour, markSeen: false),
        ),
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: const Text('Appearance'),
          subtitle: const Text('Light or dark, colour and banner'),
          onTap: () => showAppearanceSheet(context),
        ),
        ListTile(
          leading: const Icon(Icons.menu_book_outlined),
          title: const Text('Handbook – quick facts'),
          onTap: () => _push(context, 'Handbook', const HandbookPage()),
        ),
        if ((data.me.studyYear ?? 1) > 1)
          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Succession: as a year ${data.me.studyYear} rep, help find a rep for '
                  'year ${data.me.studyYear! - 1} before you move on.'),
            ),
          ),
        const Divider(),
        ListTile(leading: const Icon(Icons.logout), title: const Text('Sign out'), onTap: Repo.signOut),
      ]);
}

class RepFollowUpsPage extends StatefulWidget {
  final RepData data;
  const RepFollowUpsPage({super.key, required this.data});
  @override
  State<RepFollowUpsPage> createState() => _RepFollowUpsPageState();
}

class _RepFollowUpsPageState extends State<RepFollowUpsPage> {
  late Future<List<Issue>> _f = Repo.issues();
  void _reload() => setState(() => _f = Repo.issues());

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final councils = widget.data.myCouncils.where((c) => !c.isSiec).toList();
            if (await showAddIssueDialog(context, councils: councils.isEmpty ? widget.data.myCouncils : councils)) {
              _reload();
            }
          },
          icon: const Icon(Icons.add),
          label: const Text('Log issue'),
        ),
        body: Loader<List<Issue>>(
          future: _f,
          onRetry: _reload,
          builder: (context, issues) => issues.isEmpty
              ? const EmptyState('No issues logged in your councils')
              : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 90), children: [
                  for (final i in issues)
                    Card(
                      child: ListTile(
                        title: Text(i.title),
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          const SizedBox(height: 4),
                          StatusChip.issue(i.status),
                          const SizedBox(height: 4),
                          Text('${widget.data.council(i.councilId)?.name ?? ''} · ${i.responsible ?? ''}'),
                          if ((i.response ?? '').isNotEmpty)
                            Text('↳ ${i.response}', style: TextStyle(color: Colors.green.shade800)),
                        ]),
                        onTap: () async {
                          if (await showIssueUpdateDialog(context, i, officer: false)) _reload();
                        },
                      ),
                    ),
                ]),
        ),
      );
}

/// Tutoring board (SIEC protocol 5.1). Officer can hide posts.
class TutoringBoard extends StatefulWidget {
  final Profile me;
  final String? focusId; // post to show first (from a notification)
  const TutoringBoard({super.key, required this.me, this.focusId});
  @override
  State<TutoringBoard> createState() => _TutoringBoardState();
}

class _TutoringBoardState extends State<TutoringBoard> {
  late Future<(List<TutoringPost>, Map<String, String>)> _f = _load();
  Future<(List<TutoringPost>, Map<String, String>)> _load() async => (await Repo.tutoring(), await Repo.memberNames());
  void _reload() => setState(() => _f = _load());
  late final _comments = Repo.itemComments('tutoring');
  late final _reactions = Repo.itemReactions('tutoring');

  /// New post, or edit [post]
  Future<void> _write(Map<String, String> names, {TutoringPost? post}) async {
    String kind = post?.kind ?? 'offer';
    final course = TextEditingController(text: post?.course ?? ''), body = TextEditingController(text: post?.body ?? '');
    final tags = <String>{...?post?.mentions};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(post == null ? 'New post' : 'Edit post'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (post == null)
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'offer', label: Text('I offer help')),
                    ButtonSegment(value: 'request', label: Text('I need help')),
                  ],
                  selected: {kind},
                  onSelectionChanged: (s) => setD(() => kind = s.first),
                ),
              const SizedBox(height: 10),
              TextField(controller: course, decoration: const InputDecoration(labelText: 'Course')),
              const SizedBox(height: 10),
              TextField(
                  controller: body, maxLines: 4, decoration: const InputDecoration(labelText: 'What, when, where?')),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.alternate_email),
                  label: const Text('Tag people'),
                  onPressed: () async {
                    await pickTags(ctx, names: names, meId: widget.me.id, into: body, tags: tags);
                    setD(() {});
                  },
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(post == null ? 'Post' : 'Save')),
          ],
        ),
      ),
    );
    if (ok != true || course.text.trim().isEmpty || !mounted) return;
    final mentions = tagsIn(body.text, tags, names);
    if (await runAction(
        context,
        () => post == null
            ? Repo.addTutoring(kind: kind, course: course.text.trim(), body: body.text.trim(), mentions: mentions)
            : Repo.editTutoring(post.id, course: course.text.trim(), body: body.text.trim(), mentions: mentions))) {
      _reload();
    }
  }

  Widget _post(TutoringPost p, Map<String, String> names, List<ItemComment> comments, List<ItemReaction> reactions) {
    final t = Theme.of(context);
    final mine = p.authorId == widget.me.id;
    final focus = p.id == widget.focusId;
    return Opacity(
      opacity: p.hidden ? 0.45 : 1,
      child: Card(
        shape: focus
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14), side: BorderSide(color: t.colorScheme.primary, width: 2))
            : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(p.kind == 'offer' ? Icons.volunteer_activism_outlined : Icons.help_outline,
                  color: p.kind == 'offer' ? Colors.green : Colors.blue),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${p.kind == 'offer' ? 'Offers help' : 'Needs help'} · ${p.course}', style: t.textTheme.titleSmall),
                  if (p.body.isNotEmpty)
                    Padding(padding: const EdgeInsets.only(top: 4), child: mentionText(context, p.body, p.mentions, names)),
                  Text('${names[p.authorId] ?? ''} · ${fmtDate(p.createdAt)}${p.editedAt != null ? ' · edited' : ''}',
                      style: t.textTheme.bodySmall),
                ]),
              ),
              if (widget.me.isOfficer)
                TextButton(
                    onPressed: () async {
                      await runAction(context, () => Repo.setTutoringHidden(p.id, !p.hidden));
                      _reload();
                    },
                    child: Text(p.hidden ? 'Show' : 'Hide')),
              EditDeleteMenu(
                canEdit: mine,
                canDelete: mine || widget.me.isOfficer,
                onEdit: () => _write(names, post: p),
                onDelete: () async {
                  if (await confirm(context, 'Delete this post?', 'The post and its comments are deleted.', ok: 'Delete') &&
                      mounted &&
                      await runAction(context, () => Repo.deleteTutoring(p.id))) {
                    _reload();
                  }
                },
              ),
            ]),
            const SizedBox(height: 4),
            ItemInteractions(
              kind: 'tutoring',
              itemId: p.id,
              meId: widget.me.id,
              officer: widget.me.isOfficer,
              names: names,
              comments: comments,
              reactions: reactions,
              canComment: !p.hidden,
              initiallyOpen: focus,
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Loader<(List<TutoringPost>, Map<String, String>)>(
        future: _f,
        onRetry: _reload,
        builder: (context, data) {
          final (all, names) = data;
          final posts = [
            ...all.where((p) => p.id == widget.focusId),
            ...all.where((p) => p.id != widget.focusId),
          ];
          return Scaffold(
            floatingActionButton: FloatingActionButton.extended(
                onPressed: () => _write(names), icon: const Icon(Icons.add), label: const Text('New post')),
            body: StreamBuilder<List<ItemComment>>(
              stream: _comments,
              builder: (context, cs) => StreamBuilder<List<ItemReaction>>(
                stream: _reactions,
                builder: (context, rs) {
                  final comments = cs.data ?? const <ItemComment>[];
                  final reactions = rs.data ?? const <ItemReaction>[];
                  return RefreshIndicator(
                    onRefresh: () async => _reload(),
                    child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 90), children: [
                      Text('MDSU only hosts this board and is not responsible for the tutoring itself.',
                          style: Theme.of(context).textTheme.bodySmall),
                      if (posts.isEmpty)
                        EmptyState('Nothing here yet. Offer help in a course you are good at, or ask for help.',
                            icon: Icons.volunteer_activism_outlined,
                            actionLabel: 'New post',
                            onAction: () => _write(names)),
                      for (final p in posts)
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 760),
                            child: _post(p, names, comments.where((c) => c.itemId == p.id).toList(), reactions),
                          ),
                        ),
                    ]),
                  );
                },
              ),
            ),
          );
        },
      );
}

class DirectoryPage extends StatelessWidget {
  const DirectoryPage({super.key});
  @override
  Widget build(BuildContext context) => Loader<List<Map<String, dynamic>>>(
        future: Repo.directory(),
        builder: (context, rows) => rows.isEmpty
            ? const EmptyState(
                'No one has shared contact details yet. Share yours under My profile → "Share my contact details".',
                icon: Icons.contacts_outlined)
            : ListView(children: [
                for (final r in rows)
                  ListTile(
                    leading: CircleAvatar(child: Text(_initial((r['full_name'] ?? '') as String))),
                    title: Text((r['full_name'] ?? '') as String),
                    subtitle: Text('${r['program'] ?? ''} · ${r['academy'] ?? ''} · year ${r['study_year'] ?? '-'}\n'
                        '${r['email'] ?? ''}'),
                    isThreeLine: true,
                  ),
              ]),
      );
}

String _initial(String name) => name.trim().isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase();

class ProfilePage extends StatefulWidget {
  final RepData data;
  final VoidCallback onChanged;
  const ProfilePage({super.key, required this.data, required this.onChanged});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late bool _share = widget.data.me.shareContact;
  late final _name = TextEditingController(text: widget.data.me.fullName);
  final _pnr = TextEditingController();
  final _address = TextEditingController();
  bool _hasPnr = false;

  @override
  void initState() {
    super.initState();
    Repo.myPrivateDetails().then((d) {
      if (!mounted || d == null) return;
      setState(() {
        _hasPnr = d['personal_number'] != null;
        _address.text = (d['address'] ?? '') as String;
      });
    });
  }

  Future<void> _savePrivate() async {
    final pnr = _pnr.text.trim();
    final ok = await runAction(
      context,
      () => Repo.savePrivateDetails(personalNumber: pnr.isEmpty ? null : pnr, address: _address.text),
      success: 'Saved',
    );
    if (ok && pnr.isNotEmpty) {
      _pnr.clear();
      setState(() => _hasPnr = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.data.me;
    return ListView(padding: const EdgeInsets.all(16), children: [
      TextField(controller: _name, decoration: const InputDecoration(labelText: 'Full name')),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
            onPressed: () async {
              if (await runAction(context, () => Repo.updateMyProfile(fullName: _name.text.trim()), success: 'Saved')) {
                widget.onChanged();
              }
            },
            child: const Text('Save name')),
      ),
      SwitchListTile(
        title: const Text('Share my contact details with other reps'),
        value: _share,
        onChanged: (v) async {
          if (await runAction(context, () => Repo.updateMyProfile(shareContact: v))) setState(() => _share = v);
        },
      ),
      const Divider(),
      ListTile(title: const Text('Union member (needed for payment)'), trailing: Icon(me.isMember ? Icons.check : Icons.close)),
      ListTile(title: const Text('Quiz passed this semester (≥80 %)'), trailing: Icon(me.quizPassed ? Icons.check : Icons.close)),
      ListTile(title: const Text('Councils'), subtitle: Text(widget.data.myCouncils.map((c) => c.name).join('\n'))),
      const Divider(),
      const ListTile(
        title: Text('Payment details for the time report'),
        subtitle: Text('Only you and the Head of Education can see these. No bank details needed.'),
      ),
      TextField(
        controller: _pnr,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: 'Personal number / samordningsnummer',
          hintText: _hasPnr ? 'On file ✓ – type to change' : 'YYYYMMDD-XXXX',
        ),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _address,
        decoration: const InputDecoration(labelText: 'Home address (Bostadsadress)', hintText: 'Street 1, 123 45 City'),
      ),
      const SizedBox(height: 10),
      FilledButton(onPressed: _savePrivate, child: const Text('Save payment details')),
      const Divider(height: 32),
      OutlinedButton.icon(
        onPressed: () => showChangePasswordDialog(context),
        icon: const Icon(Icons.key_outlined),
        label: const Text('Change my password'),
      ),
    ]);
  }
}

class HandbookPage extends StatelessWidget {
  const HandbookPage({super.key});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: const [
        _Fact('Pay', '130 SEK per hour, counted as 65 SEK per started half hour, only while you are a union member.'),
        _Fact('Counts as work', 'Gathering input, class visits, council and SIEC meetings, preparation, '
            'education-related Teams and email.'),
        _Fact('Does not count', 'Chats not about education, travel time without active work, '
            'association meetings not about student influence.'),
        _Fact('Before meetings', 'Ask students for input 1–2 weeks before. Read the agenda and documents.'),
        _Fact('After meetings', 'Report back to classmates and log your time right away. Keep your notes.'),
        _Fact('SIEC', 'First Monday of each month (not January, July or August).'),
        _Fact('Deadline', 'Submit your time report by the semester deadline. Late reports are paid next semester.'),
        _Fact('Succession', 'Help recruit a rep for the year group directly below yours.'),
        _Fact('Quiz', 'Redo the quiz at the start of each semester and score at least 80 %.'),
      ]);
}

class _Fact extends StatelessWidget {
  final String title, body;
  const _Fact(this.title, this.body);
  @override
  Widget build(BuildContext context) => Card(child: ListTile(title: Text(title), subtitle: Text(body)));
}
