import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../push/app_badge_stub.dart' if (dart.library.js_interop) '../push/app_badge_web.dart';
import '../push/push_service.dart';
import '../data/models.dart';
import '../data/repo.dart';
import 'format.dart';
import 'interactions.dart';
import 'theme.dart';
import 'widgets.dart';

/// Teams-like channels. Used by both the rep app and the officer app.
/// Colours a channel can have
const channelColors = <String, Color>{
  'blue': Color(0xFF2F5AAE),
  'sky': Color(0xFF0B8BC4),
  'teal': Color(0xFF00897B),
  'green': Color(0xFF2E7D32),
  'amber': Color(0xFFC77C02),
  'orange': Color(0xFFE65100),
  'rose': Color(0xFFC2185B),
  'purple': Color(0xFF6A4BC4),
};

/// The channel's colour (chosen, or a steady one picked from its id)
Color channelColor(Channel c) {
  final chosen = channelColors[c.color];
  if (chosen != null) return chosen;
  final all = channelColors.values.toList();
  return all[c.id.codeUnits.fold<int>(0, (a, b) => a + b) % all.length];
}

class ChannelsPage extends StatefulWidget {
  final Profile me;
  final bool wide; // officer desktop: list + chat side by side
  final String? openChannelId; // from a notification
  final String? focusId; // the message to show first
  const ChannelsPage({super.key, required this.me, this.wide = false, this.openChannelId, this.focusId});
  @override
  State<ChannelsPage> createState() => _ChannelsPageState();
}

class _ChannelsPageState extends State<ChannelsPage> {
  late Future<(List<Channel>, Map<String, String>)> _f = _load();
  Channel? _selected;

  Future<(List<Channel>, Map<String, String>)> _load() async => (await Repo.channels(), await Repo.memberNames());
  bool _linkDone = false;

