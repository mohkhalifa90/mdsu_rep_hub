import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import 'format.dart';
import 'widgets.dart';

/// Teams-like channels. Used by both the rep app and the officer app.
class ChannelsPage extends StatefulWidget {
  final Profile me;
  final bool wide; // officer desktop: list + chat side by side
  const ChannelsPage({super.key, required this.me, this.wide = false});
  @override
  State<ChannelsPage> createState() => _ChannelsPageState();
}

class _ChannelsPageState extends State<ChannelsPage> {
  late Future<(List<Channel>, Map<String, String>)> _f = _load();
  Channel? _selected;

  Future<(List<Channel>, Map<String, String>)> _load() async => (await Repo.channels(), await Repo.memberNames());

  Future<void> _newChannel() async {
    final name = TextEditingController(), desc = TextEditingController();
    String audience = 'all';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('New channel'),
          content: SizedBox(
            width: 400,
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
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok == true && name.text.trim().isNotEmpty) {
      await runAction(context,
          () => Repo.createChannel(name: name.text.trim(), description: desc.text.trim(), audience: audience));
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
        final list = ListView(children: [
          for (final c in channels)
            ListTile(
              leading: Icon(c.officerOnly ? Icons.campaign_outlined : Icons.forum_outlined),
              title: Text(c.name),
              subtitle: Text(c.description, maxLines: 1, overflow: TextOverflow.ellipsis),
              selected: widget.wide && _selected?.id == c.id,
              onTap: () {
                if (widget.wide) {
                  setState(() => _selected = c);
                } else {
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => Scaffold(
                                appBar: AppBar(title: Text(c.name)),
                                body: ChatView(channel: c, me: widget.me, names: names),
                              )));
                }
              },
            ),
          if (widget.me.isOfficer)
            ListTile(leading: const Icon(Icons.add), title: const Text('New channel'), onTap: _newChannel),
        ]);
        if (!widget.wide) return list;
        final sel = _selected ?? (channels.isEmpty ? null : channels.first);
        return Row(children: [
          SizedBox(width: 280, child: list),
          const VerticalDivider(width: 1),
          Expanded(
            child: sel == null
                ? const EmptyState('No channels yet')
                : ChatView(key: ValueKey(sel.id), channel: sel, me: widget.me, names: names),
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
  const ChatView({super.key, required this.channel, required this.me, required this.names});
  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _text = TextEditingController();
  bool _announcement = false;
  Set<String> _read = {};
  late final Stream<List<Message>> _stream = Repo.messageStream(widget.channel.id);

  @override
  void initState() {
    super.initState();
    _announcement = widget.channel.officerOnly;
    Repo.myReadMessageIds().then((r) {
      if (mounted) setState(() => _read = r);
    });
  }

  bool get _canPost => !widget.channel.officerOnly || widget.me.isOfficer;

  Future<void> _send() async {
    final body = _text.text.trim();
    if (body.isEmpty) return;
    final ok = await runAction(
        context, () => Repo.sendMessage(widget.channel.id, body, announcement: widget.me.isOfficer && _announcement));
    if (ok) _text.clear();
  }

  Future<void> _showReads(Message m) async {
    final rows = await Repo.announcementReads(m.id);
    if (!mounted) return;
    final read = rows.where((r) => r['read_at'] != null).length;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Read by $read of ${rows.length}'),
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
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(children: [
      Expanded(
        child: StreamBuilder<List<Message>>(
          stream: _stream,
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(error: snap.error!);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final msgs = snap.data!;
            if (msgs.isEmpty) return const EmptyState('No messages yet');
            return ListView.builder(
              reverse: true,
              padding: const EdgeInsets.all(12),
              itemCount: msgs.length,
              itemBuilder: (context, i) {
                final m = msgs[msgs.length - 1 - i];
                final mine = m.authorId == widget.me.id;
                final bg = m.isAnnouncement
                    ? const Color(0xFFFFF6DC)
                    : (mine ? t.colorScheme.primaryContainer : t.colorScheme.surfaceContainerHighest);
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          '${widget.names[m.authorId] ?? 'Someone'} · ${fmtDateTime(m.createdAt)}'
                          '${m.isAnnouncement ? ' · announcement' : ''}',
                          style: t.textTheme.labelSmall,
                        ),
                        const SizedBox(height: 4),
                        SelectableText(m.body),
                        if (m.isAnnouncement && widget.me.isOfficer)
                          TextButton.icon(
                              onPressed: () => _showReads(m),
                              icon: const Icon(Icons.done_all, size: 16),
                              label: const Text('Who has read this?')),
                        if (m.isAnnouncement && !widget.me.isOfficer)
                          _read.contains(m.id)
                              ? Text('✓ You confirmed you read this', style: t.textTheme.labelSmall)
                              : TextButton.icon(
                                  onPressed: () async {
                                    if (await runAction(context, () => Repo.markRead(m.id))) {
                                      setState(() => _read = {..._read, m.id});
                                    }
                                  },
                                  icon: const Icon(Icons.thumb_up_alt_outlined, size: 16),
                                  label: const Text('Mark as read')),
                      ]),
                    ),
                  ),
                );
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
            if (widget.me.isOfficer)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _announcement,
                onChanged: (v) => setState(() => _announcement = v ?? false),
                title: const Text('Announcement (push + read confirmation)'),
              ),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(hintText: 'Write to ${widget.channel.name}…'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _send, icon: const Icon(Icons.send)),
            ]),
          ]),
        )
      else
        const Padding(
            padding: EdgeInsets.all(12), child: Text('Only the Head of Education can post in this channel')),
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
  void dispose() {
    Repo.markAllNotificationsRead();
    super.dispose();
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
                  onTap: n.link == null || widget.onOpen == null
                      ? null
                      : () {
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

class _NotificationBellState extends State<NotificationBell> {
  final Stream<List<AppNotification>> _stream = Repo.notificationStream();

  @override
  Widget build(BuildContext context) => StreamBuilder<List<AppNotification>>(
        stream: _stream,
        builder: (context, snap) {
          final unread = (snap.data ?? const <AppNotification>[]).where((n) => n.readAt == null).length;
          return IconButton(
            tooltip: 'Notifications',
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => NotificationsPage(onOpen: widget.onOpen))),
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.notifications_outlined),
            ),
          );
        },
      );
}
