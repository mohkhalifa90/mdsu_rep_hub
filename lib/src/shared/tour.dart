import 'package:flutter/material.dart';

import 'theme.dart';

/// One page of the welcome tour
class TourPage {
  final IconData icon;
  final String title;
  final String text;
  const TourPage(this.icon, this.title, this.text);
}

const repTour = [
  TourPage(Icons.waving_hand_outlined, 'Welcome to Rep Hub',
      'Everything you need as a student representative in one place: your hours, your meetings and news from the Head of Education.'),
  TourPage(Icons.schedule, 'Hours',
      'Log your time after each meeting or task. Press Submit before the deadline – the Head of Education approves it and you get paid.'),
  TourPage(Icons.event_note_outlined, 'Meetings',
      'Say if you come (in the room, online or not) and send topics for the agenda. Only people who attend can log time for a meeting.'),
  TourPage(Icons.forum_outlined, 'Channels',
      'Posts from the Head of Education. Comment, react and tag others with @. A red number on a tab means something new is waiting.'),
  TourPage(Icons.notifications_active_outlined, 'Notifications',
      'Turn on notifications so you do not miss meetings and deadlines. Tap a notification to go straight to it.'),
];

const officerTour = [
  TourPage(Icons.today_outlined, 'Today',
      'Your start page: what needs you now (reports to review, sign-ups, deadlines), quick actions and the next meetings.'),
  TourPage(Icons.schedule, 'Time reports',
      'Follow the steps: reps submit → you review → download Excel for payroll → mark as paid. Tap a number to see who.'),
  TourPage(Icons.event_seat_outlined, 'Programmes & seats',
      'Who sits where, and which seats are vacant. Tap any number to list those programmes. Add reps by email.'),
  TourPage(Icons.forum_outlined, 'Channels and posts',
      'Only you post; reps comment. Tag people with @, react, edit or delete. Red numbers on the left show what is waiting.'),
  TourPage(Icons.search, 'Find anything',
      'Press Ctrl+K (or the search button at the top) to jump to a representative, programme, meeting or channel.'),
];

/// Shows the tour. When [markSeen] is true it is remembered on the account.
Future<void> showTour(BuildContext context, List<TourPage> pages, {bool markSeen = true}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _TourDialog(pages: pages),
  );
  if (markSeen && !AppTheme.instance.onboarded) {
    AppTheme.instance.onboarded = true;
    await AppTheme.instance.save();
  }
}

class _TourDialog extends StatefulWidget {
  final List<TourPage> pages;
  const _TourDialog({required this.pages});
  @override
  State<_TourDialog> createState() => _TourDialogState();
}

class _TourDialogState extends State<_TourDialog> {
  final _pc = PageController();
  int _i = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final last = _i == widget.pages.length - 1;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 440),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Expanded(
              child: PageView(
                controller: _pc,
                onPageChanged: (i) => setState(() => _i = i),
                children: [
                  for (final p in widget.pages)
                    Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      CircleAvatar(
                        radius: 36,
                        backgroundColor: t.colorScheme.primaryContainer,
                        child: Icon(p.icon, size: 36, color: t.colorScheme.primary),
                      ),
                      const SizedBox(height: 18),
                      Text(p.title, textAlign: TextAlign.center, style: t.textTheme.titleLarge),
                      const SizedBox(height: 10),
                      Text(p.text, textAlign: TextAlign.center, style: t.textTheme.bodyMedium),
                    ]),
                ],
              ),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 0; i < widget.pages.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.all(3),
                  width: i == _i ? 18 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == _i ? t.colorScheme.primary : t.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              if (!last) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Skip')),
              const Spacer(),
              FilledButton(
                onPressed: last
                    ? () => Navigator.pop(context)
                    : () => _pc.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
                child: Text(last ? 'Get started' : 'Next'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
