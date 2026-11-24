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

  /// Any signed-in user changes their own password.
  static Future<void> changeMyPassword(String password) async {
    await sb.auth.updateUser(UserAttributes(password: password));
    await sb.rpc('password_changed');
  }

  /// Can new people create an account themselves? (Asked before signing in.)
  static Future<bool> signupOpen() async {
    try {
      return (await sb.rpc('signup_open')) as bool? ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Payslip link (e.g. Fortnox) and its name, set by the Head of Education
  static Future<(String?, String)> payslipLink() async {
    try {
      final row = await sb.from('app_settings').select('payslip_url, payslip_label').maybeSingle();
      final url = (row?['payslip_url'] as String?)?.trim();
      final label = (row?['payslip_label'] as String?)?.trim();
      return (url == null || url.isEmpty ? null : url, label == null || label.isEmpty ? 'Fortnox' : label);
    } catch (_) {
      return (null, 'Fortnox');
    }
  }

  static Future<void> setPayslipLink(String? url, String label) => sb
      .from('app_settings')
      .update({'payslip_url': url == null || url.trim().isEmpty ? null : url.trim(), 'payslip_label': label.trim()})
      .eq('id', true);

  static Future<void> setSignupOpen(bool open) =>
      sb.from('app_settings').update({'signup_open': open}).eq('id', true);

  /// Head of Education creates an account (Edge Function admin-create-user). Returns the temporary password.
  static Future<String> createAccount({required String fullName, required String email}) async {
    final res = await sb.functions.invoke('admin-create-user', body: {'full_name': fullName, 'email': email});
    final data = res.data;
    if (res.status != 200 || data is! Map || data['ok'] != true) {
      throw Exception(data is Map && data['error'] != null ? '${data['error']}' : 'Could not create the account');
    }
    return data['password'] as String;
  }

  /// Head of Education sets a temporary password for a representative (Edge Function admin-reset-password).
  static Future<void> adminResetPassword(String userId, String password) async {
    final res = await sb.functions.invoke('admin-reset-password', body: {'user_id': userId, 'password': password});
    final data = res.data;
    if (res.status != 200 || (data is Map && data['ok'] != true)) {
      throw Exception(data is Map && data['error'] != null ? '${data['error']}' : 'Could not reset the password');
    }
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

  /// Programme details (city, intake, length, seats, director …). Returns the id.
  static Future<String> saveCouncil(String? id, Map<String, dynamic> values) async {
    if (id == null) {
      final row = await sb.from('councils').insert(values).select('id').single();
      return row['id'] as String;
    }
    await sb.from('councils').update(values).eq('id', id);
    return id;
  }

  /// Study years from the cohorts (they move up in August/January)
  static Future<void> refreshStudyYears() async {
    try {
      await sb.rpc('refresh_study_years');
    } catch (_) {
      // not critical
    }
  }

  static Future<List<RosterEntry>> roster() async =>
      _list(await sb.from('roster').select().order('cohort'), RosterEntry.fromMap);

  static Future<void> addToRoster(String councilId, String email, {String? cohort, String? note}) =>
      sb.from('roster').insert({
        'council_id': councilId,
        'email': email.trim().toLowerCase(),
        'cohort': cohort,
        'note': (note == null || note.trim().isEmpty) ? null : note.trim(),
      });

  static Future<void> updateRoster(String id, {String? cohort, String? note}) => sb
      .from('roster')
      .update({'cohort': cohort, 'note': (note == null || note.trim().isEmpty) ? null : note.trim()}).eq('id', id);

  static Future<void> removeFromRoster(String id) => sb.from('roster').delete().eq('id', id);

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
      _list(await sb.from('meetings').select().order('starts_at', ascending: true), Meeting.fromMap); // oldest first

  static Future<void> createMeeting(
          {required String councilId,
          required String title,
          required DateTime startsAt,
          String? location,
          bool servesFood = true}) =>
      sb.from('meetings').insert({
        'council_id': councilId,
        'title': title,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'location': location,
        'serves_food': servesFood,
      });

  /// Head of Education: is food served at this meeting (ask for food preferences)?
  static Future<void> setServesFood(String meetingId, bool on) =>
      sb.from('meetings').update({'serves_food': on}).eq('id', meetingId);

  static Future<void> deleteMeeting(String id) => sb.from('meetings').delete().eq('id', id);

  static Future<int> requestAgendaInput(String meetingId) async =>
      ((await sb.rpc('request_agenda_input', params: {'p_meeting': meetingId})) as num).toInt();

  /// Active representatives of a council (SIEC = all representatives).
  static Future<Set<String>> councilMemberIds(String councilId) async {
    final rows = await sb.rpc('council_member_ids', params: {'p_council': councilId}) as List;
    return {for (final r in rows) r is Map ? r.values.first as String : r as String};
  }

  // ---------- posts from the Head of Education ----------
  static const postsBucket = 'posts';

  static Future<List<Post>> posts({int limit = 50}) async => _list(
      await sb.from('posts').select().order('created_at', ascending: false).limit(limit), Post.fromMap);

  /// Latest final agenda published for a meeting, if any
  static Future<Post?> finalAgenda(String meetingId) async {
    final r = await sb
        .from('posts')
        .select()
        .eq('meeting_id', meetingId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return r == null ? null : Post.fromMap(r);
  }

  static Future<void> createPost({
    required String title,
    String body = '',
    String? councilId,
    String? meetingId,
    String? fileName,
    Uint8List? bytes,
    List<String> mentions = const [],
  }) async {
    String? path;
    if (fileName != null && bytes != null) {
      final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      path = '${DateTime.now().millisecondsSinceEpoch}_$safe';
      await sb.storage.from(postsBucket).uploadBinary(path, bytes);
    }
    await sb.from('posts').insert({
      'title': title,
      'body': body,
      'council_id': councilId,
      'meeting_id': meetingId,
      'file_path': path,
      'file_name': path == null ? null : fileName,
      'mentions': mentions,
    });
  }

  static Future<void> editPost(String id, {required String title, required String body}) =>
      sb.from('posts').update({'title': title, 'body': body}).eq('id', id);

  static Future<void> deletePost(Post p) async {
    await sb.from('posts').delete().eq('id', p.id);
    if (p.filePath != null) {
      await sb.storage.from(postsBucket).remove([p.filePath!]).catchError((_) => <FileObject>[]);
    }
  }

  static Future<String> postFileUrl(String path) => sb.storage.from(postsBucket).createSignedUrl(path, 300);

  // ---------- attendance ----------
  /// The signed-in rep's answers: meeting id → mode
  static Future<Map<String, String>> myAttendance() async {
    final rows = await sb.from('meeting_attendance').select('meeting_id, mode').eq('user_id', uid);
    return {for (final r in rows as List) r['meeting_id'] as String: r['mode'] as String};
  }

  /// My food preference for a meeting I attend in the room (empty list = not answered yet)
  static Future<(List<String>, String?)> myFood(String meetingId) async {
    final r = await sb
        .from('meeting_attendance')
        .select('food, food_other')
        .eq('meeting_id', meetingId)
        .eq('user_id', uid)
        .maybeSingle();
    return (((r?['food'] as List?) ?? const []).cast<String>(), r?['food_other'] as String?);
  }

  static Future<void> setFood(String meetingId, List<String> food, String? other) =>
      sb.rpc('set_food', params: {'p_meeting': meetingId, 'p_food': food, 'p_other': other});

  static Future<void> setAttendance(String meetingId, String? mode) =>
      sb.rpc('set_attendance', params: {'p_meeting': meetingId, 'p_mode': mode});

  /// Officer: set (or with null remove) someone's attendance, also after the meeting
  static Future<void> setAttendanceFor(String meetingId, String userId, String? mode) =>
      sb.rpc('set_attendance_for', params: {'p_meeting': meetingId, 'p_user': userId, 'p_mode': mode});

  /// "No topics this time" for a meeting
  static Future<void> setNoInput(String meetingId, bool noInput) =>
      sb.rpc('set_no_input', params: {'p_meeting': meetingId, 'p_no_input': noInput});

  /// Meetings where the signed-in rep said they have no topics
  static Future<Set<String>> myNoInput() async {
    final rows = await sb.from('meeting_no_input').select('meeting_id').eq('user_id', uid);
    return {for (final r in rows as List) r['meeting_id'] as String};
  }

  /// Officer: who said "no topics" for a meeting
  static Future<Set<String>> noInputFor(String meetingId) async {
    final rows = await sb.from('meeting_no_input').select('user_id').eq('meeting_id', meetingId);
    return {for (final r in rows as List) r['user_id'] as String};
  }

  /// Officer: all answers (optionally for one meeting)
  static Future<List<Attendance>> attendance({String? meetingId}) async {
    var q = sb.from('meeting_attendance').select();
    if (meetingId != null) q = q.eq('meeting_id', meetingId);
    return _list(await q, Attendance.fromMap);
  }

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
      {String? id,
      required String name,
      required String description,
      required String audience,
      required bool officerOnly,
      String? color}) {
    final values = {
      'name': name,
      'description': description,
      'audience': audience,
      'officer_only': officerOnly,
      'color': color,
    };
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

  /// Appearance (mode, colour, banner) on my profile
  static Future<void> saveMyPrefs(Map<String, dynamic> prefs) =>
      sb.from('profiles').update({'ui_prefs': prefs}).eq('id', uid);

  /// Profile photo → public URL, saved on my profile (null removes it)
  static Future<String?> setAvatar(String? fileName, Uint8List? bytes) async {
    String? url;
    if (bytes != null) {
      final ext = (fileName ?? '').contains('.') ? fileName!.split('.').last.toLowerCase() : 'jpg';
      final path = '$uid/avatar_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await sb.storage.from('avatars').uploadBinary(path, bytes);
      url = sb.storage.from('avatars').getPublicUrl(path);
    }
    await sb.from('profiles').update({'avatar_url': url}).eq('id', uid);
    return url;
  }

  /// Head of Education: a person's email
  static Future<String?> emailOf(String userId) async =>
      (await sb.from('profiles').select('email').eq('id', userId).maybeSingle())?['email'] as String?;

  /// What a profile card shows (name, photo, programme, department, councils, email when allowed)
  static Future<Map<String, dynamic>?> profileCard(String userId) async {
    final r = await sb.rpc('profile_card', params: {'p_user': userId});
    return r == null ? null : (r as Map).cast<String, dynamic>();
  }

  /// Everyone's profile photo (id → url)
  static Future<Map<String, String>> avatars() async {
    final rows = await sb.from('member_names').select('id, avatar_url').not('avatar_url', 'is', null);
    return {for (final r in rows as List) r['id'] as String: r['avatar_url'] as String};
  }

  /// Last 7 days vs the 7 days before (Head of Education)
  static Future<Map<String, dynamic>> weeklySummary() async =>
      ((await sb.rpc('weekly_summary')) as Map).cast<String, dynamic>();

  /// My own banner picture → public URL
  static Future<String> uploadBanner(String fileName, Uint8List bytes) async {
    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'jpg';
    final path = '$uid/banner_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await sb.storage.from('banners').uploadBinary(path, bytes);
    return sb.storage.from('banners').getPublicUrl(path);
  }

  static Future<String> channelFileUrl(String path) => sb.storage.from(channelFilesBucket).createSignedUrl(path, 300);

  /// The newest [limit] messages (posts and comments) of a channel, oldest first (live)
  static Stream<List<Message>> messageStream(String channelId, {int limit = 80}) => sb
      .from('messages')
      .stream(primaryKey: ['id'])
      .eq('channel_id', channelId)
      .order('created_at', ascending: false)
      .limit(limit)
      .map((rows) => rows.map(Message.fromMap).toList().reversed.toList());

  static Future<void> sendMessage(String channelId, String body,
          {bool announcement = false, String? filePath, String? fileName, String? parentId, List<String>? mentions}) =>
      sb.from('messages').insert({
        'channel_id': channelId,
        'body': body,
        'is_announcement': announcement,
        'file_path': filePath,
        'file_name': fileName,
        if (parentId != null) 'parent_id': parentId,
        if (mentions != null && mentions.isNotEmpty) 'mentions': mentions,
      });

  static Future<void> editMessage(String id, String body, {List<String>? mentions}) =>
      sb.from('messages').update({'body': body, if (mentions != null) 'mentions': mentions}).eq('id', id);

  static Future<void> deleteMessage(String id) => sb.from('messages').delete().eq('id', id);

  /// Numbers for the tabs (reps: channels, meetings; officer: reports, signups)
  static Future<Map<String, int>> badges() async {
    try {
      final r = await sb.rpc('my_badges');
      return {for (final e in (r as Map).entries) '${e.key}': (e.value as num).toInt()};
    } catch (_) {
      return const {};
    }
  }

  /// Reactions in one channel (live)
  static Stream<List<Reaction>> reactionStream(String channelId) => sb
      .from('message_reactions')
      .stream(primaryKey: ['message_id', 'user_id']) // same key as the table, so removed reactions disappear live
      .eq('channel_id', channelId)
      .map((rows) => rows.map(Reaction.fromMap).toList());

  /// One reaction per person: a new emoji replaces the old one; off removes it.
  static Future<void> react(String messageId, String emoji, bool on) async {
    await sb.from('message_reactions').delete().eq('message_id', messageId).eq('user_id', uid);
    if (on) await sb.from('message_reactions').insert({'message_id': messageId, 'user_id': uid, 'emoji': emoji});
  }

  /// Marks every message from the Head of Education in the channel as seen.
  /// Per channel: latest post text, when, who, and how many posts from the Head of Education I have not seen
  static Future<Map<String, ({String? body, DateTime? at, String? author, int unread})>> channelOverview() async {
    final rows = await sb.rpc('channel_overview') as List;
    return {
      for (final r in rows)
        r['channel_id'] as String: (
          body: ((r['last_body'] as String?)?.trim().isNotEmpty ?? false)
              ? r['last_body'] as String
              : (r['last_file'] == null ? null : '📎 ${r['last_file']}'),
          at: r['last_at'] == null ? null : DateTime.parse(r['last_at'] as String).toLocal(),
          author: r['last_author'] as String?,
          unread: (r['unread'] as num?)?.toInt() ?? 0,
        )
    };
  }

  static Future<void> markChannelRead(String channelId) =>
      sb.rpc('mark_channel_read', params: {'p_channel': channelId});

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

  static Future<void> addTutoring(
          {required String kind, required String course, required String body, List<String> mentions = const []}) =>
      sb.from('tutoring_posts').insert({'kind': kind, 'course': course, 'body': body, 'mentions': mentions});

  static Future<void> setTutoringHidden(String id, bool hidden) =>
      sb.from('tutoring_posts').update({'hidden': hidden}).eq('id', id);

  static Future<void> deleteTutoring(String id) => sb.from('tutoring_posts').delete().eq('id', id);

  static Future<void> editTutoring(String id, {required String course, required String body, List<String>? mentions}) =>
      sb.from('tutoring_posts').update({'course': course, 'body': body, if (mentions != null) 'mentions': mentions}).eq('id', id);

  // ---------- comments & reactions on posts / tutoring (shared design) ----------
  static Stream<List<ItemComment>> itemComments(String kind) => sb
      .from('item_comments')
      .stream(primaryKey: ['id'])
      .eq('kind', kind)
      .order('created_at', ascending: true)
      .map((rows) => rows.map(ItemComment.fromMap).toList());

  /// Reactions on posts or on the tutoring board (area: post | tutoring), live
  static Stream<List<ItemReaction>> itemReactions(String area) => sb
      .from('item_reactions')
      .stream(primaryKey: ['kind', 'item_id', 'user_id']) // same key as the table
      .eq('area', area)
      .map((rows) => rows.map(ItemReaction.fromMap).toList());

  static Future<void> addItemComment(String kind, String itemId, String body, {List<String> mentions = const []}) =>
      sb.from('item_comments').insert({'kind': kind, 'item_id': itemId, 'body': body.trim(), 'mentions': mentions});

  static Future<void> editItemComment(String id, String body) =>
      sb.from('item_comments').update({'body': body.trim()}).eq('id', id);

  static Future<void> deleteItemComment(String id) => sb.from('item_comments').delete().eq('id', id);

  /// One reaction per person: a new emoji replaces the old one; off removes it.
  static Future<void> reactItem(String kind, String itemId, String emoji, bool on) async {
    await sb.from('item_reactions').delete().eq('kind', kind).eq('item_id', itemId).eq('user_id', uid);
    if (on) await sb.from('item_reactions').insert({'kind': kind, 'item_id': itemId, 'user_id': uid, 'emoji': emoji});
  }

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

  /// Only the changes are written, so roster details (cohort, note) of kept councils stay.
  static Future<void> setCouncils(String userId, Set<String> councilIds) async {
    final now = {
      for (final r in await sb.from('council_members').select('council_id').eq('user_id', userId) as List)
        r['council_id'] as String
    };
    final gone = now.difference(councilIds), added = councilIds.difference(now);
    if (gone.isNotEmpty) {
      await sb.from('council_members').delete().eq('user_id', userId).inFilter('council_id', gone.toList());
    }
    if (added.isNotEmpty) {
      await sb.from('council_members').insert([for (final c in added) {'council_id': c, 'user_id': userId}]);
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
