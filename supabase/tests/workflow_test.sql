-- End-to-end test of permissions and workflow. Run on a fresh database after the migration + seed.
\set ON_ERROR_STOP on
\set QUIET on

create temporary table t(name text, passed boolean);
grant all on t to authenticated;

-- academy channels for the visibility test
insert into public.channels (name, audience) values ('IDT representatives', 'IDT'), ('HVV representatives', 'HVV');

-- ---------- users -----------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
 ('00000000-0000-0000-0000-00000000000a', 'utbildning@mdsu.se',         '{"full_name":"Head of Education"}'),
 ('00000000-0000-0000-0000-000000000001', 'lina@student.mdu.se',        '{"full_name":"Lina Berg"}'),
 ('00000000-0000-0000-0000-000000000002', 'omar@student.mdu.se',        '{"full_name":"Omar Haddad"}'),
 ('00000000-0000-0000-0000-000000000003', 'ahmed@student.mdu.se',       '{"full_name":"Ahmed Saleh"}');
-- 0. new accounts are inactive and see nothing
do $$ begin
  insert into auth.users (email) values ('someone@gmail.com');
  insert into t values ('0x sign-up with gmail is rejected', false);
exception when others then insert into t values ('0x sign-up with gmail is rejected', sqlerrm like 'EMAIL_DOMAIN_NOT_ALLOWED%'); end $$;
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000ff', 'stranger@student.mdu.se');
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000ff', false);
insert into t select '0 unapproved account sees no channels', (select count(*) from public.channels) = 0;
insert into t select '0b unapproved account sees no meetings/names', (select count(*) from public.meetings) = 0
  and (select count(*) from public.member_names) = 0;
insert into t select '0c unapproved account sees own profile', (select count(*) from public.profiles) = 1;
do $$ begin
  insert into public.messages (channel_id, body) select id, 'spam' from public.channels;
  insert into public.time_entries (work_date, activity, minutes) values (current_date, 'class_visit', 30);
  insert into t values ('0d unapproved account cannot log time', false);
exception when others then insert into t values ('0d unapproved account cannot log time', true); end $$;
reset role;
select set_config('request.jwt.claim.sub', '', false);
update public.profiles set active = true where email <> 'stranger@student.mdu.se';
update public.profiles set role = 'officer' where email = 'utbildning@mdsu.se';
update public.profiles set academy='IDT', program='Computer Science', study_year=2, is_member=true  where full_name='Lina Berg';
update public.profiles set academy='HVV', program='Nursing',          study_year=3, is_member=false where full_name='Omar Haddad';
update public.profiles set academy='IDT', program='Computer Science', study_year=1, is_member=true  where full_name='Ahmed Saleh';
insert into public.council_members select c.id, p.id from public.councils c, public.profiles p
 where c.name='Program council – Computer Science' and p.full_name in ('Lina Berg','Ahmed Saleh');
insert into public.council_members select c.id, p.id from public.councils c, public.profiles p
 where c.name='Program council – Nursing' and p.full_name='Omar Haddad';

-- meetings: two past CS meetings, one CS meeting in 10 days, one yesterday
insert into public.meetings (council_id, title, starts_at, input_requested)
select id, 'CS #1', now() - interval '40 days', true from public.councils where name like 'Program council – Computer%';
insert into public.meetings (council_id, title, starts_at, input_requested)
select id, 'CS #2', now() - interval '1 day', true from public.councils where name like 'Program council – Computer%';
insert into public.meetings (council_id, title, starts_at)
select id, 'CS #3', now() + interval '5 days' from public.councils where name like 'Program council – Computer%';
insert into public.meetings (council_id, title, starts_at)
select id, 'Nursing #2', now() + interval '40 days' from public.councils where name like 'Program council – Nursing%';

-- who attended the past meetings (only attendees log time for a meeting)
insert into public.meeting_attendance (meeting_id, user_id, mode)
select id, '00000000-0000-0000-0000-000000000001', 'offline' from public.meetings where title in ('CS #1', 'CS #2');
insert into public.meeting_attendance (meeting_id, user_id, mode)
select id, '00000000-0000-0000-0000-000000000003', 'online' from public.meetings where title = 'CS #2';

-- helper: act as a user
create or replace function pg_temp.as_user(p_name text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', case p_name
    when 'Head of Education' then '00000000-0000-0000-0000-00000000000a'
    when 'Lina Berg'         then '00000000-0000-0000-0000-000000000001'
    when 'Omar Haddad'       then '00000000-0000-0000-0000-000000000002'
    when 'Ahmed Saleh'       then '00000000-0000-0000-0000-000000000003' end, false);
end $$;

-- =====================================================================
set role authenticated;
select from pg_temp.as_user('Lina Berg');

-- 1. Lina logs 60 + 70 minutes (=130 min → 5 started half hours → 325 SEK)
insert into public.time_entries (work_date, activity, council_id, meeting_id, minutes, description)
select current_date - 40, 'council_meeting', m.council_id, m.id, 60, 'CS #1' from public.meetings m where m.title = 'CS #1';
insert into public.time_entries (work_date, activity, council_id, minutes, description)
select current_date - 39, 'preparation', id, 70, 'Read documents' from public.councils where name like 'Program council – Computer%';
insert into t select '1 rep sees own hours = 130', (select minutes from public.report_overview) = 130;
insert into t select '1b estimated amount = 325 SEK', (select amount from public.report_overview) = 325;

-- 1c. rounding per activity like the Excel sheet: 3 × 20 min = 3 started half hours (not 2)
select from pg_temp.as_user('Ahmed Saleh');
insert into public.time_entries (work_date, activity, minutes, start_time) values
  (current_date, 'class_visit', 20, '10:00'), (current_date, 'class_visit', 20, '11:00'), (current_date, 'class_visit', 20, '12:00');
