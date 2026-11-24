import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import 'format.dart';
import 'widgets.dart';

// One design for every place people interact: channel posts, posts from the Head of Education and
// the tutoring board. Emoji reactions, comments, @tags, edit and delete look and work the same.

const reactionEmojis = ['👍', '❤️', '🎉', '👏', '😂', '🙏'];

/// Choose people to tag. "@Name" is added to [into] and their ids to [tags].
Future<void> pickTags(BuildContext context,
    {required Map<String, String> names,
    required String meId,
    required TextEditingController into,
    required Set<String> tags}) async {
  final people = names.entries.where((e) => e.key != meId && e.value.trim().isNotEmpty).toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  final chosen = <String>{};
  var q = '';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        final shown = people.where((e) => e.value.toLowerCase().contains(q.toLowerCase())).toList();
        return AlertDialog(
          title: const Text('Tag people'),
          content: SizedBox(
            width: 400,
            height: 420,
            child: Column(children: [
              TextField(
                autofocus: true,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name'),
                onChanged: (v) => setD(() => q = v),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(children: [
                  for (final e in shown)
                    CheckboxListTile(
                      dense: true,
                      value: chosen.contains(e.key),
                      onChanged: (v) => setD(() => v == true ? chosen.add(e.key) : chosen.remove(e.key)),
                      title: Text(e.value),
                    ),
                ]),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
                onPressed: chosen.isEmpty ? null : () => Navigator.pop(ctx, true),
                child: Text(chosen.isEmpty ? 'Tag' : 'Tag ${chosen.length}')),
          ],
        );
      },
    ),
  );
  if (ok != true) return;
  final add = chosen.map((id) => '@${names[id]}').join(' ');
  final t = into.text;
  into.text = t.isEmpty || t.endsWith(' ') ? '$t$add ' : '$t $add ';
  into.selection = TextSelection.collapsed(offset: into.text.length);
  tags.addAll(chosen);
}

/// Keep only the tags whose "@Name" is still in the text
List<String> tagsIn(String text, Set<String> tags, Map<String, String> names) =>
    [for (final id in tags) if (names[id] != null && text.contains('@${names[id]}')) id];

/// Text with tagged names highlighted, as a span (for measuring and folding)
TextSpan mentionSpan(BuildContext context, String body, List<String> mentions, Map<String, String> names) {
  final t = Theme.of(context);
  final tagged = [
    for (final id in mentions)
      if (names[id] != null) '@${names[id]}'
  ];
  if (tagged.isEmpty) return TextSpan(text: body, style: t.textTheme.bodyMedium);
  final re = RegExp(tagged.map(RegExp.escape).join('|'));
  final spans = <TextSpan>[];
  var last = 0;
  for (final hit in re.allMatches(body)) {
    if (hit.start > last) spans.add(TextSpan(text: body.substring(last, hit.start)));
    spans.add(TextSpan(text: hit.group(0), style: TextStyle(color: t.colorScheme.primary, fontWeight: FontWeight.w600)));
    last = hit.end;
  }
  if (last < body.length) spans.add(TextSpan(text: body.substring(last)));
  return TextSpan(style: t.textTheme.bodyMedium, children: spans);
}

/// Text with tagged names highlighted; long text is folded after a few lines with "See more"
Widget mentionText(BuildContext context, String body, List<String> mentions, Map<String, String> names,
        {int maxLines = 4}) =>
    ExpandableText(span: mentionSpan(context, body, mentions, names), maxLines: maxLines);

/// Shows [maxLines] lines and "See more"; opens to the whole text and "See less".
class ExpandableText extends StatefulWidget {
  final TextSpan span;
  final int maxLines;
  const ExpandableText({super.key, required this.span, this.maxLines = 4});
  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final tp = TextPainter(
          text: widget.span,
          maxLines: widget.maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: c.maxWidth);
        if (!tp.didExceedMaxLines) return SelectableText.rich(widget.span);
        final link = TextButton(
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
          onPressed: () => setState(() => _open = !_open),
          child: Text(_open ? 'See less' : 'See more'),
        );
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _open
              ? SelectableText.rich(widget.span)
              : Text.rich(widget.span, maxLines: widget.maxLines, overflow: TextOverflow.ellipsis),
          link,
        ]);
      });
}

