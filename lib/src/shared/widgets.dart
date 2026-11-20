import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/repo.dart';

/// Turns server errors into readable text.
String errorText(Object e) {
  if (e is PostgrestException) return e.message;
  if (e is AuthException) return e.message;
  if (e is StorageException) return e.message;
  if (e is FunctionException) {
    final d = e.details;
    if (d is Map && d['error'] != null) return '${d['error']}';
    return 'Server error (${e.status})';
  }
  if (e is Exception) return e.toString().replaceFirst('Exception: ', '');
  return e.toString();
}

void showSnack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Runs an action, shows errors as a snackbar. Returns true on success.
Future<bool> runAction(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (success != null && context.mounted) showSnack(context, success);
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
    return false;
  }
}

class ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback? onRetry;
  const ErrorView({super.key, required this.error, this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 8),
            Text(errorText(error), textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ]),
        ),
      );
}

/// FutureBuilder with loading + error states.
class Loader<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(BuildContext, T) builder;
  final VoidCallback? onRetry;
  const Loader({super.key, required this.future, required this.builder, this.onRetry});

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: future,
        builder: (context, snap) {
          if (snap.hasError) return ErrorView(error: snap.error!, onRetry: onRetry);
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return builder(context, snap.data as T);
        },
      );
}

class EmptyState extends StatelessWidget {
  final String text;
  const EmptyState(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(text, style: TextStyle(color: Theme.of(context).hintColor))),
      );
}

class StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const StatusChip(this.label, this.color, {super.key});

  static StatusChip report(String status) {
    const labels = {
      'draft': 'Draft',
      'submitted': 'Submitted',
      'returned': 'Returned',
      'approved': 'Approved',
      'paid': 'Paid'
    };
    final c = switch (status) {
      'submitted' => Colors.blue.shade700,
      'returned' => Colors.orange.shade800,
      'approved' => Colors.green.shade700,
      'paid' => Colors.purple.shade700,
      _ => Colors.grey.shade700,
    };
    return StatusChip(labels[status] ?? status, c);
  }

  static StatusChip issue(String status) {
    const labels = {
      'awaiting': 'Awaiting response',
      'answered': 'Answered',
      'escalated': 'Escalated',
      'closed': 'Closed'
    };
    final c = switch (status) {
      'awaiting' => Colors.orange.shade800,
      'answered' => Colors.green.shade700,
      'escalated' => Colors.red.shade700,
      _ => Colors.grey.shade700,
    };
    return StatusChip(labels[status] ?? status, c);
  }

  static StatusChip agenda(String status) => switch (status) {
        'included' => StatusChip('On agenda', Colors.green.shade700),
        'declined' => StatusChip('Not included', Colors.grey.shade700),
        _ => StatusChip('New', Colors.blue.shade700),
      };

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

/// A small card with a label and a big number (dashboard KPIs).
class Kpi extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  const Kpi({super.key, required this.label, required this.value, this.sub});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: isNarrow(context) ? 155 : 190,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              if (sub != null) Text(sub!, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      );
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Row(children: [
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
          if (trailing != null) trailing!,
        ]),
      );
}

/// Simple text-input dialog.
Future<String?> promptText(BuildContext context,
    {required String title, String? label, String initial = '', int maxLines = 1}) async {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: TextField(
            controller: c,
            autofocus: true,
            maxLines: maxLines,
            decoration: InputDecoration(labelText: label)),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'OK'}) async =>
    (await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
        ],
      ),
    )) ??
    false;


/// Easy-to-read temporary password, e.g. "Mdsu-7KQ4-PX2N" (no 0/O or 1/l)
String generateTempPassword() {
  const chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  final r = Random.secure();
  String part() => List.generate(4, (_) => chars[r.nextInt(chars.length)]).join();
  return 'Mdsu-${part()}-${part()}';
}

/// "Change my password" for the signed-in user.
Future<void> showChangePasswordDialog(BuildContext context) async {
  final p1 = TextEditingController(), p2 = TextEditingController();
  String? error;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: const Text('Change my password'),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
                controller: p1, obscureText: true, decoration: const InputDecoration(labelText: 'New password (8+ characters)')),
            const SizedBox(height: 10),
            TextField(controller: p2, obscureText: true, decoration: const InputDecoration(labelText: 'Repeat new password')),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(error!, style: TextStyle(color: Colors.red.shade800)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (p1.text.length < 8) return setD(() => error = 'At least 8 characters');
              if (p1.text != p2.text) return setD(() => error = 'The two passwords are not the same');
              try {
                await Repo.changeMyPassword(p1.text);
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) showSnack(context, 'Password changed ✓');
              } catch (e) {
                setD(() => error = errorText(e));
              }
            },
            child: const Text('Change'),
          ),
        ],
      ),
    ),
  );
}

/// Head of Education: give a representative a temporary password.
Future<void> showResetPasswordDialog(BuildContext context, {required String userId, required String name}) async {
  final pw = TextEditingController(text: generateTempPassword());
  String? error;
  bool done = false, busy = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) => AlertDialog(
        title: Text(done ? 'Password reset ✓' : 'Reset password for $name'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(done
                ? 'Give $name this temporary password (in person, by phone or Teams). '
                    'They should change it under More → My profile.'
                : 'Check that you are talking to $name before you reset the password.'),
            const SizedBox(height: 12),
            TextField(
              controller: pw,
              readOnly: done,
              decoration: InputDecoration(
                labelText: 'Temporary password',
                suffixIcon: IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy),
                  onPressed: () => Clipboard.setData(ClipboardData(text: pw.text)),
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(error!, style: TextStyle(color: Colors.red.shade800)),
              ),
          ]),
        ),
        actions: done
            ? [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))]
            : [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          if (pw.text.length < 8) return setD(() => error = 'At least 8 characters');
                          setD(() {
                            busy = true;
                            error = null;
                          });
                          try {
                            await Repo.adminResetPassword(userId, pw.text);
                            setD(() => done = true);
                          } catch (e) {
                            setD(() => error = errorText(e));
                          }
                          setD(() => busy = false);
                        },
                  child: const Text('Reset password'),
                ),
              ],
      ),
    ),
  );
}


/// Short explanation at the top of a page with its main buttons. Side by side on a wide
/// screen, stacked on a phone so the text is not squeezed.
class PageIntro extends StatelessWidget {
  final String text;
  final List<Widget> actions;
  const PageIntro({super.key, required this.text, this.actions = const []});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final t = Text(text, style: Theme.of(context).textTheme.bodyMedium);
        if (c.maxWidth < 700) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            t,
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: actions),
            ],
          ]);
        }
        return Row(children: [
          Expanded(child: t),
          for (final a in actions) ...[const SizedBox(width: 8), a],
        ]);
      });
}

/// True on a phone-sized screen.
bool isNarrow(BuildContext context) => MediaQuery.of(context).size.width < 720;
