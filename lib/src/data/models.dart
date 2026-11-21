// Plain data classes mapped from Supabase rows.

DateTime _dt(dynamic v) => DateTime.parse(v as String).toLocal();
DateTime? _dtn(dynamic v) => v == null ? null : DateTime.parse(v as String).toLocal();
int _int(dynamic v) => v == null ? 0 : (v as num).toInt();

class Profile {
  final String id;
  final String fullName;
  final String? email;
  final String role;
  final String? program;
  final String? academy;
  final int? studyYear;
  final bool isMember;
  final bool quizPassed;
  final bool shareContact;
  final bool active;

  Profile.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        fullName = (m['full_name'] ?? '') as String,
        email = m['email'] as String?,
        role = (m['role'] ?? 'rep') as String,
        program = m['program'] as String?,
        academy = m['academy'] as String?,
        studyYear = m['study_year'] == null ? null : _int(m['study_year']),
        isMember = (m['is_member'] ?? false) as bool,
        quizPassed = (m['quiz_passed'] ?? false) as bool,
        shareContact = (m['share_contact'] ?? false) as bool,
        active = (m['active'] ?? true) as bool;

  bool get isOfficer => role == 'officer' || role == 'admin';
  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p[0].toUpperCase()).join();
  }
}

class Semester {
  final String id;
  final String name;
  final DateTime startsOn;
  final DateTime endsOn;
  final DateTime reportDeadline;
  final DateTime? reminderDate;
  final int hourlyRate;
  final int halfHourRate;
  final int escalateAfter;
  final int agendaCallDays;
  final int agendaDeadlineDays;

  Semester.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        name = m['name'] as String,
        startsOn = DateTime.parse(m['starts_on'] as String),
        endsOn = DateTime.parse(m['ends_on'] as String),
        reportDeadline = DateTime.parse(m['report_deadline'] as String),
        reminderDate = m['reminder_date'] == null ? null : DateTime.parse(m['reminder_date'] as String),
        hourlyRate = _int(m['hourly_rate']),
        halfHourRate = _int(m['half_hour_rate']),
        escalateAfter = _int(m['escalate_after']),
        agendaCallDays = _int(m['agenda_call_days']),
        agendaDeadlineDays = _int(m['agenda_deadline_days']);
}

class Council {
  final String id;
  final String name;
  final String type;
  final String? academy;
  Council.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        name = m['name'] as String,
        type = m['type'] as String,
        academy = m['academy'] as String?;
  bool get isSiec => type == 'siec';
}

/// Councils with how many reps and meetings each has (officer Councils page).
class CouncilStats {
  final List<Council> councils;
  final Map<String, int> members;
  final Map<String, int> meetings;
  CouncilStats(this.councils, this.members, this.meetings);
}

class Meeting {
  final String id;
  final String councilId;
  final String title;
  final DateTime startsAt;
  final String? location;
  final bool inputRequested;
  final DateTime? _inputDeadline;
  Meeting.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        councilId = m['council_id'] as String,
        title = m['title'] as String,
        startsAt = _dt(m['starts_at']),
        location = m['location'] as String?,
        inputRequested = (m['input_requested'] ?? false) as bool,
        _inputDeadline = m['input_deadline'] == null ? null : DateTime.parse(m['input_deadline'] as String);
  bool get isPast => startsAt.isBefore(DateTime.now());
  /// Last day reps can send agenda items (set by the database, default 2 days before).
  DateTime get inputDeadline => _inputDeadline ?? startsAt.subtract(const Duration(days: 2));
}

/// A post from the Head of Education. With [meetingId] it is that meeting's final agenda.
class Post {
  final String id;
  final String? authorId;
  final String title;
  final String body;
  final String? councilId; // null = all representatives
  final String? meetingId;
  final String? filePath;
  final String? fileName;
  final DateTime createdAt;
  Post.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        authorId = m['author_id'] as String?,
        title = (m['title'] ?? '') as String,
        body = (m['body'] ?? '') as String,
        councilId = m['council_id'] as String?,
        meetingId = m['meeting_id'] as String?,
        filePath = m['file_path'] as String?,
        fileName = m['file_name'] as String?,
        createdAt = _dt(m['created_at']);
  bool get isFinalAgenda => meetingId != null;
}

/// How a representative attends a meeting.
class Attendance {
  final String meetingId;
  final String userId;
  final String mode; // offline | online | absent
  Attendance.fromMap(Map<String, dynamic> m)
      : meetingId = m['meeting_id'] as String,
        userId = m['user_id'] as String,
        mode = m['mode'] as String;
}

const attendanceLabels = {'offline': 'In the room', 'online': 'Online (Teams)', 'absent': 'Can\'t attend'};

class TimeEntry {
  final String id;
  final String userId;
  final DateTime workDate;
  final String activity;
  final String? councilId;
  final String? meetingId;
  final int minutes;
  final String description;
  final String? startTime; // 'HH:MM:SS'
  TimeEntry.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        userId = m['user_id'] as String,
        workDate = DateTime.parse(m['work_date'] as String),
        activity = m['activity'] as String,
        councilId = m['council_id'] as String?,
        meetingId = m['meeting_id'] as String?,
        minutes = _int(m['minutes']),
        description = (m['description'] ?? '') as String,
        startTime = m['start_time'] as String?;

  /// Started half hours for this activity (rounded up, like the Excel time report)
  int get halfHours => (minutes + 29) ~/ 30;

