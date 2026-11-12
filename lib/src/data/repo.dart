import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../push/push_service.dart';
import 'models.dart';

/// All database access in one place. Row Level Security on the server decides
/// what each user may see, so the same calls work for reps and the officer.
class Repo {
  static SupabaseClient get sb => Supabase.instance.client;
  static String get uid => sb.auth.currentUser!.id;
  static const notesBucket = 'meeting-notes';

  static List<T> _list<T>(dynamic rows, T Function(Map<String, dynamic>) f) =>
      (rows as List).map((r) => f(Map<String, dynamic>.from(r as Map))).toList();

  // ---------- auth & profile ----------
  static Future<void> signIn({required String email, required String password}) =>
      sb.auth.signInWithPassword(email: email, password: password);

  /// Returns true when the user is signed in right away (email confirmation switched off in Supabase).
  static Future<bool> signUp({required String email, required String password, required String fullName}) async {
    final res = await sb.auth.signUp(email: email, password: password, data: {'full_name': fullName});
    return res.session != null;
  }

  // Sign-in with an emailed code (needs custom SMTP in Supabase; not used by the app right now)
  static Future<void> sendCode(String email) =>
      sb.auth.signInWithOtp(email: email.trim(), shouldCreateUser: true);

  static Future<void> verifyCode(String email, String code) =>
      sb.auth.verifyOTP(type: OtpType.email, email: email.trim(), token: code.trim());

  static Future<void> signOut() async {
    await PushService.instance.unregister();
    await sb.auth.signOut();
  }

  static Future<void> saveDeviceToken(String token, String platform) =>
      sb.rpc('register_device', params: {'p_token': token, 'p_platform': platform});

  static Future<void> deleteDeviceToken(String token) =>
      sb.from('device_tokens').delete().eq('token', token);

  static Future<Profile> me() async =>
      Profile.fromMap(await sb.from('profiles').select().eq('id', uid).single());

  static Future<void> updateMyProfile({String? fullName, bool? shareContact}) => sb.from('profiles').update({
        if (fullName != null) 'full_name': fullName,
        if (shareContact != null) 'share_contact': shareContact,
      }).eq('id', uid);

  /// Own personal number + address (null when not filled in yet)
  static Future<Map<String, dynamic>?> myPrivateDetails() =>
      sb.from('private_details').select().eq('user_id', uid).maybeSingle();

