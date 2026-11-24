import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/repo.dart';
import 'avatars.dart';
import 'widgets.dart';

/// Tap a photo or a name: a card with the person's photo, programme, department, councils and
/// (when they share it) their email, with buttons for Teams chat and email.
Future<void> showProfileCard(BuildContext context, String userId, {String? name}) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (_) => _ProfileCard(userId: userId, name: name ?? ''),
    );

class _ProfileCard extends StatelessWidget {
  final String userId;
  final String name;
  const _ProfileCard({required this.userId, required this.name});

  void _bigPhoto(BuildContext context, String url) => showDialog(
        context: context,
        builder: (_) => GestureDetector(
          onTap: () => Navigator.pop(context),
          child: InteractiveViewer(
            child: Center(child: ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.network(url))),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return FutureBuilder<Map<String, dynamic>?>(
      future: Repo.profileCard(userId),
      builder: (context, s) {
        final p = s.data;
        final fullName = (p?['full_name'] as String?) ?? name;
        final role = p?['role'] as String?;
        final email = p?['email'] as String?;
        final photo = p?['avatar_url'] as String?;
        final councils = ((p?['councils'] as List?) ?? const []).cast<String>();
        final details = [
          if ((p?['program'] as String?)?.isNotEmpty ?? false) p!['program'] as String,
          if (p?['study_year'] != null && role == 'rep') 'Year ${p!['study_year']}',
        ].join(' · ');
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              GestureDetector(
                onTap: photo == null ? null : () => _bigPhoto(context, photo),
                child: UserAvatar(id: userId, name: fullName, radius: 52, tappable: false),
              ),
              const SizedBox(height: 12),
              Text(fullName, style: t.textTheme.titleLarge, textAlign: TextAlign.center),
              if (role != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: StatusChip(
                      role == 'rep' ? 'Student representative' : 'Head of Education',
                      role == 'rep' ? t.colorScheme.primary : Colors.deepPurple),
                ),
              if (s.connectionState == ConnectionState.waiting)
                const Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(details, style: t.textTheme.bodyMedium, textAlign: TextAlign.center),
              ],
              if ((p?['department'] as String?)?.isNotEmpty ?? false)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(p!['department'] as String, style: t.textTheme.bodySmall, textAlign: TextAlign.center),
                ),
              if (councils.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 6, runSpacing: 6, alignment: WrapAlignment.center, children: [
                  for (final c in councils)
                    Chip(
                      avatar: const Icon(Icons.groups_outlined, size: 16),
                      label: Text(c, style: t.textTheme.labelSmall),
                      visualDensity: VisualDensity.compact,
                    ),
                ]),
              ],
              const SizedBox(height: 16),
              if (email != null) ...[
                Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: const Icon(Icons.mail_outline),
                    title: SelectableText(email),
                    trailing: IconButton(
                      tooltip: 'Copy',
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: email));
                        showSnack(context, 'Email copied');
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => launchUrl(
                          Uri.parse('https://teams.microsoft.com/l/chat/0/0?users=${Uri.encodeComponent(email)}'),
                          mode: LaunchMode.externalApplication),
                      icon: const Icon(Icons.chat_outlined),
                      label: const Text('Chat in Teams'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => launchUrl(Uri(scheme: 'mailto', path: email)),
                      icon: const Icon(Icons.mail_outline),
                      label: const Text('Email'),
                    ),
                  ),
                ]),
              ] else if (p != null)
                Text('Contact details are not shared', style: t.textTheme.bodySmall),
            ]),
          ),
        );
      },
    );
  }
}
