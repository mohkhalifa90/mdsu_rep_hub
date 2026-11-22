import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One slice of a donut
class Slice {
  final String label;
  final int value;
  final Color color;
  const Slice(this.label, this.value, this.color);
}

/// A small animated donut with a legend; the middle shows [center] (e.g. "12 of 40").
class DonutCard extends StatelessWidget {
  final String title;
  final List<Slice> slices;
  final String center;
  const DonutCard({super.key, required this.title, required this.slices, required this.center});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 96,
            height: 96,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => CustomPaint(
                painter: _DonutPainter(slices, v, t.colorScheme.surfaceContainerHighest),
                child: Center(
                  child: Text(center,
                      textAlign: TextAlign.center, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.textTheme.titleSmall),
            const SizedBox(height: 6),
            for (final s in slices)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Text('${s.label}  ${s.value}', style: t.textTheme.bodySmall),
                ]),
              ),
          ]),
        ]),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<Slice> slices;
  final double progress;
  final Color track;
  _DonutPainter(this.slices, this.progress, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.14;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: size.width / 2 - stroke / 2);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    final total = slices.fold<int>(0, (a, s) => a + s.value);
    if (total == 0) return;
    var start = -math.pi / 2;
    for (final s in slices) {
      final sweep = math.pi * 2 * s.value / total * progress;
      if (sweep <= 0) continue;
      canvas.drawArc(
          rect,
          start,
          sweep,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.butt
            ..color = s.color);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) => old.progress != progress || old.slices != slices;
}