  void _push(Channel c, Map<String, String> names, {String? focus}) => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => Scaffold(
                appBar: AppBar(
                  title: Text(c.name),
                  backgroundColor: channelColor(c),
                  foregroundColor: Colors.white,
                ),
                body: ChatView(channel: c, me: widget.me, names: names, focusId: focus),
              )));

  Future<void> _editChannel({Channel? channel}) async {
    final name = TextEditingController(text: channel?.name ?? '');
    final desc = TextEditingController(text: channel?.description ?? '');
    String audience = channel?.audience ?? 'all';
    bool officerOnly = channel?.officerOnly ?? true;
    String? color = channel?.color;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(channel == null ? 'New channel' : 'Edit channel'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 10),
              TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: audience,
                decoration: const InputDecoration(labelText: 'Members'),
                items: const [
                  DropdownMenuItem(value: 'all', child: Text('All representatives')),
                  DropdownMenuItem(value: 'EST', child: Text('Academy EST')),
                  DropdownMenuItem(value: 'HVV', child: Text('Academy HVV')),
                  DropdownMenuItem(value: 'IDT', child: Text('Academy IDT')),
                  DropdownMenuItem(value: 'UKK', child: Text('Academy UKK')),
                ],
                onChanged: (v) => setD(() => audience = v ?? 'all'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Only the Head of Education posts – others comment'),
                subtitle: const Text('Shown as posts with comments (e.g. SIEC, Resources)'),
                value: officerOnly,
                onChanged: (v) => setD(() => officerOnly = v),
              ),
              const SizedBox(height: 6),
              Align(alignment: Alignment.centerLeft, child: Text('Colour', style: Theme.of(ctx).textTheme.labelLarge)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in channelColors.entries)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setD(() => color = e.key),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: e.value,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: color == e.key ? Theme.of(ctx).colorScheme.onSurface : Colors.transparent, width: 3),
                      ),
                      child: color == e.key ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
                    ),
                  ),
              ]),
            ]),
          ),
          actions: [
            if (channel != null)
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'delete'),
                child: const Text('Delete channel', style: TextStyle(color: Colors.red)),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (result == 'delete' && channel != null) {
      if (await confirm(context, 'Delete “${channel.name}”?', 'All messages and files in the channel are deleted.',
              ok: 'Delete') &&
          await runAction(context, () => Repo.deleteChannel(channel.id), success: 'Channel deleted')) {
        setState(() {
          _selected = null;
          _f = _load();
        });
      }
      return;
    }
    if (result == 'save' && name.text.trim().isNotEmpty) {
      await runAction(
          context,
          () => Repo.saveChannel(
              id: channel?.id,
              name: name.text.trim(),
              description: desc.text.trim(),
              audience: audience,
              officerOnly: officerOnly,
              color: color));
      setState(() => _f = _load());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Loader<(List<Channel>, Map<String, String>)>(
      future: _f,
      onRetry: () => setState(() => _f = _load()),
      builder: (context, data) {
        final (channels, names) = data;
        // opened from a notification: that channel, with the message on top
        final linked = channels.where((c) => c.id == widget.openChannelId).toList();
        if (!_linkDone && linked.isNotEmpty) {
          _linkDone = true;
          if (widget.wide) {
            _selected = linked.first;
          } else {
            WidgetsBinding.instance.addPostFrameCallback((_) => _push(linked.first, names, focus: widget.focusId));
          }
        }
        final list = ListView(children: [
          for (final c in channels)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: channelColor(c).withValues(alpha: 0.15),
                child: Icon(
                    c.name.toLowerCase().contains('resource')
                        ? Icons.folder_outlined
                        : (c.officerOnly ? Icons.campaign_outlined : Icons.forum_outlined),
                    color: channelColor(c)),
              ),
              selectedTileColor: channelColor(c).withValues(alpha: 0.10),
              selectedColor: channelColor(c),
              trailing: widget.me.isOfficer
                  ? IconButton(
                      tooltip: 'Edit channel',
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      onPressed: () => _editChannel(channel: c))
                  : null,
              title: Text(c.name),
              subtitle: Text(c.description, maxLines: 1, overflow: TextOverflow.ellipsis),
              selected: widget.wide && _selected?.id == c.id,
              onTap: () {
                if (widget.wide) {
                  setState(() => _selected = c);
                } else {
                  _push(c, names);
                }
              },
            ),
          if (widget.me.isOfficer)
            ListTile(leading: const Icon(Icons.add), title: const Text('New channel'), onTap: () => _editChannel()),
        ]);
        if (!widget.wide) return list;
        final sel = _selected ?? (channels.isEmpty ? null : channels.first);
        return Row(children: [
          SizedBox(width: 280, child: list),
          const VerticalDivider(width: 1),
          Expanded(
            child: sel == null
                ? const EmptyState('No channels yet')
                : Column(children: [
                    // the channel's colour band
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      color: channelColor(sel),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(sel.name,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
                        if (sel.description.isNotEmpty)
                          Text(sel.description, style: TextStyle(color: Colors.white.withValues(alpha: 0.85))),
                      ]),
                    ),
                    Expanded(
                      child: ChatView(
                          key: ValueKey(sel.id),
                          channel: sel,
                          me: widget.me,
                          names: names,
                          focusId: sel.id == widget.openChannelId ? widget.focusId : null),
                    ),
                  ]),
          ),
        ]);
      },
    );
  }
}

class ChatView extends StatefulWidget {
  final Channel channel;
  final Profile me;
  final Map<String, String> names;
  final String? focusId; // a post or comment to show first (from a notification)
  const ChatView({super.key, required this.channel, required this.me, required this.names, this.focusId});
  @override
  State<ChatView> createState() => _ChatViewState();
}