/// "💬 Comment" and "3 comments ▾" under a post
class CommentActions extends StatelessWidget {
  final int count;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback onComment;
  const CommentActions(
      {super.key, required this.count, required this.open, required this.onToggle, required this.onComment});

  @override
  Widget build(BuildContext context) {
    final style = TextButton.styleFrom(
        visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8));
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
      if (count > 0)
        TextButton(
          style: style,
          onPressed: onToggle,
          child: Text('$count comment${count == 1 ? '' : 's'} ${open ? '▴' : '▾'}'),
        ),
      TextButton.icon(
        style: style,
        onPressed: onComment,
        icon: const Icon(Icons.chat_bubble_outline, size: 16),
        label: const Text('Comment'),
      ),
    ]);
  }
}

/// Emoji chips (tap to add/remove yours, hover to see who) and a button to add one.
class ReactionBar extends StatelessWidget {
  final List<(String userId, String emoji)> reactions;
  final String meId;
  final Map<String, String> names;
  final Future<void> Function(String emoji, bool on) onToggle;
  const ReactionBar(
      {super.key, required this.reactions, required this.meId, required this.names, required this.onToggle});

  void _go(BuildContext context, String emoji, bool on) {
    onToggle(emoji, on).catchError((Object e) {
      if (context.mounted) showSnack(context, errorText(e));
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final groups = <String, List<String>>{};
    for (final (user, emoji) in reactions) {
      groups.putIfAbsent(emoji, () => []).add(user);
    }
    return Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final e in groups.entries)
        Builder(builder: (context) {
          final mine = e.value.contains(meId);
          return Tooltip(
            // who reacted, e.g. "Dania Khamis, Salma"
            message: e.value.map((u) => u == meId ? 'You' : (names[u] ?? '')).join(', '),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _go(context, e.key, !mine),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  // yours: coloured with a border; other people's: plain grey
                  color: mine ? t.colorScheme.primaryContainer : t.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: mine ? t.colorScheme.primary : Colors.transparent, width: 1.5),
                ),
                child: Text('${e.key} ${e.value.length}',
                    style: TextStyle(fontWeight: mine ? FontWeight.w700 : FontWeight.normal)),
              ),
            ),
          );
        }),
      PopupMenuButton<String>(
        tooltip: 'React',
        icon: Icon(Icons.add_reaction_outlined, size: 18, color: t.colorScheme.onSurfaceVariant),
        onSelected: (emoji) => _go(context, emoji, true),
        itemBuilder: (_) => [
          for (final e in reactionEmojis)
            PopupMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 22))),
        ],
      ),
    ]);
  }
}

/// Edit text in a dialog. Returns the new text, or null when cancelled.
Future<String?> editTextDialog(BuildContext context, {required String title, required String initial}) async {
  final c = TextEditingController(text: initial);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(width: 520, child: TextField(controller: c, autofocus: true, minLines: 3, maxLines: 12)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
      ],
    ),
  );
  if (ok != true || c.text.trim().isEmpty) return null;
  return c.text.trim();
}

