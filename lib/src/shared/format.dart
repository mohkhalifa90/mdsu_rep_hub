import 'package:intl/intl.dart';

/// Same rule as the database function pay_amount():
/// 130 SEK/hour = 65 SEK per *started* half hour, only for union members.
int payAmount(int minutes, {required bool member, int halfHourRate = 65}) {
  if (!member || minutes <= 0) return 0;
  return ((minutes + 29) ~/ 30) * halfHourRate;
}

/// Semester pay like the official Excel time report: every activity is rounded up to
/// started half hours on its own, then the rows are added up.
int payForActivities(Iterable<int> minutesPerActivity, {required bool member, int halfHourRate = 65}) {
  if (!member) return 0;
  return minutesPerActivity.fold<int>(0, (sum, m) => sum + (m <= 0 ? 0 : (m + 29) ~/ 30)) * halfHourRate;
}

const swedishWeekdays = ['Måndag', 'Tisdag', 'Onsdag', 'Torsdag', 'Fredag', 'Lördag', 'Söndag'];

const activityLabels = <String, String>{
  'council_meeting': 'Council meeting with the university',
  'siec_meeting': 'SIEC meeting',
  'preparation': 'Preparation (reading documents, agenda)',
  'student_input': 'Gathering student input / student errands',
  'class_visit': 'Class visit',
  'teams_email': 'Teams & email (education related)',
  'materials': 'Preparing material (presentations, surveys, guides)',
  'task': 'Task from MDSU / Head of Education',
  'other': 'Other education-related work (describe it)',
};

const agendaSources = [
  'Talking to students',
  'Class group chat',
  'Survey',
  'Class visit',
  'Focus group',
  'Course evaluation',
];

const reportStatusLabels = {
  'draft': 'Draft',
  'submitted': 'Submitted',
  'returned': 'Returned',
  'approved': 'Approved',
  'paid': 'Paid',
};

const issueStatusLabels = {
  'awaiting': 'Awaiting response',
  'answered': 'Answered',
  'escalated': 'Escalated',
  'closed': 'Closed',
};

String fmtMinutes(int m) {
  final h = m ~/ 60, mm = m % 60;
  if (h == 0) return '${mm}m';
  return mm == 0 ? '${h}h' : '${h}h ${mm}m';
}

String fmtHours(int minutes) => (minutes / 60).toStringAsFixed(minutes % 60 == 0 ? 0 : 1);

final _sek = NumberFormat.decimalPattern('sv');
String sek(int amount) => '${_sek.format(amount)} SEK';

String fmtDate(DateTime d) => DateFormat('d MMM').format(d);
String fmtDateY(DateTime d) => DateFormat('d MMM y').format(d);
String fmtDateTime(DateTime d) => DateFormat('d MMM, HH:mm').format(d);

int daysUntil(DateTime d) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return DateTime(d.year, d.month, d.day).difference(today).inDays;
}
