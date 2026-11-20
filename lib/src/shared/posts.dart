import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../data/repo.dart';
import 'format.dart';
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
  const PostCard({super.key, required this.post, this.audience, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(post.isFinalAgenda ? Icons.description_outlined : Icons.campaign_outlined, color: t.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(post.title, style: t.textTheme.titleMedium),
                Text('${fmtDateTime(post.createdAt)}${audience == null ? '' : ' · $audience'}',
                    style: t.textTheme.bodySmall),
              ]),
            ),
            if (onDelete != null)
              IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: onDelete),
          ]),
          if (post.body.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(post.body),
          ],
          if (post.filePath != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.attach_file),
              label: Text(post.fileName ?? 'Open file', overflow: TextOverflow.ellipsis),
              onPressed: () => openPostFile(context, post),
            ),
          ],
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
  const PostsPage({super.key, this.officer = false, this.councils = const [], this.standalone = false});
  @override
  State<PostsPage> createState() => _PostsPageState();
}

class _PostsPageState extends State<PostsPage> {
  late Future<List<Post>> _f = Repo.posts();
  void _reload() => setState(() => _f = Repo.posts());

  String _audience(Post p) {
    if (p.councilId == null) return 'All representatives';
    for (final c in widget.councils) {
      if (c.id == p.councilId) return c.name;
    }
    return 'One council';
  }

  @override
  Widget build(BuildContext context) {
    final list = Loader<List<Post>>(
      future: _f,
      onRetry: _reload,
      builder: (context, posts) => RefreshIndicator(
        onRefresh: () async => _reload(),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (widget.officer)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                icon: const Icon(Icons.campaign_outlined),
                label: const Text('New post'),
                onPressed: () async {
                  if (await showNewPostDialog(context, councils: widget.councils)) _reload();
                },
              ),
            ),
          if (widget.officer) const SizedBox(height: 8),
          if (posts.isEmpty) const EmptyState('No posts yet'),
          for (final p in posts)
            PostCard(
              post: p,
              audience: widget.officer ? _audience(p) : null,
              onDelete: !widget.officer
                  ? null
                  : () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Delete this post?'),
                          content: const Text('Representatives will no longer see it. Notifications already sent stay.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                          ],
                        ),
                      );
                      if (ok == true && context.mounted && await runAction(context, () => Repo.deletePost(p))) {
                        _reload();
                      }
                    },
            ),
        ]),
      ),
    );
    if (!widget.standalone) return list;
    return Scaffold(appBar: AppBar(title: const Text('From the Head of Education')), body: list);
  }
}

/// New post (or, with [meeting], the final agenda of that meeting). Returns true when sent.
Future<bool> showNewPostDialog(BuildContext context, {required List<Council> councils, Meeting? meeting}) async {
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