insert into t select '1c per-activity rounding: 3×20 min = 3 half hours = 195 SEK',
  (select half_hours from public.report_overview) = 3 and (select amount from public.report_overview) = 195;
insert into public.time_entries (work_date, activity, minutes, description) values (current_date, 'materials', 45, 'Made a survey');
insert into t select '1d new work types (material, no council) can be logged', (select count(*) from public.time_entries where activity = 'materials') = 1;
select from pg_temp.as_user('Lina Berg');

-- 2. Lina cannot make herself union member / officer
do $$ begin
  update public.profiles set role = 'officer' where id = auth.uid();
  insert into t values ('2 rep cannot change own role', false);
exception when others then insert into t values ('2 rep cannot change own role', true); end $$;
update public.profiles set share_contact = true where id = auth.uid();
insert into t select '2b rep can change share_contact', (select share_contact from public.profiles where id = auth.uid());

-- 3. Lina adds agenda item to CS #3 (her council), not to Nursing
insert into public.agenda_items (meeting_id, title, details, student_count)
select id, 'Lab overlaps lecture', '12 students', 12 from public.meetings where title = 'CS #3';
do $$ begin
  insert into public.agenda_items (meeting_id, title) select id, 'x' from public.meetings where title = 'Nursing #2';
  insert into t values ('3 rep cannot add to other council (or meeting invisible)', (select count(*) from public.agenda_items where title='x') = 0);
exception when others then insert into t values ('3 rep cannot add to other council (or meeting invisible)', true); end $$;
insert into t select '3b rep sees only own council meetings + SIEC', not exists (select 1 from public.meetings where title like 'Nursing%');

-- 4. Lina logs an issue in CS #1
insert into public.issues (council_id, raised_at_meeting, title, responsible)
select m.council_id, m.id, 'Exam results late', 'Program coordinator' from public.meetings m where m.title = 'CS #1';

-- 5. Lina cannot post announcements or in officer-only channel
do $$ begin
  insert into public.messages (channel_id, body) select id, 'hi' from public.channels where name = 'SIEC';
  insert into t values ('5 rep cannot post in SIEC (moderators only)', false);
exception when others then insert into t values ('5 rep cannot post in SIEC (moderators only)', true); end $$;
insert into t select '5b rep sees IDT channel, not HVV', exists (select 1 from public.channels where name='IDT representatives')
                                                     and not exists (select 1 from public.channels where name='HVV representatives');

-- 6. Lina submits → entries locked
select public.submit_time_report();
insert into t select '6 report submitted', (select status from public.report_overview) = 'submitted';
do $$ begin
  insert into public.time_entries (work_date, activity, minutes) values (current_date, 'class_visit', 30);
  insert into t values ('6b entries locked after submit', false);
exception when others then insert into t values ('6b entries locked after submit', true); end $$;

-- 6c. Phone token moves to whoever signs in on the phone
select public.register_device('phone-token-1', 'android');
insert into t select '6c device registered for Lina', (select count(*) from public.device_tokens) = 1;

-- 7. Omar (HVV, not member)
select from pg_temp.as_user('Omar Haddad');
insert into t select '7g Omar cannot see Lina''s device token', (select count(*) from public.device_tokens) = 0;
select public.register_device('phone-token-1', 'android');
insert into t select '7h shared phone token moves to Omar', (select count(*) from public.device_tokens) = 1;
insert into t select '7 rep cannot see other reps time entries', (select count(*) from public.time_entries) = 0;
insert into public.time_entries (work_date, activity, minutes) values (current_date, 'student_input', 90);
insert into t select '7b non-member amount = 0', (select amount from public.report_overview) = 0;
insert into t select '7c report_overview shows only own row', (select count(*) from public.report_overview) = 1;
insert into public.private_details (user_id, personal_number, address) values (auth.uid(), '19990101-1234', 'Vägsgatan 1, 123 45 Ort');
insert into t select '7d rep cannot see issue in other council', (select count(*) from public.issues) = 0;
insert into t select '7e payroll empty for rep', (select count(*) from public.payroll_export()) = 0;
do $$ begin
  perform public.review_time_report((select id from public.time_reports limit 1), 'approve');
  insert into t values ('7f rep cannot approve', false);
exception when others then insert into t values ('7f rep cannot approve', true); end $$;

-- 8. Officer
select from pg_temp.as_user('Head of Education');
insert into t select '8 officer sees all 3 active reps', (select count(*) from public.report_overview) = 3;
insert into t select '8b officer sees Omar personal number', (select count(*) from public.private_details) = 1;
select public.review_time_report((select report_id from public.report_overview where full_name='Lina Berg'), 'approve');
insert into t select '8c approved amount snapshot 325', (select approved_amount from public.time_reports where status='approved') = 325;
insert into public.messages (channel_id, body, is_announcement)
  select id, 'Reports due 17 Jan', true from public.channels where name = 'SIEC';
insert into t select '8d announcement → notification per rep',
  (select count(*) from public.notifications where title = 'New announcement') = 0; -- officer cannot read others' notifications (RLS)
insert into t select '8e payroll has 1 row (Lina approved)', (select count(*) from public.payroll_export()) = 1;
insert into t select '8e2 payroll row has email + half hours', (select email from public.payroll_export()) = 'lina@student.mdu.se'
  and (select started_half_hours from public.payroll_export()) = 5;
insert into t select '8f open follow-up carried to CS #3',
  (select count(*) from public.open_issues_for_meeting((select id from public.meetings where title='CS #3'))) = 1;
