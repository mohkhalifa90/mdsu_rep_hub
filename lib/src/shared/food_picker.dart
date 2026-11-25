import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import 'format.dart';
import 'widgets.dart';

/// "Special food preference (allergies)" – shown when a rep attends a meeting in the room.
/// One choice. Once saved it shows the answer with a "Change" button (so a stray tap changes nothing).
/// Changes close after the meeting's input deadline (the food is ordered then).
class FoodPicker extends StatefulWidget {
  final String meetingId;
  final DateTime deadline; // last day to change (the agenda input deadline)
  final bool locked; // meeting has started
  final bool compact; // one line with the answer (the meeting card's summary)
  final bool startEditing; // open with the choices showing (the card's "Change")
  final VoidCallback? onTap; // compact: tapping the line
  const FoodPicker(
      {super.key,
      required this.meetingId,
      required this.deadline,
      this.locked = false,
      this.compact = false,
      this.startEditing = false,
      this.onTap});
  @override
  State<FoodPicker> createState() => _FoodPickerState();
}

class _FoodPickerState extends State<FoodPicker> {
  String? _saved; // the saved choice (null = not answered)
  String _savedOther = '';
  String? _choice; // while editing
  final _other = TextEditingController();
  bool _loading = true, _saving = false, _editing = false;

  bool get _closed {
    final now = DateTime.now();
    final d = widget.deadline;
    return widget.locked || DateTime(now.year, now.month, now.day).isAfter(DateTime(d.year, d.month, d.day));
  }

  @override
  void initState() {
    super.initState();
    Repo.myFood(widget.meetingId).then((v) {
      if (!mounted) return;
      setState(() {
        _saved = v.$1.isEmpty ? null : v.$1.first;
        _savedOther = v.$2 ?? '';
        _choice = _saved;
        _other.text = _savedOther;
        _editing = _saved == null || (widget.startEditing && !_closed);
        _loading = false;
      });
    }).catchError((_) {
      if (mounted) setState(() => _loading = false);
    });
  }

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c = _choice;
    if (c == null) return;
    if (c == 'other' && _other.text.trim().isEmpty) {
      showSnack(context, 'Write what "Other" means (e.g. nut allergy)');
      return;
    }
    setState(() => _saving = true);
    final ok = await runAction(
        context, () => Repo.setFood(widget.meetingId, [c], c == 'other' ? _other.text.trim() : null),
        success: 'Food preference saved');
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) {
        _saved = c;
        _savedOther = c == 'other' ? _other.text.trim() : '';
        _editing = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final missing = !_loading && _saved == null;
    final answer = _saved == null ? '' : foodSummary([_saved!], _savedOther);
    if (widget.compact) {
      if (_loading) return const SizedBox(height: 20);
      final color = missing ? Colors.orange.shade900 : t.colorScheme.onSurface;
      return InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Icon(Icons.restaurant_outlined, size: 16, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(missing ? 'Food: not chosen yet – tap to choose' : 'Food: $answer',
                  style: t.textTheme.bodyMedium?.copyWith(color: color, fontWeight: missing ? FontWeight.w600 : null)),
            ),
          ]),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: missing ? Colors.orange.withValues(alpha: 0.08) : t.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: missing ? Colors.orange.shade300 : t.colorScheme.outlineVariant),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.restaurant_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'Special food preference (allergies)'),
                  TextSpan(text: ' *', style: TextStyle(color: Colors.red.shade700)),
                ]),
                style: t.textTheme.titleSmall),
          ),
        ]),
        const SizedBox(height: 8),
        if (_loading)
          const LinearProgressIndicator()
        // ---- answered: show it, change only on purpose ----
        else if (!_editing)
          Row(children: [
            Icon(Icons.check_circle, size: 18, color: Colors.green.shade700),
            const SizedBox(width: 6),
            Expanded(child: Text(answer, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
            if (_closed)
              Text('Closed ${fmtDate(widget.deadline)}', style: t.textTheme.labelSmall)
            else
              TextButton.icon(
                onPressed: () => setState(() {
                  _editing = true;
                  _choice = _saved;
                  _other.text = _savedOther;
                }),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Change'),
              ),
          ])
        // ---- choosing ----
        else ...[
          Text(
            missing
                ? 'Food is served – choose one. You can change it until ${fmtDate(widget.deadline)}.'
                : 'Choose one. You can change it until ${fmtDate(widget.deadline)}.',
            style: t.textTheme.bodySmall?.copyWith(color: missing ? Colors.orange.shade900 : null),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final e in foodLabels.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: _choice == e.key,
                onSelected: (_closed && _saved != null) ? null : (on) => setState(() => _choice = on ? e.key : null),
              ),
          ]),
          if (_choice == 'other') ...[
            const SizedBox(height: 10),
            TextField(
              controller: _other,
              maxLength: 200,
              decoration: const InputDecoration(
                  labelText: 'Other – what should we know?', hintText: 'e.g. nut allergy, halal', counterText: ''),
            ),
          ],
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (_saved != null)
              TextButton(onPressed: () => setState(() => _editing = false), child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving || _choice == null ? null : _save,
              child: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Save'),
            ),
          ]),
        ],
      ]),
    );
  }
}
