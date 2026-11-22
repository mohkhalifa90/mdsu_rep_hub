import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../data/repo.dart';
import 'format.dart';
import 'interactions.dart';
import 'widgets.dart';

Future<void> openPostFile(BuildContext context, Post p) async {
  if (p.filePath == null) return;
  try {
    await launchUrl(Uri.parse(await Repo.postFileUrl(p.filePath!)));
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
  }
}

/// One post as a card: title, text, date, who it went to, and its file.
class PostCard extends StatelessWidget {
  final Post post;
  final String? audience;
  final VoidCallback? onDelete;
  final VoidCallback? onEdit;
  final Map<String, String>? names; // to highlight tags
  final Widget? footer; // reactions and comments
  final bool highlight; // opened from a notification
  const PostCard(
      {super.key,
      required this.post,
      this.audience,
      this.onDelete,
      this.onEdit,
      this.names,
      this.footer,
      this.highlight = false});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      shape: highlight
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14), side: BorderSide(color: t.colorScheme.primary, width: 2))
          : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(post.isFinalAgenda ? Icons.description_outlined : Icons.campaign_outlined, color: t.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(post.title, style: t.textTheme.titleMedium),
                Text(
                    '${fmtDateTime(post.createdAt)}${audience == null ? '' : ' · $audience'}'
                    '${post.editedAt != null ? ' · edited' : ''}',
                    style: t.textTheme.bodySmall),
              ]),
            ),
            if (onEdit != null || onDelete != null)
              EditDeleteMenu(
                canEdit: onEdit != null,
                canDelete: onDelete != null,
                onEdit: onEdit ?? () {},
                onDelete: onDelete ?? () {},
              ),
          ]),
          if (highlight) ...[const SizedBox(height: 6), StatusChip('From your notification', t.colorScheme.primary)],
          if (post.body.isNotEmpty) ...[
            const SizedBox(height: 8),
            mentionText(context, post.body, post.mentions, names ?? const {}),
          ],
          if (post.filePath != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.attach_file),
              label: Text(post.fileName ?? 'Open file', overflow: TextOverflow.ellipsis),
              onPressed: () => openPostFile(context, post),
            ),
          ],
          if (footer != null) ...[const SizedBox(height: 8), footer!],
        ]),
      ),
    );
  }
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
  Future<(List<Post>, Map<String, String>)> _load() async => (await Repo.posts(), await Repo.memberNames());
  void _reload() => setState(() => _f = _load());
  late final _comments = Repo.itemComments('post');
  late final _reactions = Repo.itemReactions();

  String _audience(Post p) {
    if (p.councilId == null) return 'All representatives';
    for (final c in widget.councils) {
      if (c.id == p.councilId) return c.name;
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
        final (all, names) = data;
        final posts = [
          ...all.where((p) => p.id == widget.focusId),
          ...all.where((p) => p.id != widget.focusId),
        ];
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
                  if (posts.isEmpty) const EmptyState('No posts yet'),
                  for (final p in posts)
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: PostCard(
                          post: p,
                          highlight: p.id == widget.focusId,
                          names: names,
                          audience: widget.officer ? _audience(p) : null,
                          onEdit: widget.officer ? () => _edit(p) : null,
                          onDelete: widget.officer ? () => _delete(p) : null,
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