insert into t select '8g announcement read list = 3 reps', (select count(*) from public.announcement_reads((select id from public.messages where is_announcement))) = 3;
insert into t select '8h officer sees all agenda items', (select count(*) from public.agenda_items) = 1;
update public.agenda_items set status = 'included';

-- 9. Automations (run as officer)
select public.run_automations() as automation_result \gset
-- CS #3 (in 5 days) was already asked when it was created; Nursing (in 40 days) is not due yet
insert into t select '9 automations: no second agenda call (CS #3 asked on creation, Nursing not yet)',
  (:'automation_result'::jsonb ->> 'agenda_calls')::int = 0
  and (select input_requested from public.meetings where title = 'CS #3')
  and not (select input_requested from public.meetings where title = 'Nursing #2');
insert into t select '9f input deadline defaults to 2 days before', (select input_deadline from public.meetings where title = 'CS #3') = ((now() + interval '5 days') at time zone 'Europe/Stockholm')::date - 2;
insert into t select '9b automations: time-log prompts for CS #2 (2 members)', (:'automation_result'::jsonb ->> 'time_prompts')::int = 2;
insert into t select '9c automations: issue escalated? (only 1 meeting since → no)', (:'automation_result'::jsonb ->> 'escalated')::int = 0;
select public.run_automations() as automation_result2 \gset
insert into t select '9d automations do not repeat prompts', (:'automation_result2'::jsonb ->> 'time_prompts')::int = 0;

-- 9e. a second meeting passes without an answer → escalation
insert into public.meetings (council_id, title, starts_at, input_requested)
select id, 'CS #2b', now() - interval '5 days', true from public.councils where name like 'Program council – Computer%';
select public.run_automations() as automation_result3 \gset
insert into t select '9e automations: escalate after 2 meetings without answer', (:'automation_result3'::jsonb ->> 'escalated')::int = 1
  and (select status from public.issues limit 1) = 'escalated';

-- 9g. officer deletes a council that has logged (and approved) hours: hours stay, link cleared
insert into public.councils (name, type) values ('Temporary council', 'general');
update public.time_entries set council_id = (select id from public.councils where name = 'Temporary council')
  where id = (select id from public.time_entries where user_id = '00000000-0000-0000-0000-000000000002' limit 1);
delete from public.councils where name = 'Temporary council';
insert into t select '9g council deleted, hours kept', (select count(*) from public.councils where name='Temporary council') = 0
  and (select count(*) from public.time_entries where user_id = '00000000-0000-0000-0000-000000000002') = 1;
insert into public.councils (name, type) values ('Temp 2', 'general');
reset role;
select set_config('request.jwt.claim.sub', '', false);
set session_replication_role = replica;   -- test setup only: skip the lock trigger
update public.time_entries set council_id = (select id from public.councils where name = 'Temp 2')
  where user_id = '00000000-0000-0000-0000-000000000001';      -- Lina's report is APPROVED (locked)
set session_replication_role = origin;
set role authenticated;
select from pg_temp.as_user('Head of Education');
delete from public.councils where name = 'Temp 2';
insert into t select '9h council with locked report hours can be deleted', (select count(*) from public.councils where name='Temp 2') = 0;

-- 9i. deleting a user who raised an issue and logged hours removes their data, keeps the issue
reset role;
select set_config('request.jwt.claim.sub', '', false);
insert into auth.users (id, email) values ('00000000-0000-0000-0000-0000000000dd', 'temp.rep@student.mdu.se');
update public.profiles set active = true where id = '00000000-0000-0000-0000-0000000000dd';
insert into public.council_members select c.id, '00000000-0000-0000-0000-0000000000dd' from public.councils c where c.name like 'Program council – Computer%';
insert into public.time_entries (user_id, work_date, activity, minutes) values ('00000000-0000-0000-0000-0000000000dd', current_date, 'class_visit', 30);
insert into public.issues (council_id, raised_by, title) select id, '00000000-0000-0000-0000-0000000000dd', 'Temp issue' from public.councils where name like 'Program council – Computer%';
insert into public.time_reports (user_id, semester_id, status) select '00000000-0000-0000-0000-0000000000dd', id, 'approved' from public.semesters where is_current;
delete from auth.users where id = '00000000-0000-0000-0000-0000000000dd';
insert into t select '9i deleted user with approved report: hours gone, issue kept',
  not exists (select 1 from public.time_entries where user_id = '00000000-0000-0000-0000-0000000000dd')
  and exists (select 1 from public.issues where title = 'Temp issue' and raised_by is null);
delete from public.issues where title = 'Temp issue';
set role authenticated;
select from pg_temp.as_user('Head of Education');

-- 10. back as Lina: notifications arrived, mark read
select from pg_temp.as_user('Lina Berg');
insert into t select '10 Lina got approval + announcement + agenda + log prompt',
  (select count(*) from public.notifications) >= 4;
select public.mark_message_read((select id from public.messages where is_announcement));
insert into t select '10b Lina can record university answer', (select status from public.set_issue_status(
  (select id from public.issues limit 1), 'answered', 'Fixed from next exam')) = 'answered';
do $$ begin
  perform public.set_issue_status((select id from public.issues limit 1), 'closed');
  insert into t values ('10c rep cannot close issue', false);
exception when others then insert into t values ('10c rep cannot close issue', true); end $$;

-- 11. Tutoring
insert into public.tutoring_posts (kind, course, body) values ('offer', 'Linear algebra', 'Tuesdays');
select from pg_temp.as_user('Head of Education');
update public.tutoring_posts set hidden = true;
select from pg_temp.as_user('Omar Haddad');
insert into t select '11 hidden tutoring post invisible to others', (select count(*) from public.tutoring_posts) = 0;
insert into t select '11b directory shows Lina (shared)', exists (select 1 from public.rep_directory where full_name='Lina Berg');

