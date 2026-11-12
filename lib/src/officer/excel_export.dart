import 'package:excel/excel.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/format.dart';
import 'save_file_io.dart' if (dart.library.js_interop) 'save_file_web.dart';

/// Payroll workbook for the current semester, in MDSU's own format:
///   Sheet "Sammanställning" – one row per representative + total
///   One sheet per representative laid out like "Timrapport för studentrepresentanter"
/// Only representatives who have submitted (submitted / approved / paid) are included.
/// Returns where it was saved, or null if the user cancelled.
Future<String?> exportPayrollXlsx({required Semester semester, required List<Council> councils}) async {
  final payroll = await Repo.payroll();
  final entries = await Repo.allEntries(semester.id);
  final councilNames = {for (final c in councils) c.id: c.name};
  final term = _termCode(semester);

  final excel = Excel.createExcel();
  final defaultSheet = excel.getDefaultSheet();

  // ---------------- Sammanställning ----------------
  final sum = excel['Sammanställning'];
  _text(sum, 'A1', 'Sammanställning – timrapporter studentrepresentanter', bold: true, size: 16);
  _text(sum, 'A3', 'Termin/år', bold: true);
  _text(sum, 'B3', term);
  const headers = [
    'Namn', 'Personnummer', 'Bostadsadress', 'E-postadress', 'Program', 'Medlem i MDSU', 'Status', 'Timmar',
    'Antal påbörjade halvtimmar', 'Belopp (kr)'
  ];
  for (var i = 0; i < headers.length; i++) {
    _cell(sum, i, 4).value = TextCellValue(headers[i]);
    _cell(sum, i, 4).cellStyle = CellStyle(bold: true);
  }
  var row = 5, totalHalves = 0, totalAmount = 0;
  for (final r in payroll) {
    final halves = (r['started_half_hours'] as num?)?.toInt() ?? 0;
    final amount = (r['amount'] as num?)?.toInt() ?? 0;
    totalHalves += halves;
    totalAmount += amount;
    final values = <CellValue?>[
      TextCellValue('${r['full_name'] ?? ''}'),
      TextCellValue('${r['personal_number'] ?? 'SAKNAS'}'),
      TextCellValue('${r['address'] ?? ''}'),
      TextCellValue('${r['email'] ?? ''}'),
      TextCellValue('${r['program'] ?? ''}'),
      TextCellValue(r['is_member'] == true ? 'Ja' : 'Nej'),
      TextCellValue(_statusSv('${r['status']}')),
      DoubleCellValue(((r['hours'] as num?) ?? 0).toDouble()),
      IntCellValue(halves),
      IntCellValue(amount),
    ];
    for (var i = 0; i < values.length; i++) {
      _cell(sum, i, row).value = values[i];
    }
    row++;
  }
  _cell(sum, 0, row + 1).value = TextCellValue('TOTALT');
  _cell(sum, 0, row + 1).cellStyle = CellStyle(bold: true);
  _cell(sum, 8, row + 1).value = IntCellValue(totalHalves);
  _cell(sum, 9, row + 1).value = IntCellValue(totalAmount);
  _cell(sum, 9, row + 1).cellStyle = CellStyle(bold: true);
  _cell(sum, 0, row + 3).value = TextCellValue('${semester.hourlyRate} kr/timme = ${semester.halfHourRate} kr per '
      'påbörjad halvtimme. Varje aktivitet avrundas uppåt till påbörjade halvtimmar. Endast medlemmar i MDSU.');
  for (final (col, w) in const [(0, 26.0), (1, 16.0), (2, 30.0), (3, 30.0), (4, 24.0), (5, 14.0), (6, 12.0),
    (7, 9.0), (8, 26.0), (9, 12.0)]) {
    sum.setColumnWidth(col, w);
  }

  // ---------------- One time report per representative ----------------
  final used = <String>{'Sammanställning'};
  for (final r in payroll) {
    final userId = '${r['user_id']}';
    final mine = entries.where((e) => e.userId == userId).toList()
      ..sort((a, b) {
        final d = a.workDate.compareTo(b.workDate);
        return d != 0 ? d : (a.startTime ?? '').compareTo(b.startTime ?? '');
      });
    final s = excel[_sheetName('${r['full_name'] ?? 'Representant'}', used)];

    _text(s, 'A1', 'Timrapport för studentrepresentanter', bold: true, size: 16);
    _text(s, 'A3', 'Termin/år', bold: true);
    _text(s, 'B3', term);
    s.merge(CellIndex.indexByString('D5'), CellIndex.indexByString('E5'));
    _text(s, 'D5', 'Arbetstid', center: true);
    const cols = ['Veckodag', 'Datum', 'Nämnd/Organ', 'Fr.o.m.', 'T.o.m.', 'Delsumma', '', 'Summa / 30',
      'Antal påbörjade halvtimmar'];
    for (var i = 0; i < cols.length; i++) {
      if (cols[i].isNotEmpty) _cell(s, i, 5).value = TextCellValue(cols[i]);
    }

    var rr = 6, halves = 0;
    for (final e in mine) {
      halves += e.halfHours;
      _cell(s, 0, rr).value = TextCellValue(swedishWeekdays[e.workDate.weekday - 1]);
      _cell(s, 1, rr).value = TextCellValue(e.workDate.toIso8601String().substring(0, 10));
      _cell(s, 2, rr).value =
          TextCellValue(councilNames[e.councilId] ?? (activityLabels[e.activity] ?? e.activity));
      if (e.fromText != null) {
        _cell(s, 3, rr).value = TextCellValue(e.fromText!);
        _cell(s, 4, rr).value = TextCellValue(e.toText!);
      }
      _cell(s, 5, rr).value = TextCellValue('${e.minutes ~/ 60}:${(e.minutes % 60).toString().padLeft(2, '0')}');
      _cell(s, 7, rr).value = DoubleCellValue(double.parse((e.minutes / 30).toStringAsFixed(2)));
      _cell(s, 8, rr).value = IntCellValue(e.halfHours);
      rr++;
    }
    // at least the 31 rows of the paper template
    final sumRow = rr < 37 ? 37 : rr;
    s.merge(CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: sumRow),
        CellIndex.indexByColumnRow(columnIndex: 4, rowIndex: sumRow));
    _cell(s, 2, sumRow).value = TextCellValue('Summa antal påbörjade halvtimmar');
    _cell(s, 2, sumRow).cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Right);
    _cell(s, 5, sumRow).value = IntCellValue(halves);
    _cell(s, 5, sumRow).cellStyle = CellStyle(bold: true);
    _cell(s, 7, sumRow).value = TextCellValue('Belopp (kr)');
    _cell(s, 8, sumRow).value = IntCellValue((r['amount'] as num?)?.toInt() ?? 0);
    _cell(s, 8, sumRow).cellStyle = CellStyle(bold: true);

    final details = [
      ('För- och efternamn studentrepresentant', '${r['full_name'] ?? ''}'),
      ('Personnummer', '${r['personal_number'] ?? ''}'),
      ('Bostadsadress', '${r['address'] ?? ''}'),
      ('E-postadress (studentmejl)', '${r['email'] ?? ''}'),
      ('Medlem i Mälardalens Studentkår (fylls i av MDSU)', r['is_member'] == true ? 'Ja' : 'Nej'),
    ];
    var dr = sumRow + 1;
    for (final (label, value) in details) {
      s.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: dr),
          CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: dr));
      _cell(s, 0, dr).value = TextCellValue(label);
      _cell(s, 0, dr).cellStyle = CellStyle(fontSize: 8);
      s.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: dr + 1),
          CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: dr + 1));
      _cell(s, 0, dr + 1).value = TextCellValue(value);
      dr += 2;
    }
    for (final (col, w) in const [(0, 12.7), (1, 12.0), (2, 34.0), (3, 12.7), (4, 10.0), (5, 10.0), (6, 3.0),
      (7, 12.4), (8, 24.0)]) {
      s.setColumnWidth(col, w);
    }
  }

  excel.setDefaultSheet('Sammanställning');
  if (defaultSheet != null && !used.contains(defaultSheet)) excel.delete(defaultSheet);

  final bytes = excel.encode();
  if (bytes == null) throw Exception('Could not create the Excel file');
  return saveBytes('MDSU_timrapporter_$term.xlsx', bytes, extension: 'xlsx', title: 'Save time reports');
}

