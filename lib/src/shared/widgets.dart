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
          if (snap.connectionState != ConnectionState.done) return const SkeletonList();
          return builder(context, snap.data as T);
        },
      );
}

/// Grey placeholder cards while a page loads – feels faster than a spinner
class SkeletonList extends StatefulWidget {
  final int count;
  const SkeletonList({super.key, this.count = 5});
  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bar(double w, double h) => Container(
        width: w, height: h, decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(6)));
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(_c),
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          for (var i = 0; i < widget.count; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  bar(140, 12),
                  const SizedBox(height: 10),
                  bar(double.infinity, 12),
                  const SizedBox(height: 6),
                  bar(i.isEven ? 220 : 160, 12),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

/// Nothing here yet – with a short hint and, where it helps, the button to start
class EmptyState extends StatelessWidget {
  final String text;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  const EmptyState(this.text, {super.key, this.icon, this.actionLabel, this.onAction});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[
              Icon(icon, size: 40, color: Theme.of(context).hintColor),
              const SizedBox(height: 8),
            ],
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonal(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ]),
        ),
      );
}

/// Delete straight away with "Undo" for a few seconds instead of asking first.
/// The deletion happens when the message goes away without Undo.
/// [hide] takes it off the screen at once, [restore] brings it back on Undo.
void deleteWithUndo(BuildContext context, String message, Future<void> Function() delete,
    {VoidCallback? hide, VoidCallback? restore}) {
  final messenger = ScaffoldMessenger.of(context);
  hide?.call();
  messenger.hideCurrentSnackBar();
  final bar = messenger.showSnackBar(SnackBar(
    content: Text(message),
    duration: const Duration(seconds: 5),
    action: SnackBarAction(label: 'Undo', onPressed: () {}),
  ));
  bar.closed.then((reason) {
    if (reason == SnackBarClosedReason.action) {
      restore?.call();
      return;
    }
    delete().catchError((Object e) {
      restore?.call();
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    });
  });
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
/// A number card. With an icon and colour; lifts a little under the mouse and counts up when shown.
class Kpi extends StatefulWidget {
  final String label;
  final String value;
  final String? sub;
  final IconData? icon;
  final Color? color;
  final VoidCallback? onTap;
  final bool selected; // used as a filter right now
  const Kpi(
      {super.key,
      required this.label,
      required this.value,
      this.sub,
      this.icon,
      this.color,
      this.onTap,
      this.selected = false});
  @override
  State<Kpi> createState() => _KpiState();
}

class _KpiState extends State<Kpi> {
  bool _hover = false;

  /// "28.3 h", "3 705 SEK", "4 of 9": counts up the first number, keeps the rest
  Widget _value(TextStyle? style) {
    final m = RegExp('^(\\d+(?:[ \u00a0]\\d{3})*(?:[.,]\\d+)?)(.*)\$').firstMatch(widget.value);
    if (m == null) return Text(widget.value, style: style);
    final raw = m.group(1)!;
    final target = double.tryParse(raw.replaceAll(RegExp('[ \u00a0]'), '').replaceAll(',', '.'));
    if (target == null) return Text(widget.value, style: style);
    final decimals = raw.contains('.') || raw.contains(',') ? raw.split(RegExp('[.,]')).last.length : 0;
    final sep = raw.contains('\u00a0') ? '\u00a0' : (raw.contains(' ') ? ' ' : null);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: target),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) {
        var s = v.toStringAsFixed(decimals);
        if (sep != null) {
          final parts = s.split('.');
          parts[0] = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => sep);
          s = parts.join('.');
        }
        return Text('$s${m.group(2)}', style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = widget.color ?? t.colorScheme.primary;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 150),
        offset: _hover ? const Offset(0, -0.03) : Offset.zero,
        child: SizedBox(
          width: isNarrow(context) ? 155 : 200,
          child: Card(
            elevation: _hover ? 4 : 0,
            shape: widget.selected
                ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: color, width: 2))
                : null,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (widget.icon != null) ...[
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                        child: Icon(widget.icon, size: 18, color: color),
                      ),
                      const SizedBox(width: 8),
                    ],
                    // one line, so all cards in a row line up
                    Expanded(
                      child: Text(widget.label,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  _value(t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                  if (widget.sub != null) Text(widget.sub!, style: t.textTheme.bodySmall),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
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


/// Switching between the main pages: a short fade with a small upward slide.
Widget pageSwitch(Object key, Widget child) => AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.012), end: Offset.zero).animate(a), child: c),
      ),
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
      child: KeyedSubtree(key: ValueKey(key), child: child),
    );

/// A scrolling page whose content stays a comfortable width on big screens.
class CenteredList extends StatelessWidget {
  final List<Widget> children;
  final double maxWidth;
  const CenteredList({super.key, required this.children, this.maxWidth = 760});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final side = c.maxWidth > maxWidth + 32 ? (c.maxWidth - maxWidth) / 2 : 12.0;
        return ListView(padding: EdgeInsets.fromLTRB(side, 16, side, 24), children: children);
      });
}

/// A calendar-style date: month above, day below.
class DateTile extends StatelessWidget {
  final DateTime date;
  final bool muted;
  final double width;
  const DateTile(this.date, {super.key, this.muted = false, this.width = 54});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bg = muted ? t.colorScheme.surfaceContainerHighest : t.colorScheme.primaryContainer;
    final fg = muted ? t.colorScheme.onSurfaceVariant : t.colorScheme.onPrimaryContainer;
    const months = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
    return Container(
      width: width,
      padding: EdgeInsets.symmetric(vertical: width > 50 ? 8 : 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(months[date.month - 1], style: t.textTheme.labelSmall?.copyWith(color: fg, letterSpacing: 0.8)),
        Text('${date.day}',
            style: (width > 50 ? t.textTheme.headlineSmall : t.textTheme.titleMedium)
                ?.copyWith(color: fg, fontWeight: FontWeight.bold, height: 1.1)),
      ]),
    );
  }
}

/// "Today", "Tomorrow", "In 5 days", "Yesterday", "3 days ago"
String relativeDay(DateTime d) {
  final n = daysUntilDate(d);
  if (n == 0) return 'Today';
  if (n == 1) return 'Tomorrow';
  if (n == -1) return 'Yesterday';
  return n > 1 ? 'In $n days' : '${-n} days ago';
}

int daysUntilDate(DateTime d) {
  final now = DateTime.now();
  return DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
}
