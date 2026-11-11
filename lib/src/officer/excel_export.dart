import 'package:excel/excel.dart';

import '../data/models.dart';
import '../data/repo.dart';
import '../shared/format.dart';
import 'save_file_io.dart' if (dart.library.js_interop) 'save_file_web.dart';

/// Builds the payroll workbook for the current semester:
///   Sheet "Payroll" – one row per rep with a submitted / approved / paid report
///   Sheet "Entries" – every logged activity, for documentation
/// Returns where it was saved, or null if the user cancelled.
Future<String?> exportPayrollXlsx({required Semester semester, required List<Council> councils}) async {
  final payroll = await Repo.payroll();
  final reports = await Repo.reportOverview();
  final names = {for (final r in reports) r.userId: r.fullName};
  final entries = await Repo.allEntries(semester.id);
  final councilNames = {for (final c in councils) c.id: c.name};

  final excel = Excel.createExcel();
  final defaultSheet = excel.getDefaultSheet();

  // ---- Payroll sheet ----
  final pay = excel['Payroll'];
  _header(pay, ['Name', 'Personal number', 'Program', 'Union member', 'Status', 'Hours', 'Started half hours',
      'Amount (SEK)']);
  var totalAmount = 0;
  for (final r in payroll) {
    final amount = (r['amount'] as num?)?.toInt() ?? 0;
    totalAmount += amount;
    pay.appendRow([
      TextCellValue('${r['full_name'] ?? ''}'),
      TextCellValue('${r['personal_number'] ?? 'MISSING'}'),
      TextCellValue('${r['program'] ?? ''}'),
      TextCellValue(r['is_member'] == true ? 'yes' : 'no'),
      TextCellValue('${r['status'] ?? ''}'),
      DoubleCellValue(((r['hours'] as num?) ?? 0).toDouble()),
      IntCellValue((r['started_half_hours'] as num?)?.toInt() ?? 0),
      IntCellValue(amount),
    ]);
  }
  pay.appendRow([]);
  pay.appendRow([
    TextCellValue('TOTAL'),
    null, null, null, null, null, null,
    IntCellValue(totalAmount),
  ]);
  pay.appendRow([
    TextCellValue('${semester.name} · ${semester.hourlyRate} SEK/h, '
        '${semester.halfHourRate} SEK per started half hour, union members only'),
  ]);

  // ---- Entries sheet ----
  final ent = excel['Entries'];
  _header(ent, ['Name', 'Date', 'Activity', 'Council', 'Minutes', 'Description']);
  for (final e in entries) {
    ent.appendRow([
      TextCellValue(names[e.userId] ?? ''),
      TextCellValue(e.workDate.toIso8601String().substring(0, 10)),
      TextCellValue(activityLabels[e.activity] ?? e.activity),
      TextCellValue(councilNames[e.councilId] ?? ''),
      IntCellValue(e.minutes),
      TextCellValue(e.description),
    ]);
  }

  excel.setDefaultSheet('Payroll');
  if (defaultSheet != null && defaultSheet != 'Payroll' && defaultSheet != 'Entries') {
    excel.delete(defaultSheet);
  }

  final bytes = excel.encode();
  if (bytes == null) throw Exception('Could not create the Excel file');
  final safeName = semester.name.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
  return saveBytes('MDSU_payroll_$safeName.xlsx', bytes);
}

void _header(Sheet sheet, List<String> titles) {
  sheet.appendRow([for (final t in titles) TextCellValue(t)]);
  for (var i = 0; i < titles.length; i++) {
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0)).cellStyle = CellStyle(bold: true);
  }
}