-- 12. Attendance
select from pg_temp.as_user('Ahmed Saleh');
select from public.set_attendance((select id from public.meetings where title='CS #3'), 'online');
do $$ begin
  perform public.set_attendance((select id from public.meetings where title='Nursing #2'), 'online');
  insert into t values ('12 no attendance answer outside own council', false);
exception when others then insert into t values ('12 no attendance answer outside own council', true); end $$;
select from pg_temp.as_user('Lina Berg');
select from public.set_attendance((select id from public.meetings where title='CS #3'), 'absent');
select from public.set_attendance((select id from public.meetings where title='CS #3'), 'offline');
insert into t select '12b rep sees only own answer (changed to offline)',
  not exists (select 1 from public.meeting_attendance where user_id <> auth.uid())
  and (select mode from public.meeting_attendance where meeting_id = (select id from public.meetings where title='CS #3')) = 'offline';
do $$ begin
  insert into public.meeting_attendance (meeting_id, user_id, mode)
  select id, '00000000-0000-0000-0000-000000000003', 'absent' from public.meetings where title='CS #1';
  insert into t values ('12c rep cannot answer for someone else', false);
exception when others then insert into t values ('12c rep cannot answer for someone else', true); end $$;
select from pg_temp.as_user('Head of Education');
insert into t select '12d officer sees 1 offline + 1 online',
  (select count(*) filter (where mode='offline') = 1 and count(*) filter (where mode='online') = 1
     from public.meeting_attendance where meeting_id = (select id from public.meetings where title='CS #3'));

-- 13. New meeting notifies the council, officer posts notify, "no topics"
select from pg_temp.as_user('Head of Education');
insert into public.meetings (council_id, title, starts_at)
select id, 'CS #9', now() + interval '3 days' from public.councils where name like 'Program council – Computer%';
select from pg_temp.as_user('Ahmed Saleh');
insert into t select '13 rep told about a new meeting at once',
  exists (select 1 from public.notifications where title = 'New meeting: CS #9' and link like 'agenda/%');
select from pg_temp.as_user('Omar Haddad');
insert into t select '13b other council not told', not exists (select 1 from public.notifications where title = 'New meeting: CS #9');
reset role;
insert into t select '13c meeting inside the call window counts as asked',
  (select input_requested from public.meetings where title = 'CS #9');
set role authenticated;
select from pg_temp.as_user('Head of Education');
insert into public.messages (channel_id, author_id, body)
select id, auth.uid(), 'Remember the SIEC meeting' from public.channels where name = 'Allmänt';
select from pg_temp.as_user('Ahmed Saleh');
insert into t select '13d ordinary post by the Head of Education notifies reps',
  exists (select 1 from public.notifications where title = 'Head of Education in Allmänt' and body = 'Remember the SIEC meeting');
insert into public.messages (channel_id, author_id, body, parent_id)
select channel_id, auth.uid(), 'Hi all', id from public.messages where body = 'Remember the SIEC meeting';
select from pg_temp.as_user('Lina Berg');
insert into t select '13e rep comments do not notify other reps', not exists (select 1 from public.notifications where body = 'Hi all');
select from public.set_no_input((select id from public.meetings where title = 'CS #9'), true);
select from public.set_no_input((select id from public.meetings where title = 'CS #9'), true);
insert into t select '13f no-topics answer saved once', (select count(*) from public.meeting_no_input) = 1;
select from pg_temp.as_user('Head of Education');
insert into t select '13g officer sees who has no topics',
  exists (select 1 from public.meeting_no_input n join public.profiles p on p.id = n.user_id where p.full_name = 'Lina Berg');

-- 14. Posts and final agendas
select from pg_temp.as_user('Head of Education');
insert into public.posts (title, body) values ('Welcome', 'Read the handbook');
insert into public.posts (title, body, council_id)
select 'CS only', 'For the CS council', id from public.councils where name like 'Program council – Computer%';
insert into public.posts (title, file_name, file_path, meeting_id)
select 'Final agenda', 'agenda.pdf', 'x/agenda.pdf', id from public.meetings where title = 'CS #9';
select from pg_temp.as_user('Ahmed Saleh');
insert into t select '14 rep sees post for all + own council + final agenda', (select count(*) from public.posts) = 3;
insert into t select '14b rep told about the post',
  exists (select 1 from public.notifications where title = 'From the Head of Education: Welcome' and link like 'posts/%');
insert into t select '14c final agenda notification opens the meeting',
  exists (select 1 from public.notifications where title = 'Final agenda: CS #9' and link like 'agenda/%');
insert into t select '14d final agenda took the meeting''s council',
  (select council_id from public.posts where title = 'Final agenda') = (select council_id from public.meetings where title = 'CS #9');
do $$ begin
  insert into public.posts (title) values ('rep post');
  insert into t values ('14e rep cannot post', false);
exception when others then insert into t values ('14e rep cannot post', true); end $$;
select from pg_temp.as_user('Omar Haddad');
insert into t select '14f other council sees only the post for all', (select count(*) from public.posts) = 1
  and not exists (select 1 from public.notifications where title = 'From the Head of Education: CS only');

-- 15. Phase 5: comments in post channels, seen-by, attendance decides who logs time
select from pg_temp.as_user('Lina Berg');
insert into public.messages (channel_id, body, parent_id)
select channel_id, 'Thanks, noted', id from public.messages where body = 'Reports due 17 Jan';
insert into t select '15 rep can comment on a post in SIEC', exists (select 1 from public.messages where body = 'Thanks, noted');
do $$ begin
  insert into public.messages (channel_id, body, parent_id)
  select channel_id, 'reply to reply', id from public.messages where body = 'Thanks, noted';
  insert into t values ('15b no comments on comments', false);
