import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/models.dart';
import '../shared/format.dart';
import '../shared/widgets.dart';

const _councilColors = [
  Color(0xFF1E88E5), Color(0xFF8E24AA), Color(0xFF43A047), Color(0xFFFB8C00),
  Color(0xFF00897B), Color(0xFFD81B60), Color(0xFF3949AB), Color(0xFF6D4C41),
];
Color councilColor(String id) => _councilColors[id.hashCode.abs() % _councilColors.length];

/// A month of meetings. Wide screens show the meetings in each day; phones show dots
/// and the chosen day's meetings below the month.
class MeetingsCalendar extends StatefulWidget {
  final List<Meeting> meetings;
  final String Function(String councilId) councilName;
  final void Function(Meeting m) onOpen;
  final void Function(DateTime day) onAdd;
  const MeetingsCalendar(
      {super.key, required this.meetings, required this.councilName, required this.onOpen, required this.onAdd});
  @override
  State<MeetingsCalendar> createState() => _MeetingsCalendarState();
}

class _MeetingsCalendarState extends State<MeetingsCalendar> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime? _picked;

  static bool _same(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
  List<Meeting> _on(DateTime d) => widget.meetings.where((m) => _same(m.startsAt, d)).toList()
    ..sort((a, b) => a.startsAt.compareTo(b.startsAt));

  void _move(int months) => setState(() {
        _month = DateTime(_month.year, _month.month + months);
        _picked = null;
      });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final narrow = isNarrow(context);
    final now = DateTime.now();
    final first = _month;
    final lead = (first.weekday + 6) % 7; // Monday first
    final daysInMonth = DateTime(first.year, first.month + 1, 0).day;
    final cells = ((lead + daysInMonth) / 7).ceil() * 7;
    final inMonth = widget.meetings.where((m) => m.startsAt.year == first.year && m.startsAt.month == first.month);
    final picked = _picked;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        IconButton(onPressed: () => _move(-1), icon: const Icon(Icons.chevron_left), tooltip: 'Previous month'),
        Expanded(
          child: Column(children: [
            Text(DateFormat('MMMM y').format(first), style: t.textTheme.titleLarge),
            Text('${inMonth.length} meeting${inMonth.length == 1 ? '' : 's'}', style: t.textTheme.bodySmall),
          ]),
        ),
        TextButton(
            onPressed: () => setState(() {
                  _month = DateTime(now.year, now.month);
                  _picked = DateTime(now.year, now.month, now.day);
                }),
            child: const Text('Today')),
        IconButton(onPressed: () => _move(1), icon: const Icon(Icons.chevron_right), tooltip: 'Next month'),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        for (final d in const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'])
          Expanded(child: Center(child: Text(narrow ? d.substring(0, 1) : d, style: t.textTheme.labelMedium))),
      ]),
      const SizedBox(height: 4),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: Column(key: ValueKey(first), children: [
          for (var row = 0; row < cells ~/ 7; row++)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (var col = 0; col < 7; col++) Expanded(child: _cell(context, row * 7 + col - lead + 1, daysInMonth, narrow)),
            ]),
        ]),
      ),
      if (narrow && picked != null) ...[
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: Text(DateFormat('EEEE d MMMM').format(picked), style: t.textTheme.titleMedium)),
          TextButton.icon(
              onPressed: () => widget.onAdd(picked), icon: const Icon(Icons.add), label: const Text('Add')),
        ]),
        if (_on(picked).isEmpty) Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('No meetings this day', style: t.textTheme.bodySmall),
        ),
        for (final m in _on(picked))
          Card(
            child: ListTile(
              leading: CircleAvatar(radius: 6, backgroundColor: councilColor(m.councilId)),
              title: Text(m.title),
              subtitle: Text('${fmtTime(m.startsAt)} · ${widget.councilName(m.councilId)}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => widget.onOpen(m),
            ),
          ),
      ],
    ]);
  }

  Widget _cell(BuildContext context, int day, int daysInMonth, bool narrow) {
    final t = Theme.of(context);
    if (day < 1 || day > daysInMonth) return SizedBox(height: narrow ? 52 : 110);
    final date = DateTime(_month.year, _month.month, day);
    final today = _same(date, DateTime.now());
    final picked = _picked != null && _same(date, _picked!);
    final list = _on(date);
    final weekend = date.weekday >= 6;

    final number = Container(
      width: 26,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: today ? t.colorScheme.primary : null, shape: BoxShape.circle),
      child: Text('$day',
          style: t.textTheme.labelMedium?.copyWith(
              color: today ? t.colorScheme.onPrimary : (weekend ? t.colorScheme.outline : null),
              fontWeight: today ? FontWeight.bold : null)),
    );

    return Padding(
      padding: const EdgeInsets.all(2),
      child: Material(
        color: picked
            ? t.colorScheme.primaryContainer
            : (weekend ? t.colorScheme.surfaceContainerLow : t.colorScheme.surfaceContainerLowest),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            if (narrow) {
              setState(() => _picked = date);
            } else if (list.isEmpty) {
              widget.onAdd(date);
            }
          },
          child: SizedBox(
            height: narrow ? 52 : 110,
            child: narrow
                ? Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    number,
                    const SizedBox(height: 2),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      for (final m in list.take(3))
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: BoxDecoration(color: councilColor(m.councilId), shape: BoxShape.circle),
                        ),
                    ]),
                  ])
                : Padding(
                    padding: const EdgeInsets.all(4),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      number,
                      for (final m in list.take(3)) _chip(context, m),
                      if (list.length > 3)
                        Text('+${list.length - 3} more', style: t.textTheme.labelSmall),
                    ]),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, Meeting m) {
    final c = councilColor(m.councilId);
    return Tooltip(
      message: '${m.title}\n${fmtDateTime(m.startsAt)} · ${widget.councilName(m.councilId)}',
      child: InkWell(
        onTap: () => widget.onOpen(m),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.14),
            border: Border(left: BorderSide(color: c, width: 3)),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text('${fmtTime(m.startsAt)} ${m.title}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: c)),
        ),
      ),
    );
  }
}