  static Future<void> savePrivateDetails({String? personalNumber, String? address}) =>
      sb.from('private_details').upsert({
        'user_id': uid,
        if (personalNumber != null) 'personal_number': personalNumber.trim().isEmpty ? null : personalNumber.trim(),
        if (address != null) 'address': address.trim().isEmpty ? null : address.trim(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });

  // ---------- reference data ----------
  static Future<Semester?> semester() async {
    final r = await sb.from('semesters').select().eq('is_current', true).maybeSingle();
    return r == null ? null : Semester.fromMap(r);
  }

  static Future<List<Council>> councils() async =>
      _list(await sb.from('councils').select().order('type').order('name'), Council.fromMap);

  static Future<CouncilStats> councilStats() async {
    final list = await councils();
    final members = <String, int>{};
    for (final r in await sb.from('council_members').select('council_id') as List) {
      final id = r['council_id'] as String;
      members[id] = (members[id] ?? 0) + 1;
    }
    final meetingCounts = <String, int>{};
    for (final r in await sb.from('meetings').select('council_id') as List) {
      final id = r['council_id'] as String;
      meetingCounts[id] = (meetingCounts[id] ?? 0) + 1;
    }
    return CouncilStats(list, members, meetingCounts);
  }

  static Future<void> createCouncil({required String name, required String type, String? academy}) =>
      sb.from('councils').insert({'name': name, 'type': type, 'academy': academy});

  static Future<void> updateCouncil(String id, {required String name, required String type, String? academy}) =>
      sb.from('councils').update({'name': name, 'type': type, 'academy': academy}).eq('id', id);

  static Future<void> deleteCouncil(String id) => sb.from('councils').delete().eq('id', id);

  /// Council ids the user belongs to (SIEC always included).
  static Future<Set<String>> councilIdsOf(String userId) async {
    final rows = await sb.from('council_members').select('council_id').eq('user_id', userId);
    final all = await councils();
    return {
      ...(rows as List).map((r) => r['council_id'] as String),
      ...all.where((c) => c.isSiec).map((c) => c.id),
    };
  }

  static Future<Map<String, String>> memberNames() async {
    final rows = await sb.from('member_names').select('id, full_name');
    return {for (final r in rows as List) r['id'] as String: (r['full_name'] ?? '') as String};
  }

  // ---------- meetings ----------
  static Future<List<Meeting>> meetings() async =>
      _list(await sb.from('meetings').select().order('starts_at'), Meeting.fromMap);

  static Future<void> createMeeting(
          {required String councilId, required String title, required DateTime startsAt, String? location}) =>
      sb.from('meetings').insert({
        'council_id': councilId,
        'title': title,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'location': location,
      });

  static Future<void> deleteMeeting(String id) => sb.from('meetings').delete().eq('id', id);

  static Future<int> requestAgendaInput(String meetingId) async =>
      ((await sb.rpc('request_agenda_input', params: {'p_meeting': meetingId})) as num).toInt();

  // ---------- time entries & reports ----------
  static Future<List<TimeEntry>> entries({required String userId, required String semesterId}) async => _list(
      await sb
          .from('time_entries')
          .select()
          .eq('user_id', userId)
          .eq('semester_id', semesterId)
          .order('work_date', ascending: false),
      TimeEntry.fromMap);

  /// Officer: every entry of the semester (RLS lets reps see only their own).
  static Future<List<TimeEntry>> allEntries(String semesterId) async => _list(
      await sb.from('time_entries').select().eq('semester_id', semesterId).order('user_id').order('work_date'),
      TimeEntry.fromMap);

  static Future<String> addEntry({
    required DateTime date,
    required String activity,
    String? councilId,
    String? meetingId,
    required int minutes,
    required String description,
    String? startTime, // 'HH:MM'
  }) async {
    final r = await sb
        .from('time_entries')
        .insert({
          'work_date': date.toIso8601String().substring(0, 10),
          'activity': activity,
          'council_id': councilId,
          'meeting_id': meetingId,
          'minutes': minutes,
          'description': description,
          'start_time': startTime,
        })
        .select('id')
        .single();
    return r['id'] as String;
  }

  static Future<void> deleteEntry(String id) => sb.from('time_entries').delete().eq('id', id);

  static Future<void> uploadNote({required String entryId, required String fileName, required Uint8List bytes}) async {
    final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '$uid/$entryId/${DateTime.now().millisecondsSinceEpoch}_$safe';
    await sb.storage.from(notesBucket).uploadBinary(path, bytes);
    await sb.from('attachments').insert({'entry_id': entryId, 'storage_path': path, 'file_name': fileName});
  }

  static Future<List<Attachment>> attachments(List<String> entryIds) async {
    if (entryIds.isEmpty) return [];
    return _list(await sb.from('attachments').select().inFilter('entry_id', entryIds), Attachment.fromMap);
  }

  static Future<String> noteUrl(String path) => sb.storage.from(notesBucket).createSignedUrl(path, 300);

  static Future<List<ReportRow>> reportOverview() async =>
      _list(await sb.from('report_overview').select().order('full_name'), ReportRow.fromMap);

  static Future<ReportRow?> myReport() async {
    final r = await sb.from('report_overview').select().eq('user_id', uid).maybeSingle();
    return r == null ? null : ReportRow.fromMap(r);
  }

  static Future<void> submitReport() => sb.rpc('submit_time_report');

  /// action: approve | return | paid
  static Future<void> reviewReport(String reportId, String action, {String? comment}) =>
      sb.rpc('review_time_report', params: {'p_report': reportId, 'p_action': action, 'p_comment': comment});

  static Future<int> remindUnsubmitted() async => ((await sb.rpc('remind_unsubmitted')) as num).toInt();

  static Future<List<Map<String, dynamic>>> payroll() async =>
      List<Map<String, dynamic>>.from((await sb.rpc('payroll_export')) as List);

  // ---------- agenda ----------
  static Future<List<AgendaItem>> agendaItems({String? meetingId}) async {
    var q = sb.from('agenda_items').select();
    if (meetingId != null) q = q.eq('meeting_id', meetingId);
    return _list(await q.order('created_at'), AgendaItem.fromMap);
  }

  static Future<void> addAgendaItem(
          {required String meetingId,
          required String title,
          required String details,
          required String source,
          required int studentCount}) =>
      sb.from('agenda_items').insert({
        'meeting_id': meetingId,
        'title': title,
        'details': details,
        'source': source,
        'student_count': studentCount,
      });

  static Future<void> setAgendaStatus(String id, String status) =>
      sb.from('agenda_items').update({'status': status}).eq('id', id);

  static Future<void> deleteAgendaItem(String id) => sb.from('agenda_items').delete().eq('id', id);

  static Future<List<OpenIssue>> openIssuesForMeeting(String meetingId) async =>
      _list(await sb.rpc('open_issues_for_meeting', params: {'p_meeting': meetingId}), OpenIssue.fromMap);

  // ---------- follow-ups ----------
  static Future<List<Issue>> issues() async =>
      _list(await sb.from('issues').select().order('created_at', ascending: false), Issue.fromMap);

  static Future<void> addIssue(
          {required String councilId,
          String? meetingId,
          required String title,
          required String details,
          String? responsible}) =>
      sb.from('issues').insert({
        'council_id': councilId,
        'raised_at_meeting': meetingId,
        'title': title,
        'details': details,
        'responsible': responsible,
      });

  static Future<void> setIssueStatus(String id, String status, {String? response}) =>
      sb.rpc('set_issue_status', params: {'p_issue': id, 'p_status': status, 'p_response': response});

  static Future<List<Map<String, dynamic>>> issueEvents(String issueId) async => List<Map<String, dynamic>>.from(
      await sb.from('issue_events').select().eq('issue_id', issueId).order('at') as List);

  // ---------- channels ----------
  static Future<List<Channel>> channels() async =>
      _list(await sb.from('channels').select().order('sort_order').order('created_at'), Channel.fromMap);

  static Future<void> saveChannel(
      {String? id, required String name, required String description, required String audience, required bool officerOnly}) {
    final values = {'name': name, 'description': description, 'audience': audience, 'officer_only': officerOnly};
    return id == null ? sb.from('channels').insert(values) : sb.from('channels').update(values).eq('id', id);
  }

  static Future<void> deleteChannel(String id) => sb.from('channels').delete().eq('id', id);

  static const channelFilesBucket = 'channel-files';

  /// Uploads a file to the channel's storage and returns its path.
  static Future<String> uploadChannelFile(String fileName, Uint8List bytes) async {
    final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '$uid/${DateTime.now().millisecondsSinceEpoch}_$safe';
    await sb.storage.from(channelFilesBucket).uploadBinary(path, bytes);
    return path;
  }

  static Future<String> channelFileUrl(String path) => sb.storage.from(channelFilesBucket).createSignedUrl(path, 300);

  static Stream<List<Message>> messageStream(String channelId) => sb
      .from('messages')
      .stream(primaryKey: ['id'])
      .eq('channel_id', channelId)
      .order('created_at', ascending: true)
      .map((rows) => rows.map(Message.fromMap).toList());

  static Future<void> sendMessage(String channelId, String body,
          {bool announcement = false, String? filePath, String? fileName}) =>
      sb.from('messages').insert({
        'channel_id': channelId,
        'body': body,
        'is_announcement': announcement,
        'file_path': filePath,
        'file_name': fileName,
      });

  static Future<Set<String>> myReadMessageIds() async {
    final rows = await sb.from('message_reads').select('message_id').eq('user_id', uid);
    return {for (final r in rows as List) r['message_id'] as String};
  }

  static Future<void> markRead(String messageId) => sb.rpc('mark_message_read', params: {'p_message': messageId});

  static Future<List<Map<String, dynamic>>> announcementReads(String messageId) async =>
      List<Map<String, dynamic>>.from((await sb.rpc('announcement_reads', params: {'p_message': messageId})) as List);

  /// Announcements the user has not confirmed yet.
  static Future<int> unreadAnnouncements() async {
    final ann = await sb.from('messages').select('id').eq('is_announcement', true);
    final read = await myReadMessageIds();
    return (ann as List).where((r) => !read.contains(r['id'])).length;
  }

  // ---------- tutoring ----------
  static Future<List<TutoringPost>> tutoring() async =>
      _list(await sb.from('tutoring_posts').select().order('created_at', ascending: false), TutoringPost.fromMap);

  static Future<void> addTutoring({required String kind, required String course, required String body}) =>
      sb.from('tutoring_posts').insert({'kind': kind, 'course': course, 'body': body});

  static Future<void> setTutoringHidden(String id, bool hidden) =>
      sb.from('tutoring_posts').update({'hidden': hidden}).eq('id', id);

  static Future<void> deleteTutoring(String id) => sb.from('tutoring_posts').delete().eq('id', id);

  // ---------- notifications ----------
  static Stream<List<AppNotification>> notificationStream() => sb
      .from('notifications')
      .stream(primaryKey: ['id'])
      .eq('user_id', uid)
      .order('created_at', ascending: false)
      .limit(100)
      .map((rows) => rows.map(AppNotification.fromMap).toList());

  static Future<void> markAllNotificationsRead() => sb
      .from('notifications')
      .update({'read_at': DateTime.now().toUtc().toIso8601String()})
      .eq('user_id', uid)
      .isFilter('read_at', null);

  // ---------- directory & officer admin ----------
  static Future<List<Map<String, dynamic>>> directory() async =>
      List<Map<String, dynamic>>.from(await sb.from('rep_directory').select().order('full_name') as List);

  static Future<List<Profile>> profiles() async =>
      _list(await sb.from('profiles').select().order('full_name'), Profile.fromMap);

  static Future<void> updateProfile(String id, Map<String, dynamic> values) =>
      sb.from('profiles').update(values).eq('id', id);

  static Future<void> setCouncils(String userId, Set<String> councilIds) async {
    await sb.from('council_members').delete().eq('user_id', userId);
    if (councilIds.isNotEmpty) {
      await sb.from('council_members').insert([for (final c in councilIds) {'council_id': c, 'user_id': userId}]);
    }
  }

  static Future<void> updateSemester(String id, Map<String, dynamic> values) =>
      sb.from('semesters').update(values).eq('id', id);

  static Future<void> startNewSemester(
          {required String name,
          required DateTime starts,
          required DateTime ends,
          required DateTime deadline,
          DateTime? reminder}) =>
      sb.rpc('start_new_semester', params: {
        'p_name': name,
        'p_starts': _d(starts),
        'p_ends': _d(ends),
        'p_deadline': _d(deadline),
        'p_reminder': reminder == null ? null : _d(reminder),
      });

  static Future<Map<String, dynamic>> runAutomations() async =>
      Map<String, dynamic>.from((await sb.rpc('run_automations')) as Map);

  static String _d(DateTime d) => d.toIso8601String().substring(0, 10);
}