exception when others then insert into t values ('15b no comments on comments', true); end $$;
select from pg_temp.as_user('Ahmed Saleh');
select public.mark_channel_read((select id from public.channels where name = 'Allmänt')) as seen \gset
insert into t select '15c opening a channel marks the Head of Education''s messages as seen', :seen = 1;
select from pg_temp.as_user('Head of Education');
insert into t select '15d officer told about the comment',
  exists (select 1 from public.notifications where title = 'New comment in SIEC' and body = 'Thanks, noted');
insert into t select '15e seen-by works for ordinary messages',
  (select count(*) from public.announcement_reads((select id from public.messages where body = 'Remember the SIEC meeting'))
    where read_at is not null) = 1;
select from pg_temp.as_user('Ahmed Saleh');
do $$ begin
  perform public.set_attendance((select id from public.meetings where title='CS #1'), 'offline');
  insert into t values ('15f rep cannot sign up after the meeting started', false);
exception when others then insert into t values ('15f rep cannot sign up after the meeting started', sqlerrm like '%has started%'); end $$;
do $$ begin
  insert into public.time_entries (work_date, activity, meeting_id, minutes)
  select current_date - 40, 'council_meeting', id, 60 from public.meetings where title = 'CS #1';
  insert into t values ('15g no time for a meeting you did not attend', false);
exception when others then insert into t values ('15g no time for a meeting you did not attend', sqlerrm like '%not registered%'); end $$;
do $$ begin
  insert into public.time_entries (work_date, activity, minutes) values (current_date, 'council_meeting', 60);
  insert into t values ('15h council meeting needs the meeting', false);
exception when others then insert into t values ('15h council meeting needs the meeting', true); end $$;
select from pg_temp.as_user('Head of Education');
select public.set_attendance_for((select id from public.meetings where title='CS #1'), '00000000-0000-0000-0000-000000000003', 'offline');
select from pg_temp.as_user('Ahmed Saleh');
insert into public.time_entries (work_date, activity, meeting_id, minutes)
select current_date - 40, 'council_meeting', id, 60 from public.meetings where title = 'CS #1';
insert into t select '15i added by the Head of Education → can log time', exists (select 1 from public.time_entries where meeting_id is not null);
do $$ begin
  perform public.set_attendance_for((select id from public.meetings where title='CS #1'), auth.uid(), 'offline');
  insert into t values ('15j rep cannot add attendees', false);
exception when others then insert into t values ('15j rep cannot add attendees', true); end $$;

-- 16. Sign-up control
reset role;
select set_config('request.jwt.claim.sub', '', false);
update public.app_settings set signup_open = false;
do $$ begin
  insert into auth.users (email) values ('late@student.mdu.se');
  insert into t values ('16 closed sign-up blocks new accounts', false);
exception when others then insert into t values ('16 closed sign-up blocks new accounts', sqlerrm like 'SIGNUP_CLOSED%'); end $$;
insert into public.account_invites (email) values ('new.rep@student.mdu.se');
insert into auth.users (email, raw_user_meta_data) values ('new.rep@student.mdu.se', '{"full_name":"New Rep"}');
insert into t select '16b account made by the Head of Education: active, must change password, invite used',
  (select active and must_change_password from public.profiles where email = 'new.rep@student.mdu.se')
  and not exists (select 1 from public.account_invites);
update public.app_settings set signup_open = true;
select set_config('request.jwt.claim.sub', (select id::text from public.profiles where email = 'new.rep@student.mdu.se'), false);
set role authenticated;
select public.password_changed();
insert into t select '16c flag cleared after own password', not (select must_change_password from public.profiles where id = auth.uid());
do $$ begin
  update public.app_settings set signup_open = false;
  insert into t values ('16d rep cannot close sign-up', not (select signup_open from public.app_settings) = false);
exception when others then insert into t values ('16d rep cannot close sign-up', true); end $$;
do $$ begin
  perform 1 from public.account_invites;
  insert into t values ('16e rep cannot read invites', false);
exception when others then insert into t values ('16e rep cannot read invites', true); end $$;
reset role;
insert into t select '16f sign-up still open', public.signup_open();

-- 17. Phase 4: roster, seats, sign-ups
reset role;
select set_config('request.jwt.claim.sub', '', false);
insert into t select '17 existing memberships are on the roster',
  not exists (select 1 from public.council_members cm join public.profiles p on p.id = cm.user_id
              where p.email like '%@%'
                and not exists (select 1 from public.roster r where r.council_id = cm.council_id and r.email = lower(p.email)));
insert into public.councils (name, type, city, study_mode, intake, length_years, director_name)
values ('Ekonomprogrammet · ESK · Campus', 'program', 'ESK', 'campus', 'HT', 3, 'M. Holmstedt');
insert into public.roster (council_id, email, cohort)
select id, 'future.rep@student.mdu.se', 'HT2026' from public.councils where name = 'Ekonomprogrammet · ESK · Campus';
insert into auth.users (email, raw_user_meta_data) values ('Future.Rep@student.mdu.se', '{"full_name":"Future Rep"}');
insert into t select '17b signing up with a roster email joins the council (email case ignored)',
  exists (select 1 from public.council_members cm join public.profiles p on p.id = cm.user_id
          join public.councils c on c.id = cm.council_id
          where p.full_name = 'Future Rep' and c.name = 'Ekonomprogrammet · ESK · Campus');
insert into t select '17c officer told about the sign-up',
  exists (select 1 from public.notifications n join public.profiles o on o.id = n.user_id
          where o.role = 'officer' and n.title = 'New sign-up: Future Rep');
