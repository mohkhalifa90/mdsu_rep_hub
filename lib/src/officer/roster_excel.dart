import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../data/roster.dart';
import '../shared/widgets.dart';
import 'save_file_io.dart' if (dart.library.js_interop) 'save_file_web.dart';

// One sheet "Roster", one row per representative (a council without reps gets one row with no email).
// The same layout is read back by the import, so Dania can download, edit in Excel and upload again.
const _cols = [
  'Council', 'Type', 'City', 'Teaching', 'New students', 'Length (years)', 'Seats', 'Director',
  'Director email', 'Institution', 'Cancelled', 'Cohort', 'Rep email', 'Rep name', 'Note',
];
const _typeOut = {'program': 'Programme', 'general': 'Central council', 'academy': 'Academy council', 'siec': 'SIEC'};

String _numText(double? v) => v == null ? '' : (v == v.roundToDouble() ? '${v.toInt()}' : '$v');

Future<String?> exportRosterXlsx(List<Council> councils, List<RosterEntry> roster, Map<String, Profile> byEmail) async {
  final excel = Excel.createExcel();
  final first = excel.getDefaultSheet();
  final sheet = excel['Roster'];
  for (var i = 0; i < _cols.length; i++) {
    final c = sheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
    c.value = TextCellValue(_cols[i]);
    c.cellStyle = CellStyle(bold: true);
  }
  var row = 1;
  final list = councils.where((c) => !c.isSiec).toList()
    ..sort((a, b) => a.type == b.type ? a.name.compareTo(b.name) : a.type.compareTo(b.type));
  for (final c in list) {
    final reps = roster.where((r) => r.councilId == c.id).toList()
      ..sort((a, b) => (Cohort.parse(b.cohort)?.start ?? DateTime(0)).compareTo(Cohort.parse(a.cohort)?.start ?? DateTime(0)));
    final base = [
      c.name,
      _typeOut[c.type] ?? c.type,
      c.city ?? '',
      c.studyMode == null ? '' : (modeLabels[c.studyMode] ?? c.studyMode!),
      c.intake == null ? '' : (c.intake == 'HT_VT' ? 'HT & VT' : c.intake!),
      _numText(c.lengthYears),
      c.seats?.toString() ?? '',
      c.directorName ?? '',
      c.directorEmail ?? '',
      c.institution ?? '',
      c.cancelled ? 'yes' : '',
    ];
    for (final r in reps.isEmpty ? <RosterEntry?>[null] : reps) {
      final values = [
        ...base,
        r?.cohort ?? '',
        r?.email ?? '',
        r == null ? '' : (byEmail[r.email]?.fullName ?? ''),
        r?.note ?? '',
      ];
      for (var i = 0; i < values.length; i++) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: row)).value = TextCellValue(values[i]);
      }
      row++;
    }
  }
  for (final (col, w) in const [(0, 50.0), (1, 16.0), (2, 7.0), (3, 10.0), (4, 12.0), (5, 9.0), (6, 7.0), (7, 24.0),
    (8, 28.0), (9, 12.0), (10, 9.0), (11, 9.0), (12, 30.0), (13, 24.0), (14, 30.0)]) {
    sheet.setColumnWidth(col, w);
  }
  excel.setDefaultSheet('Roster');
  if (first != null && first != 'Roster') excel.delete(first);
  final bytes = excel.encode();
  if (bytes == null) throw Exception('Could not create the Excel file');
  return saveBytes('MDSU_programmes_and_reps.xlsx', bytes, extension: 'xlsx', title: 'Save programmes and reps');
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

