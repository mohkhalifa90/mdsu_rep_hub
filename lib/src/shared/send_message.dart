import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'widgets.dart';

/// Opens Outlook (or the computer's mail app) with the email ready: address, subject and text.
Future<void> openEmail(String email, {String subject = '', String body = ''}) => launchUrl(Uri.parse(
    'mailto:$email?subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(body)}'));

/// Opens a Teams chat with the person, with the message typed in (they press Send).
Future<void> openTeamsChat(String email, {String message = ''}) => launchUrl(
    Uri.parse('https://teams.microsoft.com/l/chat/0/0?users=${Uri.encodeComponent(email)}'
        '${message.isEmpty ? '' : '&message=${Uri.encodeComponent(message)}'}'),
    mode: LaunchMode.externalApplication);

/// A ready message with Copy, Email (Outlook) and Teams buttons.
Future<void> showSendMessage(
  BuildContext context, {
  required String title,
  String intro = 'Send this to the representative:',
  required String? email,
  required String subject,
  required String message,
  String? footer,
}) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(intro),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
              child: SelectableText(message),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: message));
                  if (ctx.mounted) showSnack(ctx, 'Copied');
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
              if (email != null && email.isNotEmpty) ...[
                OutlinedButton.icon(
                  onPressed: () => openEmail(email, subject: subject, body: message),
                  icon: const Icon(Icons.mail_outline, size: 18),
                  label: const Text('Email (Outlook)'),
                ),
                OutlinedButton.icon(
                  onPressed: () => openTeamsChat(email, message: message),
                  icon: const Icon(Icons.chat_outlined, size: 18),
                  label: const Text('Teams'),
                ),
              ],
            ]),
            if (footer != null) ...[
              const SizedBox(height: 12),
              Text(footer, style: Theme.of(ctx).textTheme.bodySmall),
            ],
          ]),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
      ),
    );