/// A channel. Normally a feed: the Head of Education posts, representatives comment under each
/// post. She can tag people, react, and edit or delete her posts. (A channel can still be set to
/// chat mode, where everyone writes.)
class _ChatViewState extends State<ChatView> {
  final _text = TextEditingController();
  final _postTags = <String>{};
  bool _announcement = false;
  bool _sending = false;
  PlatformFile? _file;
  int _seenCount = -1;
  final _comment = <String, TextEditingController>{};
  final _commentTags = <String, Set<String>>{};
  final _expanded = <String>{}; // posts with all comments shown
  final _writing = <String>{}; // posts with the comment box open
  bool _focusApplied = false;
  late final Stream<List<Message>> _stream = Repo.messageStream(widget.channel.id);
  late final Stream<List<Reaction>> _reactions = Repo.reactionStream();

  bool get _feed => widget.channel.officerOnly;
  bool get _canPost => !widget.channel.officerOnly || widget.me.isOfficer;
  bool get _officer => widget.me.isOfficer;

  @override
  void dispose() {
    _text.dispose();
    for (final c in _comment.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Representatives: opening the channel (and every new message while it is open) counts as
  /// having seen the Head of Education's messages.
  void _markSeen(int count) {
    if (_officer || count == _seenCount) return;
    _seenCount = count;
    Repo.markChannelRead(widget.channel.id).catchError((_) {});
  }

  List<String> _tagsIn(String text, Set<String> tags) => tagsIn(text, tags, widget.names);

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty && _file == null) return;
    setState(() => _sending = true);
    final ok = await runAction(context, () async {
      String? path;
      if (_file?.bytes != null) path = await Repo.uploadChannelFile(_file!.name, _file!.bytes!);
      await Repo.sendMessage(widget.channel.id, text.isEmpty ? '📎 ${_file!.name}' : text,
          announcement: _officer && _announcement,
          filePath: path,
          fileName: _file?.name,
          mentions: _tagsIn(text, _postTags));
    });
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) {
        _text.clear();
        _file = null;
        _postTags.clear();
      }
    });
  }

  Future<void> _sendComment(Message post) async {
    final c = _comment[post.id];
    final text = c?.text.trim() ?? '';
    if (text.isEmpty) return;
    final tags = _tagsIn(text, _commentTags[post.id] ?? {});
    if (await runAction(context, () => Repo.sendMessage(widget.channel.id, text, parentId: post.id, mentions: tags))) {
      c!.clear();
      _commentTags.remove(post.id);
      setState(() {
        _expanded.add(post.id);
        _writing.remove(post.id);
      });
    }
  }

  /// Pick people to tag; "@Name" goes into the text
  Future<void> _tag(TextEditingController into, Set<String> tags) async {
    await pickTags(context, names: widget.names, meId: widget.me.id, into: into, tags: tags);
    setState(() {});
  }

  Future<void> _edit(Message m) async {
    final c = TextEditingController(text: m.body);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(m.parentId == null ? 'Edit post' : 'Edit comment'),
        content: SizedBox(
          width: 520,
          child: TextField(controller: c, autofocus: true, minLines: 3, maxLines: 12),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || c.text.trim().isEmpty || !mounted) return;
    await runAction(context, () => Repo.editMessage(m.id, c.text.trim()), success: 'Saved');
  }

  Future<void> _delete(Message m) async {
    final post = m.parentId == null;
    if (await confirm(context, post ? 'Delete this post?' : 'Delete this comment?',
            post ? 'The post and all comments under it are deleted for everyone.' : 'The comment is deleted for everyone.',
            ok: 'Delete') &&
        mounted) {
      await runAction(context, () => Repo.deleteMessage(m.id), success: 'Deleted');
    }
  }

  Future<void> _pickFile() async {
    final r = await FilePicker.platform.pickFiles(withData: true);
    final f = r?.files.single;
    if (f == null) return;
    if ((f.size) > 20 * 1024 * 1024) return showSnack(context, 'Files up to 20 MB');
    setState(() => _file = f);
  }

  Future<void> _openFile(Message m) async {
    try {
      final url = await Repo.channelFileUrl(m.filePath!);
      await launchUrl(Uri.parse(url));
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
  }

  Future<void> _showReads(Message m) async {
    final rows = await Repo.announcementReads(m.id);
    if (!mounted) return;
    final read = rows.where((r) => r['read_at'] != null).length;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Seen by $read of ${rows.length}'),
        content: SizedBox(
          width: 360,
          height: 360,
          child: ListView(children: [
            for (final r in rows)
              ListTile(
                dense: true,
                leading: Icon(r['read_at'] != null ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: r['read_at'] != null ? Colors.green : Colors.grey),
                title: Text((r['full_name'] ?? '') as String),
                subtitle: r['read_at'] == null ? null : Text(fmtDateTime(DateTime.parse(r['read_at'] as String).toLocal())),
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  /// The text with tagged names highlighted
  Widget _body(Message m) => mentionText(context, m.body, m.mentions, widget.names);

  /// Emoji chips (tap to add/remove yours) and a button to add a reaction
  Widget _reactionBar(Message m, List<Reaction> all) => ReactionBar(
        reactions: [
          for (final r in all)
            if (r.messageId == m.id) (r.userId, r.emoji)
        ],
        meId: widget.me.id,
        names: widget.names,
        onToggle: (e, on) => Repo.react(m.id, e, on),
      );

  /// Author line, text, file, menu (edit/delete) and – for the Head of Education's own posts – "Seen by".
  Widget _content(Message m, List<Reaction> reactions, {bool showSeen = true, Widget? actions}) {
    final t = Theme.of(context);
    final mine = m.authorId == widget.me.id;
    final canDelete = mine || _officer;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text(
            '${widget.names[m.authorId] ?? 'Someone'} · ${fmtDateTime(m.createdAt)}'
            '${m.isAnnouncement ? ' · announcement' : ''}${m.editedAt != null ? ' · edited' : ''}',
            style: t.textTheme.labelSmall,
          ),
        ),
        if (canDelete)
          SizedBox(
            height: 28,
            child: PopupMenuButton<String>(
              padding: EdgeInsets.zero,
              iconSize: 18,
              tooltip: 'More',
              onSelected: (v) => v == 'edit' ? _edit(m) : _delete(m),
              itemBuilder: (_) => [
                if (mine) const PopupMenuItem(value: 'edit', child: Text('Edit')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ),
      ]),
      const SizedBox(height: 4),
      _body(m),
      if (m.filePath != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: ActionChip(
            avatar: const Icon(Icons.attach_file, size: 16),
            label: Text(m.fileName ?? 'File', overflow: TextOverflow.ellipsis),
            onPressed: () => _openFile(m),
          ),
        ),
      Row(children: [
        Expanded(child: _reactionBar(m, reactions)),
        if (actions != null) actions,
        if (showSeen && _officer && (mine || m.isAnnouncement))
          TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => _showReads(m),
              icon: const Icon(Icons.done_all, size: 16),
              label: const Text('Seen by')),
      ]),
    ]);
  }

  Widget _chat(List<Message> msgs, List<Reaction> reactions) {
    final t = Theme.of(context);
    if (msgs.isEmpty) return const EmptyState('No messages yet');
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.all(12),
      itemCount: msgs.length,
      itemBuilder: (context, i) {
        final m = msgs[msgs.length - 1 - i];
        final mine = m.authorId == widget.me.id;
        final bg = m.isAnnouncement
            ? softBg(context, Colors.amber)
            : (mine ? t.colorScheme.primaryContainer : t.colorScheme.surfaceContainerHighest);
        return Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
              child: _content(m, reactions),
            ),
          ),
        );
      },
    );
  }

  Widget _commentBox(Message p) {
    final c = _comment.putIfAbsent(p.id, () => TextEditingController());
    return Row(children: [
      IconButton(
          tooltip: 'Tag people',
          icon: const Icon(Icons.alternate_email),
          onPressed: () => _tag(c, _commentTags.putIfAbsent(p.id, () => <String>{})),
        ),
      Expanded(
        child: TextField(
          controller: c,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Write a comment…'),
        ),
      ),
      IconButton(tooltip: 'Send comment', onPressed: () => _sendComment(p), icon: const Icon(Icons.send)),
    ]);
  }

  Widget _posts(List<Message> all, List<Reaction> reactions) {
    final t = Theme.of(context);
    final posts = all.where((m) => m.parentId == null).toList().reversed.toList(); // newest first
    final comments = <String, List<Message>>{};
    for (final m in all.where((m) => m.parentId != null)) {
      comments.putIfAbsent(m.parentId!, () => []).add(m);
    }
    // from a notification: that post first, highlighted, with its comments open
    final focus = all.where((m) => m.id == widget.focusId).toList();
    final focusPost = focus.isEmpty ? null : (focus.first.parentId ?? focus.first.id);
    if (focusPost != null) {
      final hit = posts.indexWhere((p) => p.id == focusPost);
      if (hit > 0) posts.insert(0, posts.removeAt(hit));
      if (!_focusApplied) {
        _focusApplied = true;
        _expanded.add(focusPost);
      }
    }
    final accent = channelColor(widget.channel);
    if (posts.isEmpty) {
      return EmptyState(_officer ? 'No posts yet – write the first one below' : 'No posts yet');
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: posts.length,
      itemBuilder: (context, i) {
        final p = posts[i];
        final list = comments[p.id] ?? const <Message>[];
        final open = _expanded.contains(p.id);
        final writing = _writing.contains(p.id);
        // folded: only the latest comment
        final shown = open || list.length <= 1 ? list : [list.last];
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Card(
              color: p.isAnnouncement ? Color.alphaBlend(softBg(context, Colors.amber), t.cardColor) : null,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: p.id == focusPost
                    ? BorderSide(color: t.colorScheme.primary, width: 2)
                    : BorderSide(color: t.dividerColor.withValues(alpha: 0.4)),
              ),
              clipBehavior: Clip.antiAlias,
              child: Container(
                decoration: BoxDecoration(border: Border(left: BorderSide(color: accent, width: 5))),
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (p.id == focusPost)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: StatusChip('From your notification', t.colorScheme.primary),
                    ),
                  _content(p, reactions,
                      actions: CommentActions(
                        count: list.length,
                        open: open,
                        onToggle: () => setState(() => open ? _expanded.remove(p.id) : _expanded.add(p.id)),
                        onComment: () => setState(() => writing ? _writing.remove(p.id) : _writing.add(p.id)),
                      )),
                  if (shown.isNotEmpty || writing) const Divider(height: 12),
                  if (!open && list.length > 1)
                    TextButton(
                      onPressed: () => setState(() => _expanded.add(p.id)),
                      child: Text('View all ${list.length} comments'),
                    ),
                  for (final m in shown)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
                      decoration: BoxDecoration(
                          color: t.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                          border: m.id == widget.focusId ? Border.all(color: t.colorScheme.primary, width: 2) : null),
                      child: _content(m, reactions, showSeen: false),
                    ),
                  if (open && list.length > 1)
                    TextButton(
                      onPressed: () => setState(() => _expanded.remove(p.id)),
                      child: const Text('Hide comments'),
                    ),
                  if (writing) _commentBox(p),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: StreamBuilder<List<Message>>(
          stream: _stream,
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(error: snap.error!);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final msgs = snap.data!;
            _markSeen(msgs.length);
            return StreamBuilder<List<Reaction>>(
              stream: _reactions,
              builder: (context, r) {
                final reactions = r.data ?? const <Reaction>[];
                return _feed
                    ? _posts(msgs, reactions)
                    : _chat(msgs.where((m) => m.parentId == null).toList(), reactions);
              },
            );
          },
        ),
      ),
      const Divider(height: 1),
      if (_canPost)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Column(children: [
            if (_officer)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _announcement,
                onChanged: (v) => setState(() => _announcement = v ?? false),
                title: const Text('Announcement (highlighted)'),
              ),
            if (_file != null)
              Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  avatar: const Icon(Icons.attach_file, size: 16),
                  label: Text(_file!.name),
                  onDeleted: () => setState(() => _file = null),
                ),
              ),
            Row(children: [
              IconButton(tooltip: 'Attach file', onPressed: _pickFile, icon: const Icon(Icons.attach_file)),
              if (_officer)
                IconButton(
                    tooltip: 'Tag representatives',
                    onPressed: () => _tag(_text, _postTags),
                    icon: const Icon(Icons.alternate_email)),
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 6,
                  decoration: InputDecoration(
                      hintText: _feed ? 'New post in ${widget.channel.name}…' : 'Write to ${widget.channel.name}…'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _sending ? null : _send, icon: const Icon(Icons.send)),
            ]),
          ]),
        )
      else
        Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Only the Head of Education posts here – comment under her posts',
                style: Theme.of(context).textTheme.bodySmall)),
    ]);
  }
}

