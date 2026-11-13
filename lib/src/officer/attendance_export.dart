import 'package:excel/excel.dart';

import '../data/models.dart';
import '../data/repo.dart';
import 'save_file_io.dart' if (dart.library.js_interop) 'save_file_web.dart';

const attendanceSv = {'offline': 'På plats', 'online': 'Online', 'absent': 'Kan inte', null: 'Inget svar'};

/// Attendance workbook: "Översikt" (counts per meeting) and "Namn" (one row per representative and meeting).
/// Covers the meetings of the current semester (or all meetings if no semester is set).
Future<String?> exportAttendanceXlsx({Semester? semester, required List<Council> councils}) async {
  var meetings = await Repo.meetings();
  if (semester != null) {
    final from = semester.startsOn, to = semester.endsOn.add(const Duration(days: 1));
    meetings = meetings.where((m) => !m.startsAt.isBefore(from) && m.startsAt.isBefore(to)).toList();
  }
  meetings.sort((a, b) => a.startsAt.compareTo(b.startsAt));
  final answers = await Repo.attendance();
  final people = {for (final p in await Repo.profiles()) p.id: p};
  final councilNames = {for (final c in councils) c.id: c.name};
  final membersByCouncil = <String, Set<String>>{};
  for (final cid in meetings.map((m) => m.councilId).toSet()) {
    membersByCouncil[cid] = await Repo.councilMemberIds(cid);
  }

  final excel = Excel.createExcel();
  final defaultSheet = excel.getDefaultSheet();
  final sum = excel['Översikt'];
  final det = excel['Namn'];

  _row(sum, 0, ['Närvaro – studentrepresentanter${semester == null ? '' : ' (${semester.name})'}'], bold: true);
  _row(sum, 2, ['Möte', 'Nämnd/Organ', 'Datum', 'Tid', 'På plats', 'Online', 'Kan inte', 'Inget svar', 'Totalt'],
      bold: true);
  _row(det, 0, ['Möte', 'Nämnd/Organ', 'Datum', 'Namn', 'E-post', 'Program', 'Närvaro'], bold: true);

  var r = 3, d = 1;
  final totals = [0, 0, 0, 0];
  for (final m in meetings) {
    final mine = {for (final a in answers.where((a) => a.meetingId == m.id)) a.userId: a.mode};
    final ids = {...?membersByCouncil[m.councilId], ...mine.keys}.toList()
      ..sort((a, b) => (people[a]?.fullName ?? '').compareTo(people[b]?.fullName ?? ''));
    final counts = [
      mine.values.where((v) => v == 'offline').length,
      mine.values.where((v) => v == 'online').length,
      mine.values.where((v) => v == 'absent').length,
      ids.where((id) => !mine.containsKey(id)).length,
    ];
    for (var i = 0; i < 4; i++) {
      totals[i] += counts[i];
    }
    final date = _d(m.startsAt);
    _row(sum, r++, [m.title, councilNames[m.councilId] ?? '', date, _t(m.startsAt), ...counts, ids.length]);
    for (final id in ids) {
      final p = people[id];
      _row(det, d++, [m.title, councilNames[m.councilId] ?? '', date, p?.fullName ?? '', p?.email ?? '',
        p?.program ?? '', attendanceSv[mine[id]]!]);
    }
  }
  _row(sum, r + 1, ['TOTALT', '', '', '', ...totals, totals.reduce((a, b) => a + b)], bold: true);

  for (final (col, w) in const [(0, 30.0), (1, 34.0), (2, 12.0), (3, 8.0), (4, 10.0), (5, 10.0), (6, 10.0),
    (7, 11.0), (8, 8.0)]) {
    sum.setColumnWidth(col, w);
  }
  for (final (col, w) in const [(0, 30.0), (1, 34.0), (2, 12.0), (3, 26.0), (4, 30.0), (5, 24.0), (6, 12.0)]) {
    det.setColumnWidth(col, w);
  }
  excel.setDefaultSheet('Översikt');
  if (defaultSheet != null && defaultSheet != 'Översikt' && defaultSheet != 'Namn') excel.delete(defaultSheet);

  final bytes = excel.encode();
  if (bytes == null) throw Exception('Could not create the Excel file');
  final name = semester == null ? 'alla' : semester.name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
  return saveBytes('MDSU_narvaro_$name.xlsx', bytes, extension: 'xlsx', title: 'Save attendance');
}

void _row(Sheet s, int row, List<Object> values, {bool bold = false}) {
  for (var i = 0; i < values.length; i++) {
    final c = s.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: row));
    final v = values[i];
    c.value = v is int ? IntCellValue(v) : TextCellValue('$v');
    if (bold) c.cellStyle = CellStyle(bold: true);
  }
}

String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _t(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
