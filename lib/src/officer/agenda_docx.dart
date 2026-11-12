import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../data/models.dart';
import '../data/repo.dart';
import 'save_file_io.dart' if (dart.library.js_interop) 'save_file_web.dart';

/// Creates the meeting agenda as a Word file in MDSU's SIEC layout
/// (cover page with logo, header, footer with the union's addresses, numbered headings).
/// The layout comes from assets/agenda_template.docx; only {{TITLE}}, {{DATE}} and {{BODY}} are filled in.
Future<String?> exportAgendaDocx({
  required Meeting meeting,
  required Council? council,
  required List<OpenIssue> followUps,
  required List<AgendaItem> items,
  required Map<String, String> names,
  required Meeting? nextMeeting,
}) async {
  final title = council == null
      ? meeting.title
      : (council.isSiec ? 'Student influence and education committee' : council.name);
  final date = _d(meeting.startsAt);
  final included = items.where((a) => a.status != 'declined').toList();

  final b = StringBuffer();
  b.write(_h1('Opening the meeting'));
  b.write(_p('Meeting Chairman: '));
  b.write(_p('Meeting Secretary: '));
  b.write(_p('Meeting Adjuster: '));

  b.write(_h1('Declaration of other matters'));
  if (included.isEmpty) {
    b.write(_p(''));
  } else {
    for (final a in included) {
      b.write(_li(a.title));
    }
  }

  b.write(_h1('MDSU Reports'));
  if (followUps.isEmpty) b.write(_p('–'));
  for (final i in followUps) {
    b.write(_h2('Follow-up: ${i.title}'));
    final parts = <String>[
      if (i.responsible != null && i.responsible!.isNotEmpty) 'Responsible at the university: ${i.responsible}.',
      if (i.raisedByName != null && i.raisedByName!.isNotEmpty) 'Raised by ${i.raisedByName}.',
      if (i.meetingsWithoutAnswer > 0) 'No answer after ${i.meetingsWithoutAnswer} meeting(s).',
      'A written or verbal response is requested at this meeting.',
    ];
    b.write(_p(parts.join(' ')));
  }

  b.write(_h1('Other matters'));
  if (included.isEmpty) b.write(_p('–'));
  for (final a in included) {
    final who = names[a.userId];
    b.write(_h2(who == null || who.isEmpty ? a.title : '$who – ${a.title}'));
    if (a.details.isNotEmpty) b.write(_p(a.details));
    b.write(_p('Source: ${a.source}. Raised by ${a.studentCount} student${a.studentCount == 1 ? '' : 's'}.'));
  }

  b.write(_h1('Next meeting'));
  b.write(_p(nextMeeting == null
      ? 'To be decided'
      : '${_d(nextMeeting.startsAt)}, ${_t(nextMeeting.startsAt)}${nextMeeting.location == null || nextMeeting.location!.isEmpty ? '' : '; ${nextMeeting.location}'}'));

  b.write(_h1('Closing the meeting'));
  b.write(_p('The meeting was closed __:__.'));

  // ---- fill the template ----
  final template = await rootBundle.load('assets/agenda_template.docx');
  final input = ZipDecoder().decodeBytes(template.buffer.asUint8List());
  final output = Archive();
  for (final f in input.files) {
    if (!f.isFile) continue;
    List<int> bytes = f.content as List<int>;
    if (f.name == 'word/document.xml') {
      final xml = utf8
          .decode(bytes)
          .replaceFirst('{{TITLE}}', _esc(title))
          .replaceFirst('{{DATE}}', date)
          .replaceFirst('<w:p><w:r><w:t>{{BODY}}</w:t></w:r></w:p>', b.toString());
      bytes = utf8.encode(xml);
    } else if (f.name.startsWith('word/header')) {
      bytes = utf8.encode(utf8.decode(bytes).replaceAll('{{DATE}}', date));
    }
    output.addFile(ArchiveFile(f.name, bytes.length, bytes));
  }
  // archive 3.x returns List<int>?, 4.x returns a non-null list – this works with both
  final List<int>? encoded = ZipEncoder().encode(output);
  if (encoded == null) throw Exception('Could not create the Word file');
  final safe = title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
  return saveBytes('Agenda_${safe}_$date.docx', encoded, extension: 'docx', title: 'Save agenda');
}

/// Next meeting of the same council after [m], if planned.
Future<Meeting?> nextMeetingAfter(Meeting m) async {
  final all = await Repo.meetings();
  final later = all.where((x) => x.councilId == m.councilId && x.startsAt.isAfter(m.startsAt)).toList()
    ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  return later.isEmpty ? null : later.first;
}

String _esc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

String _run(String text) => '<w:r><w:t xml:space="preserve">${_esc(text)}</w:t></w:r>';
String _h1(String text) => '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>${_run(text)}</w:p>';
String _h2(String text) => '<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr>${_run(text)}</w:p>';
String _p(String text) => '<w:p>${_run(text)}</w:p>';
String _li(String text) =>
    '<w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>${_run(text)}</w:p>';

String _d(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _t(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
