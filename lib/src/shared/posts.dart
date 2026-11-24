import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../data/repo.dart';
import 'format.dart';
import 'interactions.dart';
import 'avatars.dart';
import 'widgets.dart';

Future<void> openPostFile(BuildContext context, Post p) async {
  if (p.filePath == null) return;
  try {
    await launchUrl(Uri.parse(await Repo.postFileUrl(p.filePath!)));
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
  }
}

/// A colour per council, so the audience chips are easy to tell apart
const _audienceColors = [
  Color(0xFF1E88E5), Color(0xFF8E24AA), Color(0xFF00897B), Color(0xFFFB8C00),
  Color(0xFF3949AB), Color(0xFFD81B60), Color(0xFF6D4C41), Color(0xFF43A047),
];
Color audienceColor(String? councilId) =>
    councilId == null ? const Color(0xFF546E7A) : _audienceColors[councilId.hashCode.abs() % _audienceColors.length];

/// One post, Facebook style: who wrote it and when, who it is for, the text, a picture or file,
/// and (for the Head of Education) how many have seen it.
class PostCard extends StatelessWidget {
  final Post post;
  final String? audience;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;
  final VoidCallback? onPin;
  final Map<String, String>? names; // to highlight tags
  final Widget? footer; // reactions and comments
  final bool highlight; // opened from a notification
  final (int, int)? seen; // (seen, readers) – Head of Education only
  final VoidCallback? onSeen;
  const PostCard(
      {super.key,
      required this.post,
      this.audience,
      this.onDelete,
      this.onEdit,
      this.onPin,
      this.names,
      this.footer,
      this.highlight = false,
      this.seen,
      this.onSeen});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final author = names?[post.authorId] ?? 'Head of Education';
    final aColor = audienceColor(post.councilId);
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: highlight || post.pinned
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: highlight ? t.colorScheme.primary : Colors.amber.shade600, width: 2))
          : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (post.pinned)
          Container(
            width: double.infinity,
            color: Colors.amber.withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            child: Row(children: [
              Icon(Icons.push_pin, size: 14, color: Colors.amber.shade900),
              const SizedBox(width: 6),
              Text('Pinned', style: t.textTheme.labelSmall?.copyWith(color: Colors.amber.shade900)),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              UserAvatar(id: post.authorId, name: author, radius: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(author, style: t.textTheme.titleSmall),
                  Text('${fmtDateTime(post.createdAt)}${post.editedAt != null ? ' · edited' : ''}',
                      style: t.textTheme.bodySmall),
                ]),
              ),
              if (onPin != null)
                IconButton(
                  tooltip: post.pinned ? 'Unpin' : 'Pin to the top',
                  icon: Icon(post.pinned ? Icons.push_pin : Icons.push_pin_outlined, size: 20),
                  onPressed: onPin,
                ),
              if (onEdit != null || onDelete != null)
                EditDeleteMenu(
                  canEdit: onEdit != null,
                  canDelete: onDelete != null,
                  onEdit: onEdit ?? () {},
                  onDelete: onDelete ?? () {},
                ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (audience != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: aColor.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(post.councilId == null ? Icons.public : Icons.groups_outlined, size: 13, color: aColor),
                    const SizedBox(width: 4),
                    Text(audience!, style: t.textTheme.labelSmall?.copyWith(color: aColor)),
                  ]),
                ),
              if (post.isFinalAgenda) StatusChip('Final agenda', Colors.indigo),
              if (highlight) StatusChip('From your notification', t.colorScheme.primary),
            ]),
            const SizedBox(height: 8),
            Text(post.title, style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            if (post.body.isNotEmpty) ...[
              const SizedBox(height: 4),
              mentionText(context, post.body, post.mentions, names ?? const {}),
            ],
            if (post.filePath != null) ...[
              const SizedBox(height: 10),
              post.isImage ? _PostImage(post: post) : _fileTile(context),
            ],
            if (seen != null) ...[
              const SizedBox(height: 8),
              InkWell(
                onTap: onSeen,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.visibility_outlined, size: 16, color: t.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text('Seen by ${seen!.$1} of ${seen!.$2}', style: t.textTheme.labelMedium),
                    if (seen!.$2 > 0) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 60,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                              value: seen!.$1 / seen!.$2, minHeight: 5, backgroundColor: t.colorScheme.surfaceContainerHighest),
                        ),
                      ),
                    ],
                  ]),
                ),
              ),
            ],
            if (footer != null) ...[const Divider(height: 18), footer!],
          ]),
        ),
      ]),
    );
  }

  Widget _fileTile(BuildContext context) {
    final t = Theme.of(context);
    final name = post.fileName ?? 'File';
    final ext = name.contains('.') ? name.split('.').last.toUpperCase() : 'FILE';
    final color = switch (ext) {
      'PDF' => Colors.red.shade700,
      'DOC' || 'DOCX' => Colors.blue.shade700,
      'XLS' || 'XLSX' || 'CSV' => Colors.green.shade700,
      'PPT' || 'PPTX' => Colors.orange.shade800,
      _ => Colors.blueGrey,
    };
    return Material(
      color: t.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => openPostFile(context, post),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
              child: Text(ext.length > 4 ? ext.substring(0, 4) : ext,
                  style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
            const Icon(Icons.open_in_new, size: 18),
          ]),
        ),
      ),
    );
  }
}

