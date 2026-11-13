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
insert into public.time_entries (work_date, activity, council_id, minutes, description)
select current_date - 40, 'council_meeting', id, 60, 'CS #1' from public.councils where name like 'Program council – Computer%';
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
insert into public.messages (channel_id, body) select id, 'Hello all' from public.channels where name = 'Allmänt';
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
insert into t select '9 automations: agenda call 7 days before (CS #3 in 5 days, Nursing in 40 days not yet)', (:'automation_result'::jsonb ->> 'agenda_calls')::int = 1;
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
  (select count(*) from public.meeting_attendance) = 1 and (select mode from public.meeting_attendance) = 'offline';
do $$ begin
  insert into public.meeting_attendance (meeting_id, user_id, mode)
  select id, '00000000-0000-0000-0000-000000000003', 'absent' from public.meetings where title='CS #1';
  insert into t values ('12c rep cannot answer for someone else', false);
exception when others then insert into t values ('12c rep cannot answer for someone else', true); end $$;
select from pg_temp.as_user('Head of Education');
insert into t select '12d officer sees 1 offline + 1 online',
  (select count(*) filter (where mode='offline') = 1 and count(*) filter (where mode='online') = 1
     from public.meeting_attendance where meeting_id = (select id from public.meetings where title='CS #3'));

reset role;
\echo
select case when passed then 'PASS' else 'FAIL' end as result, name from t order by name;
select count(*) filter (where not passed) as failures, count(*) as total from t;