/// ⋮ menu with Edit (own) and Delete (own, or anything for the Head of Education)
class EditDeleteMenu extends StatelessWidget {
  final bool canEdit;
  final bool canDelete;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const EditDeleteMenu(
      {super.key, required this.canEdit, required this.canDelete, required this.onEdit, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    if (!canEdit && !canDelete) return const SizedBox.shrink();
    return SizedBox(
      height: 28,
      child: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        iconSize: 18,
        tooltip: 'More',
        onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
        itemBuilder: (_) => [
          if (canEdit) const PopupMenuItem(value: 'edit', child: Text('Edit')),
          if (canDelete) const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

/// Reactions on an item, its comments (each with reactions, edit/delete) and a comment box with @tag.
/// [kind] is 'post' or 'tutoring'.
/// Reactions on an item, its comments (folded: the latest one, "View all") and a comment box that opens
/// with "Comment". [kind] is 'post' or 'tutoring'.
class ItemInteractions extends StatefulWidget {
  final String kind;
  final String itemId;
  final String meId;
  final bool officer;
  final Map<String, String> names;
  final List<ItemComment> comments; // of this item
  final List<ItemReaction> reactions; // all (filtered here)
  final bool canComment;
  final bool initiallyOpen; // e.g. opened from a notification
  const ItemInteractions({
    super.key,
    required this.kind,
    required this.itemId,
    required this.meId,
    required this.officer,
    required this.names,
    required this.comments,
    required this.reactions,
    this.canComment = true,
    this.initiallyOpen = false,
  });
  @override
  State<ItemInteractions> createState() => _ItemInteractionsState();
}

class _ItemInteractionsState extends State<ItemInteractions> {
  final _text = TextEditingController();
  final _tags = <String>{};
  late bool _open = widget.initiallyOpen;
  bool _writing = false;
  final _hidden = <String>{}; // deleted, waiting for Undo to run out

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  List<(String, String)> _of(String kind, String id) => [
        for (final r in widget.reactions)
          if (r.kind == kind && r.itemId == id) (r.userId, r.emoji)
      ];

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    if (await runAction(context,
        () => Repo.addItemComment(widget.kind, widget.itemId, text, mentions: tagsIn(text, _tags, widget.names)))) {
      _text.clear();
      _tags.clear();
      setState(() {
        _open = true;
        _writing = false;
      });
    }
  }

  Widget _comment(ItemComment c) {
    final t = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(
                '${widget.names[c.authorId] ?? 'Someone'} · ${fmtDateTime(c.createdAt)}'
                '${c.editedAt != null ? ' · edited' : ''}',
                style: t.textTheme.labelSmall),
          ),
          EditDeleteMenu(
            canEdit: c.authorId == widget.meId,
            canDelete: c.authorId == widget.meId || widget.officer,
            onEdit: () async {
              final v = await editTextDialog(context, title: 'Edit comment', initial: c.body);
              if (v != null && mounted) await runAction(context, () => Repo.editItemComment(c.id, v));
            },
            onDelete: () => deleteWithUndo(context, 'Comment deleted', () => Repo.deleteItemComment(c.id),
                hide: () => setState(() => _hidden.add(c.id)), restore: () => setState(() => _hidden.remove(c.id))),
          ),
        ]),
        mentionText(context, c.body, c.mentions, widget.names),
        ReactionBar(
          reactions: _of('comment', c.id),
          meId: widget.meId,
          names: widget.names,
          onToggle: (e, on) => Repo.reactItem('comment', c.id, e, on),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.comments.where((c) => !_hidden.contains(c.id)).toList();
    // folded: only the latest comment
    final shown = _open || list.length <= 1 ? list : [list.last];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: ReactionBar(
            reactions: _of(widget.kind, widget.itemId),
            meId: widget.meId,
            names: widget.names,
            onToggle: (e, on) => Repo.reactItem(widget.kind, widget.itemId, e, on),
          ),
        ),
        CommentActions(
          count: list.length,
          open: _open,
          onToggle: () => setState(() => _open = !_open),
          onComment: widget.canComment ? () => setState(() => _writing = !_writing) : () {},
        ),
      ]),
      if (shown.isNotEmpty || _writing) const Divider(height: 12),
      if (!_open && list.length > 1)
        TextButton(onPressed: () => setState(() => _open = true), child: Text('View all ${list.length} comments')),
      for (final c in shown) _comment(c),
      if (_open && list.length > 1)
        TextButton(onPressed: () => setState(() => _open = false), child: const Text('Hide comments')),
      if (widget.canComment && _writing)
        Row(children: [
          IconButton(
            tooltip: 'Tag people',
            icon: const Icon(Icons.alternate_email),
            onPressed: () async {
              await pickTags(context, names: widget.names, meId: widget.meId, into: _text, tags: _tags);
              setState(() {});
            },
          ),
          Expanded(
            child: TextField(
              controller: _text,
              autofocus: true,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(hintText: 'Write a comment…'),
            ),
          ),
          IconButton(tooltip: 'Send comment', onPressed: _send, icon: const Icon(Icons.send)),
        ]),
    ]);
  }
}