/// A picture attached to a post, shown in the post (tap to open it full size)
class _PostImage extends StatefulWidget {
  final Post post;
  const _PostImage({required this.post});
  @override
  State<_PostImage> createState() => _PostImageState();
}

class _PostImageState extends State<_PostImage> {
  late final Future<String> _url = Repo.postFileUrl(widget.post.filePath!);
  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: _url,
        builder: (context, s) {
          if (!s.hasData) {
            return Container(
              height: 180,
              decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
            );
          }
          return GestureDetector(
            onTap: () => showDialog(
              context: context,
              builder: (ctx) => GestureDetector(
                onTap: () => Navigator.pop(ctx),
                child: InteractiveViewer(child: Center(child: Image.network(s.data!))),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 380),
                child: Image.network(s.data!, width: double.infinity, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink()),
              ),
            ),
          );
        },
      );
}

/// All posts. Representatives read; the Head of Education also writes and deletes.
class PostsPage extends StatefulWidget {
  final bool officer;
  final List<Council> councils;
  final bool standalone; // pushed as its own screen (with app bar)
  final String? focusId; // post to show first (from a notification)
  const PostsPage(
      {super.key, this.officer = false, this.councils = const [], this.standalone = false, this.focusId});
  @override
  State<PostsPage> createState() => _PostsPageState();
}

class _PostsPageState extends State<PostsPage> {
  late Future<(List<Post>, Map<String, String>)> _f = _load();
  Map<String, (int, int)> _seen = {};
  String? _filter; // council id, 'all' (for everyone) or null = every post
  final _search = TextEditingController();

  Future<(List<Post>, Map<String, String>)> _load() async {
    final posts = await Repo.posts(limit: 100);
    final names = await Repo.memberNames();
    if (widget.officer) {
      Repo.postSeen().then((v) {
        if (mounted) setState(() => _seen = v);
      }).catchError((_) {});
    } else {
      Repo.markPostsSeen([for (final p in posts) p.id]).catchError((_) {});
    }
    return (posts, names);
  }

  void _reload() => setState(() => _f = _load());

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _pin(Post p) async {
    if (await runAction(context, () => Repo.setPinned(p.id, !p.pinned),
        success: p.pinned ? 'Unpinned' : 'Pinned to the top')) {
      _reload();
    }
  }