  /// 'HH:MM' start and end, or null when no start time was given
  String? get fromText => startTime == null ? null : startTime!.substring(0, 5);
  String? get toText {
    if (startTime == null) return null;
    final p = startTime!.split(':');
    final total = int.parse(p[0]) * 60 + int.parse(p[1]) + minutes;
    return '${((total ~/ 60) % 24).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
  }
}

class Attachment {
  final String id;
  final String entryId;
  final String storagePath;
  final String fileName;
  Attachment.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        entryId = m['entry_id'] as String,
        storagePath = m['storage_path'] as String,
        fileName = m['file_name'] as String;
}

/// One row of the `report_overview` view.
class ReportRow {
  final String userId;
  final String fullName;
  final String? program;
  final String? academy;
  final bool isMember;
  final String status;
  final String? reportId;
  final DateTime? submittedAt;
  final bool isLate;
  final String? reviewerComment;
  final int minutes;
  final int entries;
  final int entriesWithoutNotes;
  final int amount;
  final bool hasPersonalNumber;
  final int halfHours;

  ReportRow.fromMap(Map<String, dynamic> m)
      : userId = m['user_id'] as String,
        fullName = (m['full_name'] ?? '') as String,
        program = m['program'] as String?,
        academy = m['academy'] as String?,
        isMember = (m['is_member'] ?? false) as bool,
        status = (m['status'] ?? 'draft') as String,
        reportId = m['report_id'] as String?,
        submittedAt = _dtn(m['submitted_at']),
        isLate = (m['is_late'] ?? false) as bool,
        reviewerComment = m['reviewer_comment'] as String?,
        minutes = _int(m['minutes']),
        entries = _int(m['entries']),
        entriesWithoutNotes = _int(m['entries_without_notes']),
        amount = _int(m['amount']),
        hasPersonalNumber = (m['has_personal_number'] ?? false) as bool,
        halfHours = _int(m['half_hours']);

  bool get isLocked => status == 'submitted' || status == 'approved' || status == 'paid';
  bool get isDone => isLocked;
}

class AgendaItem {
  final String id;
  final String meetingId;
  final String userId;
  final String title;
  final String details;
  final String source;
  final int studentCount;
  final String status;
  AgendaItem.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        meetingId = m['meeting_id'] as String,
        userId = m['user_id'] as String,
        title = m['title'] as String,
        details = (m['details'] ?? '') as String,
        source = (m['source'] ?? '') as String,
        studentCount = _int(m['student_count']),
        status = m['status'] as String;
}

class Issue {
  final String id;
  final String councilId;
  final String? raisedAtMeeting;
  final String raisedBy;
  final String title;
  final String details;
  final String? responsible;
  final String status;
  final String? response;
  final DateTime createdAt;
  Issue.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        councilId = m['council_id'] as String,
        raisedAtMeeting = m['raised_at_meeting'] as String?,
        raisedBy = m['raised_by'] as String,
        title = m['title'] as String,
        details = (m['details'] ?? '') as String,
        responsible = m['responsible'] as String?,
        status = m['status'] as String,
        response = m['response'] as String?,
        createdAt = _dt(m['created_at']);
  bool get isOpen => status == 'awaiting' || status == 'escalated';
}

/// Row from rpc open_issues_for_meeting
class OpenIssue {
  final String id;
  final String title;
  final String? responsible;
  final String status;
  final String? raisedByName;
  final int meetingsWithoutAnswer;
  OpenIssue.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        title = m['title'] as String,
        responsible = m['responsible'] as String?,
        status = m['status'] as String,
        raisedByName = m['raised_by_name'] as String?,
        meetingsWithoutAnswer = _int(m['meetings_without_answer']);
}

class Channel {
  final String id;
  final String name;
  final String description;
  final String audience;
  final bool officerOnly;
  final int sortOrder;
  Channel.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        name = m['name'] as String,
        description = (m['description'] ?? '') as String,
        audience = m['audience'] as String,
        officerOnly = (m['officer_only'] ?? false) as bool,
        sortOrder = _int(m['sort_order']);
}

class Message {
  final String id;
  final String channelId;
  final String authorId;
  final String body;
  final bool isAnnouncement;
  final DateTime createdAt;
  final String? filePath;
  final String? fileName;
  final String? parentId; // set = a comment under a post
  Message.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        channelId = m['channel_id'] as String,
        authorId = m['author_id'] as String,
        body = m['body'] as String,
        isAnnouncement = (m['is_announcement'] ?? false) as bool,
        createdAt = _dt(m['created_at']),
        filePath = m['file_path'] as String?,
        fileName = m['file_name'] as String?,
        parentId = m['parent_id'] as String?;
}

class TutoringPost {
  final String id;
  final String kind;
  final String course;
  final String body;
  final String authorId;
  final bool hidden;
  final DateTime createdAt;
  TutoringPost.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        kind = m['kind'] as String,
        course = m['course'] as String,
        body = (m['body'] ?? '') as String,
        authorId = m['author_id'] as String,
        hidden = (m['hidden'] ?? false) as bool,
        createdAt = _dt(m['created_at']);
}

class AppNotification {
  final String id;
  final String title;
  final String body;
  final String? link;
  final DateTime createdAt;
  final DateTime? readAt;
  AppNotification.fromMap(Map<String, dynamic> m)
      : id = m['id'] as String,
        title = m['title'] as String,
        body = (m['body'] ?? '') as String,
        link = m['link'] as String?,
        createdAt = _dt(m['created_at']),
        readAt = _dtn(m['read_at']);
}