/// Same text with small differences removed: case, extra spaces, kinds of dash.
String normName(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[‐-―−]'), '-')
    .replaceAll(RegExp(r'\s*-\s*'), ' - ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

int _distance(String a, String b) {
  if ((a.length - b.length).abs() > 3) return 99;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return prev[b.length];
}

String _cell(Data? d) {
  final v = d?.value;
  if (v == null) return '';
  if (v is TextCellValue) return v.toString().trim(); // includes rich-text parts
  if (v is IntCellValue) return '${v.value}';
  if (v is DoubleCellValue) return _numText(v.value);
  if (v is BoolCellValue) return v.value ? 'yes' : '';
  return v.toString().trim();
}

class _FileCouncil {
  final String name;
  final Map<String, dynamic> values;
  final int row;
  Council? existing; // matched exactly
  Council? similar; // a near match – ask
  bool sameAsSimilar = true;
  bool apply = true;
  _FileCouncil(this.name, this.values, this.row);
}

class _FileRep {
  final _FileCouncil council;
  final String email;
  final String? cohort;
  final String? note;
  bool apply = true;
  _FileRep(this.council, this.email, this.cohort, this.note);
}

class _Change<T> {
  final T item;
  final String what;
  bool apply;
  _Change(this.item, this.what, {this.apply = true});
}

class _Plan {
  final newCouncils = <_FileCouncil>[];
  final councilChanges = <_Change<_FileCouncil>>[];
  final newReps = <_FileRep>[];
  final repChanges = <_Change<(RosterEntry, _FileRep)>>[];
  final missing = <_Change<RosterEntry>>[];
  final problems = <String>[];
  int unchanged = 0;
}

Map<String, dynamic> _parseCouncil(Map<String, String> r, List<String> problems, int row) {
  String? t(String k) => (r[k] ?? '').isEmpty ? null : r[k];
  final type = switch ((r['type'] ?? '').toLowerCase()) {
    'central council' || 'central' || 'centralt råd' => 'general',
    'academy council' || 'academy' => 'academy',
    'siec' => 'siec',
    _ => 'program',
  };
  final city = switch ((r['city'] ?? '').toUpperCase()) {
    'ESK' || 'ESKILSTUNA' => 'ESK',
    'VÄS' || 'VAS' || 'VÄSTERÅS' || 'VASTERAS' => 'VÄS',
    '' => null,
    final x => () {
        problems.add('Row $row: unknown city "$x" (use ESK or VÄS)');
        return null;
      }(),
  };
  final mode = switch ((r['teaching'] ?? '').toLowerCase()) {
    'campus' || 'plats' => 'campus',
    'distance' || 'distans' => 'distans',
    _ => null,
  };
  final ns = (r['new students'] ?? '').toUpperCase().replaceAll(' ', '');
  final intake = ns.contains('HT') && ns.contains('VT') ? 'HT_VT' : (ns.contains('VT') ? 'VT' : (ns.contains('HT') ? 'HT' : null));
  final len = double.tryParse((r['length (years)'] ?? '').replaceAll(',', '.'));
  final seats = int.tryParse(r['seats'] ?? '');
  return {
    'type': type,
    'city': city,
    'study_mode': type == 'program' ? mode : null,
    'intake': type == 'program' ? intake : null,
    'length_years': type == 'program' ? len : null,
    'seats': seats,
    'director_name': t('director'),
    'director_email': t('director email')?.toLowerCase(),
    'institution': t('institution'),
    'cancelled': ['yes', 'ja', 'x', 'true', '1'].contains((r['cancelled'] ?? '').toLowerCase()),
  };
}

dynamic _current(Council c, String key) => switch (key) {
      'type' => c.type,
      'city' => c.city,
      'study_mode' => c.studyMode,
      'intake' => c.intake,
      'length_years' => c.lengthYears,
      'seats' => c.seats,
      'director_name' => c.directorName,
      'director_email' => c.directorEmail,
      'institution' => c.institution,
      'cancelled' => c.cancelled,
      _ => null,
    };

const _fieldNames = {
  'type': 'type', 'city': 'city', 'study_mode': 'teaching', 'intake': 'new students', 'length_years': 'length',
  'seats': 'seats', 'director_name': 'director', 'director_email': 'director email', 'institution': 'institution',
  'cancelled': 'cancelled',
};

/// Pick an Excel file, show what would change, and apply what the Head of Education ticks.
/// Returns true if anything was saved.
Future<bool> importRosterXlsx(BuildContext context) async {
  final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx'], withData: true);
  final bytes = picked?.files.single.bytes;
  if (bytes == null || !context.mounted) return false;

  final _Plan plan;
  try {
    final excel = Excel.decodeBytes(bytes);
    final sheet = excel.tables['Roster'] ?? excel.tables.values.first;
    // find the header row
    var headerRow = -1;
    final idx = <String, int>{};
    for (var r = 0; r < sheet.maxRows && r < 10 && headerRow < 0; r++) {
      final row = sheet.row(r);
      final names = [for (final c in row) _cell(c).toLowerCase()];
      if (names.contains('council') && names.contains('rep email')) {
        headerRow = r;
        for (var i = 0; i < names.length; i++) {
          if (names[i].isNotEmpty) idx[names[i]] = i;
        }
      }
    }
    if (headerRow < 0) {
      throw Exception('This is not the right file. Use "Download Excel" first – the file needs the columns '
          '"Council" and "Rep email".');
    }
    final councils = await Repo.councils();
    final roster = await Repo.roster();
    plan = _buildPlan(sheet, headerRow, idx, councils, roster);
  } catch (e) {
    if (context.mounted) showSnack(context, errorText(e));
    return false;
  }
  if (!context.mounted) return false;
  final go = await Navigator.push<bool>(
      context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _PreviewPage(plan: plan)));
  if (go != true || !context.mounted) return false;
  return runAction(context, () => _apply(plan), success: 'Imported ✓');
}

_Plan _buildPlan(Sheet sheet, int headerRow, Map<String, int> idx, List<Council> councils, List<RosterEntry> roster) {
  final plan = _Plan();
  final byNorm = {for (final c in councils) normName(c.name): c};
  final fileCouncils = <String, _FileCouncil>{};
  final fileReps = <String, _FileRep>{}; // council|email

  for (var r = headerRow + 1; r < sheet.maxRows; r++) {
    final row = sheet.row(r);
    final m = <String, String>{for (final e in idx.entries) e.key: e.value < row.length ? _cell(row[e.value]) : ''};
    final name = (m['council'] ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty) continue;
    final excelRow = r + 1;
    final key = normName(name);
    final fc = fileCouncils.putIfAbsent(key, () {
      final f = _FileCouncil(name, _parseCouncil(m, plan.problems, excelRow), excelRow);
      f.existing = byNorm[key];
      if (f.existing == null) {
        // near match, e.g. one letter different
        Council? best;
        var bestD = 99;
        for (final c in councils) {
          final d = _distance(key, normName(c.name));
          if (d < bestD) {
            bestD = d;
            best = c;
          }
        }
        if (bestD <= 2 && key.length > 8) f.similar = best;
      }
      return f;
    });
    final email = (m['rep email'] ?? '').toLowerCase().trim();
    if (email.isEmpty) continue;
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      plan.problems.add('Row $excelRow: "$email" is not an email address – skipped');
      continue;
    }
    final cohortText = (m['cohort'] ?? '').toUpperCase().replaceAll(' ', '');
    final cohort = Cohort.parse(cohortText)?.code;
    if (cohortText.isNotEmpty && cohort == null) {
      plan.problems.add('Row $excelRow: cohort "${m['cohort']}" not understood (write e.g. HT2025 or VT2026) – left empty');
    }
    final note = (m['note'] ?? '').trim();
    final k = '$key|$email';
    if (fileReps.containsKey(k)) {
      plan.problems.add('Row $excelRow: $email is twice in "$name" – the first row is used');
      continue;
    }
    fileReps[k] = _FileRep(fc, email, cohort, note.isEmpty ? null : note);
  }

  // councils
  for (final f in fileCouncils.values) {
    final target = f.existing ?? f.similar;
    if (target == null) {
      plan.newCouncils.add(f);
      continue;
    }
    if (f.existing == null) plan.newCouncils.add(f); // asks "same as …?"
    final diffs = <String>[];
    for (final e in f.values.entries) {
      final now = _current(target, e.key);
      final v = e.value;
      final same = (now == null && v == null) || (now is num && v is num ? now.toDouble() == v.toDouble() : now == v);
      if (!same) diffs.add('${_fieldNames[e.key]}: ${now ?? '—'} → ${v ?? '—'}');
    }
    if (diffs.isNotEmpty) plan.councilChanges.add(_Change(f, diffs.join(' · ')));
  }

  // reps
  final rosterBy = <String, RosterEntry>{for (final r in roster) '${r.councilId}|${r.email}': r};
  final seen = <String>{};
  for (final fr in fileReps.values) {
    final target = fr.council.existing ?? fr.council.similar;
    final existing = target == null ? null : rosterBy['${target.id}|${fr.email}'];
    if (existing == null) {
      plan.newReps.add(fr);
    } else {
      seen.add(existing.id);
      final diffs = [
        if (existing.cohort != fr.cohort) 'cohort ${existing.cohort ?? '—'} → ${fr.cohort ?? '—'}',
        if ((existing.note ?? '') != (fr.note ?? '')) 'note',
      ];
      if (diffs.isEmpty) {
        plan.unchanged++;
      } else {
        plan.repChanges.add(_Change((existing, fr), diffs.join(' · ')));
      }
    }
  }
  // on the app's roster for a council in the file, but not in the file
  final inFile = {
    for (final f in fileCouncils.values)
      if ((f.existing ?? f.similar) != null) (f.existing ?? f.similar)!.id
  };
  for (final r in roster) {
    if (inFile.contains(r.councilId) && !seen.contains(r.id)) {
      plan.missing.add(_Change(r, 'not in the file', apply: false));
    }
  }
  return plan;
}