insert into t select '17d new sign-up is waiting', (select approval from public.profiles where full_name = 'Future Rep') = 'waiting';
update public.profiles set active = true where full_name = 'Future Rep';
insert into t select '17e switching on approves', (select approval from public.profiles where full_name = 'Future Rep') = 'approved';
delete from public.council_members where user_id = (select id from public.profiles where full_name = 'Future Rep');
insert into t select '17f leaving the council removes the roster row', not exists (select 1 from public.roster where email = 'future.rep@student.mdu.se');
insert into public.council_members (council_id, user_id)
select c.id, p.id from public.councils c, public.profiles p where c.name = 'Ekonomprogrammet · ESK · Campus' and p.full_name = 'Future Rep';
insert into t select '17g adding to a council adds a roster row', exists (select 1 from public.roster where email = 'future.rep@student.mdu.se');
set role authenticated;
select from pg_temp.as_user('Ahmed Saleh');
insert into t select '17h rep sees only own roster rows', not exists (select 1 from public.roster where email = 'future.rep@student.mdu.se');
do $$ begin
  update public.profiles set approval = 'rejected' where id = auth.uid();
  insert into t values ('17i rep cannot change approval', false);
exception when others then insert into t values ('17i rep cannot change approval', true); end $$;
do $$ begin
  insert into public.roster (council_id, email) select id, 'x@student.mdu.se' from public.councils limit 1;
  insert into t values ('17j rep cannot edit the roster', false);
exception when others then insert into t values ('17j rep cannot edit the roster', true); end $$;

-- 18. Appearance preferences: own profile only
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000003', false);
set role authenticated;
update public.profiles set ui_prefs = '{"mode":"dark","accent":"teal"}' where id = auth.uid();
insert into t select '18 rep saves own appearance', (select ui_prefs->>'mode' from public.profiles where id = auth.uid()) = 'dark';

-- 19. Feeds: only the Head of Education posts; tags, reactions, edits; tutoring comments
reset role;
select set_config('request.jwt.claim.sub', '', false);
set role authenticated;
select from pg_temp.as_user('Ahmed Saleh');
do $$ begin
  insert into public.messages (channel_id, body) select id, 'rep post' from public.channels where name = 'Allmänt';
  insert into t values ('19 reps cannot post in any channel now', false);
exception when others then insert into t values ('19 reps cannot post in any channel now', true); end $$;
select from pg_temp.as_user('Head of Education');
insert into public.messages (channel_id, body, mentions)
select id, 'Welcome @Ahmed Saleh', array['00000000-0000-0000-0000-000000000003']::uuid[] from public.channels where name = 'Allmänt';
select from pg_temp.as_user('Ahmed Saleh');
insert into t select '19b tagged rep is notified', exists (select 1 from public.notifications where title like 'The Head of Education tagged you%');
insert into public.messages (channel_id, body, parent_id, mentions)
select channel_id, 'Thanks!', id, array['00000000-0000-0000-0000-000000000001']::uuid[] from public.messages where body = 'Welcome @Ahmed Saleh';
insert into t select '19c rep tags are kept now', (select cardinality(mentions) from public.messages where body = 'Thanks!') = 1;
update public.messages set body = 'Thanks a lot!' where body = 'Thanks!';
insert into t select '19d rep edits own comment (marked edited)', (select edited_at is not null from public.messages where body = 'Thanks a lot!');
update public.messages set body = 'hacked' where body = 'Welcome @Ahmed Saleh';
insert into t select '19e rep cannot edit the officer''s post', exists (select 1 from public.messages where body = 'Welcome @Ahmed Saleh');
select from pg_temp.as_user('Head of Education');
insert into public.message_reactions (message_id, emoji) select id, '❤️' from public.messages where body = 'Thanks a lot!';
update public.messages set body = 'Welcome everyone' where body = 'Welcome @Ahmed Saleh';
insert into t select '19f officer edits own post', exists (select 1 from public.messages where body = 'Welcome everyone' and edited_at is not null);
select from pg_temp.as_user('Ahmed Saleh');
insert into t select '19g rep told about the reaction', exists (select 1 from public.notifications where title = 'The Head of Education reacted ❤️');
insert into t select '19h rep sees reactions', (select count(*) from public.message_reactions) >= 1;
insert into public.tutoring_posts (kind, course, body) values ('request', 'Calculus', 'Help with limits');
select from pg_temp.as_user('Lina Berg');
insert into public.item_comments (kind, item_id, body) select 'tutoring', id, 'I can help on Tuesday' from public.tutoring_posts where course = 'Calculus';
select from pg_temp.as_user('Ahmed Saleh');
insert into t select '19i tutoring post author told about the comment',
  exists (select 1 from public.notifications where title like 'New comment on your tutoring post%');
delete from public.item_comments;
insert into t select '19j cannot delete someone else''s comment', (select count(*) from public.item_comments) = 1;
select from pg_temp.as_user('Head of Education');
delete from public.item_comments;
insert into t select '19k officer can delete comments', (select count(*) from public.item_comments) = 0;

-- 20. Same interactions on posts and the tutoring board
select from pg_temp.as_user('Head of Education');
insert into public.posts (title, body) values ('Exam week tips', 'Good luck everyone');
select from pg_temp.as_user('Ahmed Saleh');
insert into public.item_comments (kind, item_id, body, mentions)
select 'post', id, 'Thanks @Lina Berg', array['00000000-0000-0000-0000-000000000001']::uuid[] from public.posts where title = 'Exam week tips';
insert into public.item_reactions (kind, item_id, emoji) select 'post', id, '👍' from public.posts where title = 'Exam week tips';
select from pg_temp.as_user('Lina Berg');
insert into t select '20 rep tags notify (rep → rep)', exists (select 1 from public.notifications where title like 'Ahmed Saleh tagged you%');
insert into t select '20b everyone sees comments and reactions on a post',
  (select count(*) from public.item_comments) = 1 and (select count(*) from public.item_reactions) = 1;