class NotificationsPage extends StatefulWidget {
  final void Function(String link)? onOpen;
  const NotificationsPage({super.key, this.onOpen});
  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final Stream<List<AppNotification>> _stream = Repo.notificationStream();

  @override
  void initState() {
    super.initState();
    // Opening the page counts as reading them: the bell's red counter goes away
    Repo.markAllNotificationsRead().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Notifications')),
        body: StreamBuilder<List<AppNotification>>(
          stream: _stream,
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(error: snap.error!);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            if (list.isEmpty) return const EmptyState('Nothing yet');
            return ListView.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final n = list[i];
                return ListTile(
                  leading: Icon(n.readAt == null ? Icons.circle : Icons.circle_outlined,
                      size: 12, color: Theme.of(context).colorScheme.primary),
                  title: Text(n.title, style: TextStyle(fontWeight: n.readAt == null ? FontWeight.bold : null)),
                  subtitle: Text('${n.body}\n${fmtDateTime(n.createdAt)}'),
                  isThreeLine: true,
                  trailing: n.link != null && n.link!.startsWith('http') ? const Icon(Icons.open_in_new, size: 18) : null,
                  onTap: n.link == null
                      ? null
                      : () {
                          // a web link (e.g. the payslip in Fortnox) opens in the browser / app
                          if (n.link!.startsWith('http')) {
                            launchUrl(Uri.parse(n.link!), mode: LaunchMode.externalApplication);
                            return;
                          }
                          if (widget.onOpen == null) return;
                          Navigator.pop(context);
                          widget.onOpen!(n.link!);
                        },
                );
              },
            );
          },
        ),
      );
}