Future<void> _apply(_Plan plan) async {
  final ids = <_FileCouncil, String>{};
  for (final f in plan.newCouncils) {
    if (f.similar != null && f.sameAsSimilar) {
      ids[f] = f.similar!.id;
    } else if (f.apply) {
      ids[f] = await Repo.saveCouncil(null, {'name': f.name, ...f.values});
    }
  }
  for (final ch in plan.councilChanges) {
    final f = ch.item;
    final target = f.existing ?? (f.sameAsSimilar ? f.similar : null);
    if (target == null) continue;
    ids[f] = target.id;
    if (ch.apply) await Repo.saveCouncil(target.id, f.values);
  }
  for (final f in [...plan.newCouncils, ...plan.councilChanges.map((c) => c.item)]) {
    final t = f.existing ?? (f.sameAsSimilar ? f.similar : null);
    if (t != null) ids.putIfAbsent(f, () => t.id);
  }
  for (final r in plan.newReps) {
    final cid = ids[r.council] ?? r.council.existing?.id;
    if (!r.apply || cid == null) continue;
    await Repo.addToRoster(cid, r.email, cohort: r.cohort, note: r.note);
  }
  for (final ch in plan.repChanges) {
    if (ch.apply) await Repo.updateRoster(ch.item.$1.id, cohort: ch.item.$2.cohort, note: ch.item.$2.note);
  }
  for (final ch in plan.missing) {
    if (ch.apply) await Repo.removeFromRoster(ch.item.id);
  }
}