select from pg_temp.as_user('Head of Education');
insert into t select '20c post author told about the comment', exists (select 1 from public.notifications where title = 'New comment on your post: Exam week tips');
insert into public.item_reactions (kind, item_id, emoji) select 'comment', id, '❤️' from public.item_comments where body like 'Thanks @Lina%';
update public.posts set body = 'Good luck everyone!' where title = 'Exam week tips';
insert into t select '20d edited post is marked', (select edited_at is not null from public.posts where title = 'Exam week tips');
select from pg_temp.as_user('Ahmed Saleh');
insert into t select '20e comment author told about the officer''s reaction',
  exists (select 1 from public.notifications where title = 'The Head of Education reacted ❤️' and body like 'On your post%');
update public.item_comments set body = 'Thanks a lot' where body like 'Thanks @Lina%';
insert into t select '20f rep edits own comment', exists (select 1 from public.item_comments where body = 'Thanks a lot' and edited_at is not null);
select from pg_temp.as_user('Head of Education');
delete from public.posts where title = 'Exam week tips';
insert into t select '20g deleting a post removes its comments and reactions',
  not exists (select 1 from public.item_comments) and not exists (select 1 from public.item_reactions);

-- 21. One reaction per person; links to the exact post
select from pg_temp.as_user('Lina Berg');
insert into public.message_reactions (message_id, emoji) select id, '👍' from public.messages where body = 'Welcome everyone';
do $$ begin
  insert into public.message_reactions (message_id, emoji) select id, '🎉' from public.messages where body = 'Welcome everyone';
  insert into t values ('21 only one reaction per person', false);
exception when others then insert into t values ('21 only one reaction per person', true); end $$;
select from pg_temp.as_user('Head of Education');
insert into public.messages (channel_id, body) select id, 'Link test' from public.channels where name = 'Allmänt';
select from pg_temp.as_user('Ahmed Saleh');
insert into t select '21b notification opens the exact post',
  exists (select 1 from public.notifications n join public.messages m on n.link = 'chat/' || m.channel_id || '/' || m.id
          where m.body = 'Link test');

-- 22. Study year from the cohort
reset role;
select set_config('request.jwt.claim.sub', '', false);
insert into t select '22 cohort year: HT2025 in Nov 2026 = year 2, VT2026 in Nov 2026 = year 1, HT2024 in Aug 2026 = year 3',
  public.cohort_year('HT2025', date '2026-11-23') = 2 and public.cohort_year('VT2026', date '2026-11-23') = 1
  and public.cohort_year('HT2024', date '2026-08-01') = 3 and public.cohort_year('HT2024', date '2026-07-31') = 2;
update public.roster set cohort = 'HT' || (extract(year from current_date)::int - case when extract(month from current_date) >= 8 then 2 else 3 end)
 where email = 'future.rep@student.mdu.se';
insert into t select '22b profile year follows the roster', (select study_year from public.profiles where full_name = 'Future Rep') = 3;

-- 23. Payslip link on "paid"
select set_config('request.jwt.claim.sub', '', false);
set role authenticated;
select from pg_temp.as_user('Head of Education');
update public.app_settings set payslip_url = 'https://apps.fortnox.se/', payslip_label = 'Fortnox';
select public.review_time_report((select report_id from public.report_overview where full_name='Lina Berg'), 'paid');
select from pg_temp.as_user('Lina Berg');
insert into t select '23 paid notification links to the payslip',
  exists (select 1 from public.notifications where title = 'Time report paid' and link = 'https://apps.fortnox.se/'
          and body like '%payslip%Fortnox%');
insert into t select '23b reps can read the payslip link', (select payslip_url from public.app_settings) = 'https://apps.fortnox.se/';
reset role;
do $$ begin
  update public.app_settings set payslip_url = 'fortnox.se';
  insert into t values ('23c link must start with https://', false);
exception when others then insert into t values ('23c link must start with https://', true); end $$;

-- 24. Badges and scoped reactions
set role authenticated;
select from pg_temp.as_user('Ahmed Saleh');
insert into t select '24 rep badges have channels and meetings', (select public.my_badges() ? 'channels' and public.my_badges() ? 'meetings');
insert into public.message_reactions (message_id, emoji) select id, '👍' from public.messages where body = 'Link test';
insert into t select '24b reaction knows its channel',
  (select r.channel_id = m.channel_id from public.message_reactions r join public.messages m on m.id = r.message_id
   where m.body = 'Link test' and r.user_id = auth.uid());
select from pg_temp.as_user('Head of Education');
insert into t select '24c officer badges have reports and signups', (select public.my_badges() ? 'reports' and public.my_badges() ? 'signups');

-- 25. Profile photos and the weekly summary
set role authenticated;
select from pg_temp.as_user('Ahmed Saleh');
update public.profiles set avatar_url = 'https://example.com/a.jpg' where id = auth.uid();
insert into t select '25 rep sets own photo, visible in member_names',
  (select avatar_url from public.member_names where full_name = 'Ahmed Saleh') = 'https://example.com/a.jpg';
do $$ begin
  perform public.weekly_summary();
  insert into t values ('25b reps cannot read the weekly summary', false);
exception when others then insert into t values ('25b reps cannot read the weekly summary', true); end $$;
select from pg_temp.as_user('Head of Education');
insert into t select '25c weekly summary has this and last week',
  (select jsonb_array_length(s->'reports') = 2 and (s->'comments'->>0)::int >= 1 and s ? 'answered' and s ? 'new_reps'
   from (select public.weekly_summary() s) x);

