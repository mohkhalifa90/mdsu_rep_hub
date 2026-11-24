import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import 'widgets.dart';

/// "Special food preference (allergies)" – shown when a rep attends a meeting in the room.
/// Loads and saves itself. The rep's last choice is filled in by the database.
class FoodPicker extends StatefulWidget {
  final String meetingId;
  final bool locked; // meeting has started
  const FoodPicker({super.key, required this.meetingId, this.locked = false});
  @override
  State<FoodPicker> createState() => _FoodPickerState();
}

class _FoodPickerState extends State<FoodPicker> {
  Set<String> _food = {};
  final _other = TextEditingController();
  String _savedOther = '';
  bool _loading = true, _saving = false;

  @override
  void initState() {
    super.initState();
    Repo.myFood(widget.meetingId).then((v) {
      if (!mounted) return;
      setState(() {
        _food = v.$1.toSet();
        _other.text = v.$2 ?? '';
        _savedOther = _other.text;
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

  Future<void> _save(Set<String> next) async {
    final before = _food;
    setState(() => _food = next);
    // "Other" waits for its text before saving
    if (next.isEmpty || (next.contains('other') && _other.text.trim().isEmpty)) return;
    setState(() => _saving = true);
    final ok = await runAction(
        context, () => Repo.setFood(widget.meetingId, next.toList(), next.contains('other') ? _other.text.trim() : null),
        success: 'Food preference saved');
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!ok) _food = before;
      if (ok) _savedOther = _other.text.trim();
    });
  }

  void _toggle(String key, bool on) {
    var next = {..._food};
    if (key == 'none') {
      next = on ? {'none'} : {};
    } else {
      next.remove('none');
      on ? next.add(key) : next.remove(key);
    }
    _save(next);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final missing = !_loading && _food.isEmpty;
    final otherUnsaved = _food.contains('other') && _other.text.trim() != _savedOther;
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
            child: Text.rich(TextSpan(children: [
              const TextSpan(text: 'Special food preference (allergies)'),
              TextSpan(text: ' *', style: TextStyle(color: Colors.red.shade700)),
            ]), style: t.textTheme.titleSmall),
          ),
          if (_saving) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        if (missing)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Food is served – choose one (or None)',
                style: t.textTheme.bodySmall?.copyWith(color: Colors.orange.shade900)),
          ),
        const SizedBox(height: 8),
        if (_loading)
          const LinearProgressIndicator()
        else
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final e in foodLabels.entries)
              FilterChip(
                label: Text(e.value),
                selected: _food.contains(e.key),
                onSelected: widget.locked ? null : (on) => _toggle(e.key, on),
              ),
          ]),
        if (_food.contains('other')) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _other,
                enabled: !widget.locked,
                maxLength: 200,
                decoration: const InputDecoration(
                    labelText: 'Other – what should we know?', hintText: 'e.g. nut allergy, halal', counterText: ''),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(_food),
              ),
            ),
            if (otherUnsaved) ...[
              const SizedBox(width: 8),
              FilledButton(onPressed: () => _save(_food), child: const Text('Save')),
            ],
          ]),
        ],
      ]),
    );
  }
}