class _PreviewPage extends StatefulWidget {
  final _Plan plan;
  const _PreviewPage({required this.plan});
  @override
  State<_PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<_PreviewPage> {
  _Plan get p => widget.plan;

  Widget _section(String title, Color color, IconData icon, List<Widget> children) => children.isEmpty
      ? const SizedBox.shrink()
      : Card(
          child: ExpansionTile(
            initiallyExpanded: children.length <= 30,
            leading: Icon(icon, color: color),
            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            children: children,
          ),
        );

  @override
  Widget build(BuildContext context) {
    final ticked = p.newCouncils.where((f) => f.similar == null ? f.apply : !f.sameAsSimilar && f.apply).length +
        p.councilChanges.where((c) => c.apply).length +
        p.newReps.where((r) => r.apply).length +
        p.repChanges.where((c) => c.apply).length +
        p.missing.where((c) => c.apply).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Check before importing'),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: FilledButton(
              onPressed: ticked == 0 ? null : () => Navigator.pop(context, true),
              child: Text('Apply $ticked'),
            ),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Nothing is saved until you press Apply. Untick what you do not want. '
            '${p.unchanged} representatives are already the same and are left as they are.'),
        const SizedBox(height: 12),
        _section('🟢 New programmes / councils (${p.newCouncils.length})', Colors.green.shade700, Icons.add_circle_outline, [
          for (final f in p.newCouncils)
            f.similar == null
                ? CheckboxListTile(
                    value: f.apply,
                    onChanged: (v) => setState(() => f.apply = v ?? false),
                    title: Text(f.name),
                    subtitle: Text('Excel row ${f.row}'),
                  )
                : SwitchListTile(
                    value: f.sameAsSimilar,
                    onChanged: (v) => setState(() => f.sameAsSimilar = v),
                    title: Text('Is "${f.name}" the same as "${f.similar!.name}"?'),
                    subtitle: Text(f.sameAsSimilar
                        ? 'Yes – use the existing one (row ${f.row})'
                        : 'No – it will be created as a new one'),
                  ),
        ]),
        _section('🟡 Changed details (${p.councilChanges.length})', Colors.orange.shade800, Icons.edit_note, [
          for (final c in p.councilChanges)
            CheckboxListTile(
              value: c.apply,
              onChanged: (v) => setState(() => c.apply = v ?? false),
              title: Text((c.item.existing ?? c.item.similar)!.name),
              subtitle: Text(c.what),
            ),
        ]),
        _section('🟢 New representatives on councils (${p.newReps.length})', Colors.green.shade700, Icons.person_add_alt, [
          for (final r in p.newReps)
            CheckboxListTile(
              value: r.apply,
              onChanged: (v) => setState(() => r.apply = v ?? false),
              title: Text(r.email),
              subtitle: Text('${r.council.name}${r.cohort == null ? '' : ' · ${r.cohort}'}${r.note == null ? '' : ' · ${r.note}'}'),
            ),
        ]),
        _section('🟡 Changed cohort or note (${p.repChanges.length})', Colors.orange.shade800, Icons.sync_alt, [
          for (final c in p.repChanges)
            CheckboxListTile(
              value: c.apply,
              onChanged: (v) => setState(() => c.apply = v ?? false),
              title: Text(c.item.$1.email),
              subtitle: Text('${c.item.$2.council.name} · ${c.what}'),
            ),
        ]),
        _section('🔴 In the app but not in the file (${p.missing.length}) – tick to remove', Colors.red.shade700,
            Icons.person_remove_outlined, [
          for (final c in p.missing)
            CheckboxListTile(
              value: c.apply,
              onChanged: (v) => setState(() => c.apply = v ?? false),
              title: Text(c.item.email),
              subtitle: const Text('Kept unless you tick it'),
            ),
        ]),
        _section('⚠️ Rows with a problem (${p.problems.length})', Colors.red.shade700, Icons.warning_amber, [
          for (final s in p.problems) ListTile(dense: true, title: Text(s)),
        ]),
      ]),
    );
  }
}