/// Bell icon with unread badge (live).
class NotificationBell extends StatefulWidget {
  final void Function(String link)? onOpen;
  const NotificationBell({super.key, this.onOpen});
  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> with WidgetsBindingObserver {
  Stream<List<AppNotification>> _stream = Repo.notificationStream();
  int? _shownBadge;

  // The live connection can drop while the phone is locked or the app is in the background
  // (especially the iPhone web app). Read the list again when the app comes back and when a
  // push notification arrives while the app is open.
  void _refresh() {
    if (mounted) setState(() => _stream = Repo.notificationStream());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PushService.instance.received.addListener(_refresh);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PushService.instance.received.removeListener(_refresh);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<AppNotification>>(
        stream: _stream,
        builder: (context, snap) {
          final unread = (snap.data ?? const <AppNotification>[]).where((n) => n.readAt == null).length;
          // Red number on the app icon (web version on iPhone; phones get it with each notification)
          if (snap.hasData && unread != _shownBadge) {
            _shownBadge = unread;
            setAppBadge(unread);
          }
          return IconButton(
            tooltip: 'Notifications',
            onPressed: () async {
              await Navigator.push(
                  context, MaterialPageRoute(builder: (_) => NotificationsPage(onOpen: widget.onOpen)));
              await Repo.markAllNotificationsRead().catchError((_) {});
              // read the list again so the counter is up to date
              _refresh();
            },
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.notifications_outlined),
            ),
          );
        },
      );
}