  Future<void> _showNotSeen(Post p, Map<String, String> names) async {
    final ids = await Repo.postNotSeen(p.id);
    if (!mounted) return;
    final list = ids.map((id) => (id, names[id] ?? '?')).toList()..sort((a, b) => a.$2.compareTo(b.$2));
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(list.isEmpty ? 'Everyone has seen it ✓' : 'Not seen yet (${list.length})'),
        content: SizedBox(
          width: 380,
          height: list.isEmpty ? 40 : 360,
          child: list.isEmpty
              ? const Text('All the representatives it was for have opened it.')
              : ListView(children: [
                  for (final (id, n) in list)
                    ListTile(dense: true, leading: UserAvatar(id: id, name: n), title: Text(n)),
                ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }
  late final _comments = Repo.itemComments('post');
  late final _reactions = Repo.itemReactions('post');

  String _audience(Post p) => _councilName(p.councilId);

  String _councilName(String? id) {
    if (id == null) return 'All representatives';
    for (final c in widget.councils) {
      if (c.id == id) return c.name;
    }
    return 'One council';
  }

  Future<void> _edit(Post p) async {
    final title = TextEditingController(text: p.title), body = TextEditingController(text: p.body);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit post'),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
            const SizedBox(height: 10),
            TextField(
                controller: body,
                minLines: 3,
                maxLines: 10,
                decoration: const InputDecoration(labelText: 'Message', alignLabelWithHint: true)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || title.text.trim().isEmpty || !mounted) return;
    if (await runAction(context, () => Repo.editPost(p.id, title: title.text.trim(), body: body.text.trim()),
        success: 'Saved')) {
      _reload();
    }
  }

  Future<void> _delete(Post p) async {
    if (await confirm(context, 'Delete this post?',
            'Representatives will no longer see it, with its comments. Notifications already sent stay.',
            ok: 'Delete') &&
        mounted &&
        await runAction(context, () => Repo.deletePost(p))) {
      _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = Repo.uid;
    final list = Loader<(List<Post>, Map<String, String>)>(
      future: _f,
      onRetry: _reload,
      builder: (context, data) {
        final (everything, names) = data;
        final q = _search.text.trim().toLowerCase();
        final all = everything.where((p) {
          if (_filter == 'all' && p.councilId != null) return false;
          if (_filter != null && _filter != 'all' && p.councilId != _filter) return false;
          return q.isEmpty || p.title.toLowerCase().contains(q) || p.body.toLowerCase().contains(q);
        }).toList();
        final posts = [
          ...all.where((p) => p.id == widget.focusId),
          ...all.where((p) => p.id != widget.focusId && p.pinned),
          ...all.where((p) => p.id != widget.focusId && !p.pinned),
        ];
        final usedCouncils = {for (final p in everything) if (p.councilId != null) p.councilId!}.toList();
        return StreamBuilder<List<ItemComment>>(
          stream: _comments,
          builder: (context, cs) => StreamBuilder<List<ItemReaction>>(
            stream: _reactions,
            builder: (context, rs) {
              final comments = cs.data ?? const <ItemComment>[];
              final reactions = rs.data ?? const <ItemReaction>[];
              return RefreshIndicator(
                onRefresh: () async => _reload(),
                child: ListView(padding: const EdgeInsets.all(16), children: [
                  if (widget.officer)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.campaign_outlined),
                        label: const Text('New post'),
                        onPressed: () async {
                          if (await showNewPostDialog(context, councils: widget.councils, names: names)) _reload();
                        },
                      ),
                    ),
                  if (widget.officer) const SizedBox(height: 8),
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Wrap(spacing: 10, runSpacing: 10, children: [
                        SizedBox(
                          width: 240,
                          child: DropdownButtonFormField<String?>(
                            initialValue: _filter,
                            isExpanded: true,
                            decoration: const InputDecoration(
                                isDense: true, prefixIcon: Icon(Icons.filter_list), labelText: 'Show'),
                            items: [
                              const DropdownMenuItem<String?>(value: null, child: Text('All posts')),
                              const DropdownMenuItem<String?>(value: 'all', child: Text('For all representatives')),
                              for (final id in usedCouncils)
                                DropdownMenuItem<String?>(
                                    value: id,
                                    child: Text(_councilName(id),
                                        overflow: TextOverflow.ellipsis)),
                            ],
                            onChanged: (v) => setState(() => _filter = v),
                          ),
                        ),
                        SizedBox(
                          width: 240,
                          child: TextField(
                            controller: _search,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              isDense: true,
                              prefixIcon: const Icon(Icons.search),
                              hintText: 'Search posts',
                              suffixIcon: _search.text.isEmpty
                                  ? null
                                  : IconButton(
                                      icon: const Icon(Icons.close), onPressed: () => setState(() => _search.clear())),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (posts.isEmpty)
                    EmptyState(
                      widget.officer
                          ? 'No posts yet. Posts reach all representatives or one council, with a notification.'
                          : 'No posts from the Head of Education yet.',
                      icon: Icons.campaign_outlined,
                    ),
                  for (final p in posts)
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: PostCard(
                          post: p,
                          highlight: p.id == widget.focusId,
                          names: names,
                          audience: _audience(p),
                          onEdit: widget.officer ? () => _edit(p) : null,
                          onDelete: widget.officer ? () => _delete(p) : null,
                          onPin: widget.officer ? () => _pin(p) : null,
                          seen: widget.officer ? _seen[p.id] : null,
                          onSeen: widget.officer ? () => _showNotSeen(p, names) : null,
                          footer: ItemInteractions(
                            kind: 'post',
                            itemId: p.id,
                            meId: me,
                            officer: widget.officer,
                            names: names,
                            comments: comments.where((c) => c.itemId == p.id).toList(),
                            reactions: reactions,
                            initiallyOpen: p.id == widget.focusId,
                          ),
                        ),
                      ),
                    ),
                ]),
              );
            },
          ),
        );
      },
    );
    if (!widget.standalone) return list;
    return Scaffold(appBar: AppBar(title: const Text('From the Head of Education')), body: list);
  }
}

/// New post (or, with [meeting], the final agenda of that meeting). Returns true when sent.
Future<bool> showNewPostDialog(BuildContext context,
    {required List<Council> councils, Meeting? meeting, Map<String, String>? names}) async {
  final tags = <String>{};
  final title = TextEditingController(text: meeting == null ? '' : 'Final agenda – ${meeting.title}');
  final body = TextEditingController(
      text: meeting == null
          ? ''
          : 'Here is the final agenda for ${meeting.title} on ${fmtDateTime(meeting.startsAt)}. '
              'Please read it before the meeting.');
  String? councilId; // null = all reps
  PlatformFile? file;
  var busy = false;
  String? error;

  final sent = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        Future<void> send() async {
          if (title.text.trim().isEmpty) return setD(() => error = 'Write a title');
          if (meeting != null && file == null) return setD(() => error = 'Attach the final agenda (Word or PDF)');
          setD(() {
            busy = true;
            error = null;
          });
          try {
            await Repo.createPost(
              title: title.text.trim(),
              body: body.text.trim(),
              councilId: meeting == null ? councilId : null,
              meetingId: meeting?.id,
              fileName: file?.name,
              bytes: file?.bytes,
              mentions: names == null ? const [] : tagsIn(body.text, tags, names),
            );
            if (ctx.mounted) Navigator.pop(ctx, true);
          } catch (e) {
            setD(() {
              busy = false;
              error = errorText(e);
            });
          }
        }

        return AlertDialog(
          title: Text(meeting == null ? 'New post' : 'Publish final agenda'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (meeting == null)
                  DropdownButtonFormField<String?>(
                    initialValue: councilId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Send to'),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('All representatives')),
                      for (final c in councils) DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: busy ? null : (v) => setD(() => councilId = v),
                  )
                else
                  Text('Goes to the representatives of this meeting\'s council and shows on the meeting page.',
                      style: Theme.of(ctx).textTheme.bodySmall),
                const SizedBox(height: 10),
                TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
                const SizedBox(height: 10),
                TextField(
                  controller: body,
                  minLines: 3,
                  maxLines: 10,
                  decoration: const InputDecoration(labelText: 'Message', alignLabelWithHint: true),
                ),
                if (names != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.alternate_email),
                      label: const Text('Tag people'),
                      onPressed: busy
                          ? null
                          : () async {
                              await pickTags(ctx, names: names, meId: Repo.uid, into: body, tags: tags);
                              setD(() {});
                            },
                    ),
                  ),
                const SizedBox(height: 10),
                Row(children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.attach_file),
                    label: Text(file == null ? 'Attach file' : 'Change file'),
                    onPressed: busy
                        ? null
                        : () async {
                            final r = await FilePicker.platform.pickFiles(withData: true);
                            final f = r?.files.single;
                            if (f == null || f.bytes == null) return;
                            if (f.size > 25 * 1024 * 1024) return setD(() => error = 'Files up to 25 MB');
                            setD(() {
                              file = f;
                              error = null;
                            });
                          },
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(file?.name ?? '', overflow: TextOverflow.ellipsis)),
                  if (file != null)
                    IconButton(
                        tooltip: 'Remove file',
                        icon: const Icon(Icons.close),
                        onPressed: busy ? null : () => setD(() => file = null)),
                ]),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton.icon(
              onPressed: busy ? null : send,
              icon: busy
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: const Text('Send & notify'),
            ),
          ],
        );
      },
    ),
  );
  if (sent == true && context.mounted) showSnack(context, 'Sent ✓ The representatives were notified');
  return sent == true;
}