Data _cell(Sheet s, int col, int row) => s.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row));

void _text(Sheet s, String ref, String value, {bool bold = false, int? size, bool center = false}) {
  final c = s.cell(CellIndex.indexByString(ref));
  c.value = TextCellValue(value);
  if (bold || size != null || center) {
    c.cellStyle = CellStyle(
      bold: bold,
      fontSize: size,
      horizontalAlign: center ? HorizontalAlign.Center : HorizontalAlign.Left,
    );
  }
}

/// 'Autumn 2026' → 'HT26', 'Spring 2027' → 'VT27', otherwise the name itself
String _termCode(Semester s) {
  final n = s.name.toLowerCase();
  final yy = s.startsOn.year.toString().substring(2);
  if (n.contains('autumn') || n.contains('höst') || n.contains('ht')) return 'HT$yy';
  if (n.contains('spring') || n.contains('vår') || n.contains('vt')) return 'VT$yy';
  return s.name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
}

String _statusSv(String s) => switch (s) {
      'submitted' => 'Inskickad',
      'approved' => 'Godkänd',
      'paid' => 'Utbetald',
      'returned' => 'Tillbakaskickad',
      _ => 'Utkast',
    };

/// Excel sheet names: max 31 characters, no []:*?/\ and unique
String _sheetName(String name, Set<String> used) {
  var base = name.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
  if (base.isEmpty) base = 'Representant';
  if (base.length > 28) base = base.substring(0, 28);
  var n = base, i = 2;
  while (used.contains(n)) {
    n = '$base ${i++}';
  }
  used.add(n);
  return n;
}