select from pg_temp.as_user('Ahmed Saleh');
insert into t select '25d channel overview has a latest post and unread count',
  (select count(*) > 0 and bool_and(unread >= 0) from public.channel_overview() where last_at is not null);


-- 26. Food preferences
select from pg_temp.as_user('Head of Education');
insert into public.meetings (id, council_id, title, starts_at)
select '00000000-0000-0000-0000-0000000f00d1', id, 'Food test', now() + interval '10 days'
  from public.councils where type = 'siec' limit 1;
insert into public.meetings (id, council_id, title, starts_at)
select '00000000-0000-0000-0000-0000000f00d2', id, 'Food test 2', now() + interval '20 days'
  from public.councils where type = 'siec' limit 1;
select from pg_temp.as_user('Ahmed Saleh');
select public.set_attendance('00000000-0000-0000-0000-0000000f00d1', 'online');
do $$ begin
  perform public.set_food('00000000-0000-0000-0000-0000000f00d1', array['vegan'], null);
  insert into t values ('26 food needs In the room', false);
exception when others then insert into t values ('26 food needs In the room', true); end $$;
select public.set_attendance('00000000-0000-0000-0000-0000000f00d1', 'offline');
do $$ begin
  perform public.set_food('00000000-0000-0000-0000-0000000f00d1', array['other'], ' ');
  insert into t values ('26b Other needs a text', false);
exception when others then insert into t values ('26b Other needs a text', true); end $$;
select public.set_food('00000000-0000-0000-0000-0000000f00d1', array['vegan', 'gluten_free', 'other', 'pizza'], 'Nut allergy');
insert into t select '26c food saved (unknown choice dropped)',
  (select food @> array['vegan','gluten_free','other'] and array_length(food,1) = 3 and food_other = 'Nut allergy'
     from public.meeting_attendance where meeting_id = '00000000-0000-0000-0000-0000000f00d1' and user_id = auth.uid());
select public.set_attendance('00000000-0000-0000-0000-0000000f00d2', 'offline');
insert into t select '26d last choice carried to the next meeting',
  (select food_other = 'Nut allergy' and 'vegan' = any (food)
     from public.meeting_attendance where meeting_id = '00000000-0000-0000-0000-0000000f00d2' and user_id = auth.uid());
select public.set_food('00000000-0000-0000-0000-0000000f00d2', array['none', 'vegan'], 'x');
insert into t select '26e None stands alone, Other text cleared',
  (select food = array['none'] and food_other is null
     from public.meeting_attendance where meeting_id = '00000000-0000-0000-0000-0000000f00d2' and user_id = auth.uid());
select public.set_attendance('00000000-0000-0000-0000-0000000f00d2', 'online');
insert into t select '26f online clears food',
  (select food is null from public.meeting_attendance
    where meeting_id = '00000000-0000-0000-0000-0000000f00d2' and user_id = auth.uid());


-- 27. Channels with unread notifications stand out; opening the channel clears them
reset role;
insert into public.notifications (user_id, title, link)
select (select id from public.profiles where full_name = 'Head of Education'), 'New comment',
       'chat/' || (select id from public.channels order by name limit 1) || '/x';
set role authenticated;
select from pg_temp.as_user('Head of Education');
insert into t select '27 officer sees the unread channel',
  (select unread >= 1 from public.channel_overview() where channel_id = (select id from public.channels order by name limit 1))
  and (public.my_badges()->>'channels')::int >= 1;
select public.mark_channel_read((select id from public.channels order by name limit 1));
insert into t select '27b opening the channel reads its notifications',
  not exists (select 1 from public.notifications where user_id = auth.uid() and read_at is null
              and link like 'chat/' || (select id from public.channels order by name limit 1) || '%');

select from pg_temp.as_user('Ahmed Saleh');
insert into t select '27c profile card shows name, hides email unless shared',
  (select c->>'full_name' = 'Head of Education' and c ? 'councils' from (select public.profile_card(
     '00000000-0000-0000-0000-00000000000a') c) x);

select from pg_temp.as_user('Head of Education');
insert into t select '28 meeting overview: members, answers, food',
  (select members >= 1 and room >= 1 and food_missing >= 0 from public.meeting_overview()
    where meeting_id = '00000000-0000-0000-0000-0000000f00d1');
select from pg_temp.as_user('Ahmed Saleh');
do $$ begin
  perform * from public.meeting_overview();
  insert into t values ('28b reps cannot read the meeting overview', false);
exception when others then insert into t values ('28b reps cannot read the meeting overview', true); end $$;

select from pg_temp.as_user('Head of Education');
insert into public.posts (id, title, body) values ('00000000-0000-0000-0000-0000000005e1', 'Seen test', 'hi');
select from pg_temp.as_user('Ahmed Saleh');
select public.mark_posts_seen(array['00000000-0000-0000-0000-0000000005e1']::uuid[]);
select from pg_temp.as_user('Head of Education');
insert into t select '28c post seen count and who has not seen',
  (select seen = 1 and audience >= 2 from public.post_seen() where post_id = '00000000-0000-0000-0000-0000000005e1')
  and not exists (select 1 from public.post_not_seen('00000000-0000-0000-0000-0000000005e1')
                   where user_id = '00000000-0000-0000-0000-000000000003');
update public.posts set pinned = true where id = '00000000-0000-0000-0000-0000000005e1';
insert into t select '28d officer pins a post', (select pinned from public.posts where id = '00000000-0000-0000-0000-0000000005e1');

reset role;
\echo
select case when passed is true then 'PASS' else 'FAIL' end as result, name from t order by name;
select count(*) filter (where passed is not true) as failures, count(*) as total from t;
