-- =====================================================================
-- MDSU Rep Hub – database schema (Supabase / PostgreSQL 15+)
-- Time reports & pay, channels, agenda, follow-ups, tutoring, automations
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- Types ----------------------------------------------------
create type public.app_role       as enum ('rep', 'officer', 'admin');
create type public.council_type   as enum ('program', 'academy', 'general', 'siec');
create type public.report_status  as enum ('draft', 'submitted', 'returned', 'approved', 'paid');
create type public.issue_status   as enum ('awaiting', 'answered', 'escalated', 'closed');
create type public.agenda_status  as enum ('new', 'included', 'declined');
create type public.tutoring_kind  as enum ('offer', 'request');
-- Only work that counts according to the SR Handbook §11.1
create type public.activity_type  as enum (
  'council_meeting',   -- Council meeting with the university
  'siec_meeting',      -- SIEC meeting
  'preparation',       -- Preparation, reading documents
  'student_input',     -- Gathering student input / student errands
  'class_visit',       -- Class visit
  'teams_email'        -- Teams & email (education related)
);

-- ---------- Helpers that do not depend on tables ---------------------
create or replace function public.local_today() returns date
language sql stable as $$ select (now() at time zone 'Europe/Stockholm')::date $$;

-- 130 SEK/hour = 65 SEK per *started* half hour, only for union members (Handbook §11)
create or replace function public.pay_amount(p_minutes int, p_member boolean, p_half_rate int)
returns int language sql immutable as $$
  select case when coalesce(p_member, false) and coalesce(p_minutes, 0) > 0
              then ceil(p_minutes / 30.0)::int * p_half_rate
              else 0 end
$$;

-- ---------- Tables ----------------------------------------------------
create table public.semesters (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,                      -- e.g. 'Autumn 2026'
  starts_on        date not null,
  ends_on          date not null,
  report_deadline  date not null,                      -- e.g. 17 January
  reminder_date    date,                               -- e.g. 20 December
  hourly_rate      int  not null default 130,
  half_hour_rate   int  not null default 65,
  escalate_after   int  not null default 2,            -- meetings without answer before escalation
  agenda_call_days int  not null default 7,            -- ask reps for input N days before a meeting
  agenda_deadline_days int not null default 2,         -- last day to send items: N days before the meeting
  is_current       boolean not null default false,
  created_at       timestamptz not null default now()
);
create unique index semesters_one_current on public.semesters (is_current) where is_current;

create table public.profiles (
  id             uuid primary key references auth.users (id) on delete cascade,
  full_name      text not null default '',
  email          text,
  role           public.app_role not null default 'rep',
  program        text,
  academy        text check (academy in ('EST', 'HVV', 'IDT', 'UKK')),
  study_year     int  check (study_year between 1 and 6),
  is_member      boolean not null default false,       -- union member → gets paid
  quiz_passed    boolean not null default false,       -- ≥80 % this semester
  share_contact  boolean not null default false,       -- visible in rep directory
  active         boolean not null default false,    -- new sign-ups wait for the officer's approval
  created_at     timestamptz not null default now()
);

-- Personal number kept apart from the profile; only the owner and the officer can read it
create table public.private_details (
  user_id          uuid primary key references public.profiles (id) on delete cascade,
  personal_number  text not null check (personal_number ~ '^[0-9]{6,8}-?[0-9]{4}$'),
  updated_at       timestamptz not null default now()
);

create table public.councils (
  id       uuid primary key default gen_random_uuid(),
  name     text not null unique,
  type     public.council_type not null,
  academy  text check (academy in ('EST', 'HVV', 'IDT', 'UKK'))
);

create table public.council_members (
  council_id uuid references public.councils (id) on delete cascade,
  user_id    uuid references public.profiles (id) on delete cascade,
  primary key (council_id, user_id)
);

create table public.meetings (
  id               uuid primary key default gen_random_uuid(),
  council_id       uuid not null references public.councils (id) on delete cascade,
  title            text not null,
  starts_at        timestamptz not null,
  location         text,
  input_deadline   date,
  input_requested  boolean not null default false,
  created_at       timestamptz not null default now()
);
create index on public.meetings (council_id, starts_at);

-- Input deadline defaults to N days before the meeting (semester setting)
create or replace function public.meeting_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.input_deadline is null then
    new.input_deadline := (new.starts_at at time zone 'Europe/Stockholm')::date
      - coalesce((select agenda_deadline_days from public.semesters where is_current), 2);
  end if;
  return new;
end $$;
create trigger meetings_defaults before insert on public.meetings
  for each row execute function public.meeting_defaults();

create or replace function public.current_semester_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.semesters where is_current limit 1
$$;

create table public.time_entries (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  semester_id  uuid not null default public.current_semester_id() references public.semesters (id),
  work_date    date not null,
  activity     public.activity_type not null,
  council_id   uuid references public.councils (id),
  meeting_id   uuid references public.meetings (id) on delete set null,
  minutes      int  not null check (minutes > 0 and minutes <= 720),
  description  text not null default '',
  created_at   timestamptz not null default now()
);
create index on public.time_entries (user_id, semester_id);

create table public.attachments (
  id            uuid primary key default gen_random_uuid(),
  entry_id      uuid not null references public.time_entries (id) on delete cascade,
  storage_path  text not null,                         -- path in bucket 'meeting-notes'
  file_name     text not null,
  uploaded_by   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at    timestamptz not null default now()
);

create table public.time_reports (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  semester_id       uuid not null references public.semesters (id),
  status            public.report_status not null default 'draft',
  submitted_at      timestamptz,
  is_late           boolean not null default false,
  reviewed_at       timestamptz,
  reviewed_by       uuid references public.profiles (id),
  reviewer_comment  text,
  approved_minutes  int,          -- snapshot at approval, so later rate changes do not alter pay
  approved_amount   int,
  unique (user_id, semester_id)
);

create table public.agenda_items (
  id             uuid primary key default gen_random_uuid(),
  meeting_id     uuid not null references public.meetings (id) on delete cascade,
  user_id        uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  title          text not null,
  details        text not null default '',
  source         text not null default 'Talking to students',
  student_count  int  not null default 1 check (student_count > 0),
  status         public.agenda_status not null default 'new',
  created_at     timestamptz not null default now()
);

create table public.issues (
  id                 uuid primary key default gen_random_uuid(),
  council_id         uuid not null references public.councils (id) on delete cascade,
  raised_at_meeting  uuid references public.meetings (id) on delete set null,
  raised_by          uuid not null default auth.uid() references public.profiles (id),
  title              text not null,
  details            text not null default '',
  responsible        text,                             -- who at the university owes an answer
  status             public.issue_status not null default 'awaiting',
  response           text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create table public.issue_events (
  id        bigint generated always as identity primary key,
  issue_id  uuid not null references public.issues (id) on delete cascade,
  at        timestamptz not null default now(),
  actor     uuid references public.profiles (id),
  event     text not null
);

create table public.channels (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  description   text not null default '',
  audience      text not null default 'all' check (audience in ('all', 'EST', 'HVV', 'IDT', 'UKK')),
  officer_only  boolean not null default false,       -- only the officer can post (announcements)
  created_at    timestamptz not null default now()
);

create table public.messages (
  id               uuid primary key default gen_random_uuid(),
  channel_id       uuid not null references public.channels (id) on delete cascade,
  author_id        uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body             text not null check (length(body) between 1 and 4000),
  is_announcement  boolean not null default false,
  created_at       timestamptz not null default now()
);
create index on public.messages (channel_id, created_at);

create table public.message_reads (
  message_id  uuid references public.messages (id) on delete cascade,
  user_id     uuid references public.profiles (id) on delete cascade,
  read_at     timestamptz not null default now(),
  primary key (message_id, user_id)
);

create table public.tutoring_posts (
  id          uuid primary key default gen_random_uuid(),
  kind        public.tutoring_kind not null,
  course      text not null,
  body        text not null default '',
  author_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  hidden      boolean not null default false,
  created_at  timestamptz not null default now()
);

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  title       text not null,
  body        text not null default '',
  link        text,                                    -- in-app route, e.g. 'hours', 'agenda/<id>'
  created_at  timestamptz not null default now(),
  read_at     timestamptz
);
create index on public.notifications (user_id, created_at desc);

create table public.device_tokens (
  token       text primary key,
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  platform    text not null check (platform in ('android', 'ios', 'web', 'macos', 'windows')),
  updated_at  timestamptz not null default now()
);

-- Prevents automations from sending the same message twice
create table public.automation_log (
  key  text primary key,
  at   timestamptz not null default now()
);

-- ---------- Helper functions (security definer) ----------------------
create or replace function public.is_officer() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role in ('officer', 'admin') and active)
$$;

-- Signed in AND approved by the Head of Education
create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active)
$$;

create or replace function public.my_academy() returns text
language sql stable security definer set search_path = public as $$
  select academy from public.profiles where id = auth.uid()
$$;

-- SIEC is for all representatives; other councils only for their members
create or replace function public.in_council(p_council uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_active_user() and (
         exists (select 1 from public.councils c where c.id = p_council and c.type = 'siec')
      or exists (select 1 from public.council_members m
                 where m.council_id = p_council and m.user_id = auth.uid()))
$$;

create or replace function public.council_member_ids(p_council uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  select p.id from public.profiles p
  where p.active and p.role = 'rep'
    and ( exists (select 1 from public.councils c where c.id = p_council and c.type = 'siec')
          or exists (select 1 from public.council_members m where m.council_id = p_council and m.user_id = p.id))
$$;

create or replace function public.notify_user(p_user uuid, p_title text, p_body text default '', p_link text default null)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (user_id, title, body, link) values (p_user, p_title, p_body, p_link)
$$;

create or replace function public.report_locked(p_user uuid, p_semester uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.time_reports r
                 where r.user_id = p_user and r.semester_id = p_semester
                   and r.status in ('submitted', 'approved', 'paid'))
$$;

-- Number of meetings of the same council held after the issue was raised (still unanswered)
create or replace function public.meetings_without_answer(p_issue uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.meetings m
  join public.issues i on i.id = p_issue
  left join public.meetings rm on rm.id = i.raised_at_meeting
  where m.council_id = i.council_id
    and m.starts_at < now()
    and m.starts_at > coalesce(rm.starts_at, i.created_at)
$$;

-- ---------- Triggers --------------------------------------------------
-- New login → profile (name from Microsoft / sign-up metadata)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Reps cannot change protected profile columns themselves
create or replace function public.guard_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() and auth.uid() is not null then
    if new.role <> old.role or new.is_member <> old.is_member or new.quiz_passed <> old.quiz_passed
       or new.active <> old.active or new.email is distinct from old.email then
      raise exception 'Only the Head of Education can change role, membership, quiz or status';
    end if;
  end if;
  return new;
end $$;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.guard_profile();

-- Time entries cannot change once the report is submitted / approved / paid
create or replace function public.guard_time_entry() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  if public.report_locked(r.user_id, r.semester_id) then
    raise exception 'Your time report is already submitted. Ask the Head of Education to return it.';
  end if;
  if tg_op = 'UPDATE' and public.report_locked(old.user_id, old.semester_id) then
    raise exception 'Your time report is already submitted.';
  end if;
  return r;
end $$;
create trigger time_entries_guard before insert or update or delete on public.time_entries
  for each row execute function public.guard_time_entry();

-- Announcement → notification to everyone in the channel audience
create or replace function public.on_message_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare ch record;
begin
  select * into ch from public.channels where id = new.channel_id;
  if ch.officer_only and not exists (select 1 from public.profiles where id = new.author_id and role in ('officer','admin')) then
    raise exception 'Only the Head of Education can post in %', ch.name;
  end if;
  if new.is_announcement then
    if not exists (select 1 from public.profiles where id = new.author_id and role in ('officer','admin')) then
      raise exception 'Only the Head of Education can post announcements';
    end if;
    insert into public.notifications (user_id, title, body, link)
    select p.id, 'New announcement', left(new.body, 140), 'chat/' || new.channel_id
    from public.profiles p
    where p.active and p.role = 'rep' and (ch.audience = 'all' or p.academy = ch.audience);
  end if;
  return new;
end $$;
create trigger messages_before_insert before insert on public.messages
  for each row execute function public.on_message_insert();

-- Agenda status changed → tell the rep
create or replace function public.on_agenda_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status <> old.status and new.status <> 'new' then
    perform public.notify_user(new.user_id,
      case new.status when 'included' then 'Your agenda item was added' else 'Your agenda item was not included' end,
      new.title, 'agenda/' || new.meeting_id);
  end if;
  return new;
end $$;
create trigger agenda_after_update after update on public.agenda_items
  for each row execute function public.on_agenda_update();

-- Issue log + notify council members on every status change
create or replace function public.on_issue_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.issue_events (issue_id, actor, event) values (new.id, auth.uid(), 'Issue logged');
  elsif new.status <> old.status or new.response is distinct from old.response then
    new.updated_at := now();
    insert into public.issue_events (issue_id, actor, event)
    values (new.id, auth.uid(), 'Status: ' || new.status || coalesce(' – ' || left(new.response, 200), ''));
    insert into public.notifications (user_id, title, body, link)
    select uid, 'Follow-up updated: ' || new.title,
           initcap(new.status::text) || coalesce(' – ' || left(new.response, 120), ''), 'followups'
    from public.council_member_ids(new.council_id) uid;
  end if;
  return new;
end $$;
create trigger issues_after_insert after insert on public.issues
  for each row execute function public.on_issue_change();
create trigger issues_before_update before update on public.issues
  for each row execute function public.on_issue_change();

-- ---------- Views -----------------------------------------------------
-- Names everyone may see (authors in channels, agenda lists, tutoring)
create or replace view public.member_names as
  select id, full_name, program, academy, study_year, role from public.profiles
  where active and public.is_active_user();

-- Rep directory: only reps who opted in to share contact details
create or replace view public.rep_directory as
  select id, full_name, program, academy, study_year, email
  from public.profiles where active and role = 'rep' and share_contact and public.is_active_user();

-- One row per rep for the current semester: hours, notes, status, pay
create or replace view public.report_overview with (security_invoker = true) as
  select p.id                                   as user_id,
         p.full_name, p.program, p.academy, p.is_member,
         s.id                                   as semester_id,
         s.name                                 as semester_name,
         coalesce(r.status, 'draft')            as status,
         r.id                                   as report_id,
         r.submitted_at, r.is_late, r.reviewer_comment,
         coalesce(sum(e.minutes), 0)::int       as minutes,
         count(e.id)::int                       as entries,
         count(e.id) filter (where not exists (select 1 from public.attachments a where a.entry_id = e.id))::int
                                                as entries_without_notes,
         coalesce(r.approved_amount,
                  public.pay_amount(coalesce(sum(e.minutes), 0)::int, p.is_member, s.half_hour_rate))
                                                as amount,
         exists (select 1 from public.private_details d where d.user_id = p.id) as has_personal_number
  from public.profiles p
  cross join public.semesters s
  left join public.time_reports r on r.user_id = p.id and r.semester_id = s.id
  left join public.time_entries e on e.user_id = p.id and e.semester_id = s.id
  where s.is_current and p.role = 'rep' and p.active
    and (p.id = auth.uid() or public.is_officer())
  group by p.id, s.id, r.id;

-- ---------- RPC functions (called from the app) ----------------------
-- Rep presses "Submit"
create or replace function public.submit_time_report() returns public.time_reports
language plpgsql security definer set search_path = public as $$
declare s public.semesters; rep public.time_reports; n int;
begin
  if not public.is_active_user() then raise exception 'Your account is not activated yet'; end if;
  select * into s from public.semesters where is_current;
  if s.id is null then raise exception 'No active semester'; end if;
  select count(*) into n from public.time_entries where user_id = auth.uid() and semester_id = s.id;
  if n = 0 then raise exception 'Log at least one activity before submitting'; end if;

  insert into public.time_reports (user_id, semester_id) values (auth.uid(), s.id)
  on conflict (user_id, semester_id) do nothing;

  update public.time_reports
     set status = 'submitted', submitted_at = now(), reviewer_comment = null,
         is_late = public.local_today() > s.report_deadline
   where user_id = auth.uid() and semester_id = s.id and status in ('draft', 'returned')
  returning * into rep;
  if rep.id is null then raise exception 'Report is already submitted'; end if;

  insert into public.notifications (user_id, title, body, link)
  select p.id, 'Time report submitted', (select full_name from public.profiles where id = auth.uid()), 'reports'
  from public.profiles p where p.role in ('officer', 'admin') and p.active;
  return rep;
end $$;

-- Officer: approve / return / mark paid
create or replace function public.review_time_report(p_report uuid, p_action text, p_comment text default null)
returns public.time_reports
language plpgsql security definer set search_path = public as $$
declare rep public.time_reports; mins int; amt int;
begin
  if not public.is_officer() then raise exception 'Only the Head of Education can review reports'; end if;
  select * into rep from public.time_reports where id = p_report for update;
  if rep.id is null then raise exception 'Report not found'; end if;

  if p_action = 'approve' then
    if rep.status <> 'submitted' then raise exception 'Only submitted reports can be approved'; end if;
    select coalesce(sum(minutes), 0) into mins from public.time_entries
     where user_id = rep.user_id and semester_id = rep.semester_id;
    select public.pay_amount(mins, p.is_member, s.half_hour_rate) into amt
      from public.profiles p, public.semesters s where p.id = rep.user_id and s.id = rep.semester_id;
    update public.time_reports set status = 'approved', approved_minutes = mins, approved_amount = amt,
           reviewed_at = now(), reviewed_by = auth.uid(), reviewer_comment = p_comment
     where id = p_report returning * into rep;
    perform public.notify_user(rep.user_id, 'Time report approved', amt || ' SEK will be paid out', 'hours');
  elsif p_action = 'return' then
    if rep.status <> 'submitted' then raise exception 'Only submitted reports can be returned'; end if;
    update public.time_reports set status = 'returned', reviewed_at = now(), reviewed_by = auth.uid(),
           reviewer_comment = coalesce(p_comment, 'Please check your report')
     where id = p_report returning * into rep;
    perform public.notify_user(rep.user_id, 'Time report returned', rep.reviewer_comment, 'hours');
  elsif p_action = 'paid' then
    if rep.status <> 'approved' then raise exception 'Only approved reports can be marked as paid'; end if;
    update public.time_reports set status = 'paid' where id = p_report returning * into rep;
    perform public.notify_user(rep.user_id, 'Time report paid', rep.approved_amount || ' SEK', 'hours');
  else
    raise exception 'Unknown action %', p_action;
  end if;
  return rep;
end $$;

-- Officer: remind everyone who has not submitted
create or replace function public.remind_unsubmitted() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_officer() and auth.uid() is not null then raise exception 'Not allowed'; end if;
  with targets as (
    select p.id as user_id,
           coalesce((select sum(e.minutes) from public.time_entries e
                     where e.user_id = p.id and e.semester_id = s.id), 0) as minutes
    from public.profiles p cross join public.semesters s
    left join public.time_reports r on r.user_id = p.id and r.semester_id = s.id
    where s.is_current and p.role = 'rep' and p.active
      and coalesce(r.status, 'draft') in ('draft', 'returned')
  ), ins as (
    insert into public.notifications (user_id, title, body, link)
    select t.user_id, 'Submit your time report',
           'Deadline ' || to_char((select report_deadline from public.semesters where is_current), 'DD Mon') ||
           '. You have ' || round(t.minutes / 60.0, 1) || ' h logged.', 'hours'
    from targets t returning 1)
  select count(*) into n from ins;
  return n;
end $$;

-- Officer: ask council members for agenda input
create or replace function public.request_agenda_input(p_meeting uuid) returns int
language plpgsql security definer set search_path = public as $$
declare m public.meetings; n int;
begin
  if not public.is_officer() and auth.uid() is not null then raise exception 'Not allowed'; end if;
  select * into m from public.meetings where id = p_meeting;
  update public.meetings set input_requested = true where id = p_meeting;
  insert into public.notifications (user_id, title, body, link)
  select uid, 'Send agenda items: ' || m.title,
         'Meeting ' || to_char(m.starts_at at time zone 'Europe/Stockholm', 'DD Mon') ||
         coalesce('. Send your items by ' || to_char(m.input_deadline, 'DD Mon'), '') ||
         '. Ask your classmates for input now!', 'agenda/' || m.id
  from public.council_member_ids(m.council_id) uid;
  get diagnostics n = row_count;
  return n;
end $$;

-- Open issues that must be answered at a meeting (auto carry-forward)
create or replace function public.open_issues_for_meeting(p_meeting uuid)
returns table (id uuid, title text, details text, responsible text, status public.issue_status,
               raised_on timestamptz, raised_by_name text, meetings_without_answer int)
language sql stable security definer set search_path = public as $$
  select i.id, i.title, i.details, i.responsible, i.status,
         coalesce(rm.starts_at, i.created_at), p.full_name, public.meetings_without_answer(i.id)
  from public.meetings m
  join public.issues i on i.council_id = m.council_id and i.status in ('awaiting', 'escalated')
  left join public.meetings rm on rm.id = i.raised_at_meeting
  left join public.profiles p on p.id = i.raised_by
  where m.id = p_meeting
    and coalesce(rm.starts_at, i.created_at) < m.starts_at
    and (public.is_officer() or public.in_council(m.council_id))
  order by 6
$$;

-- Officer or a council member records the university's answer
create or replace function public.set_issue_status(p_issue uuid, p_status public.issue_status, p_response text default null)
returns public.issues
language plpgsql security definer set search_path = public as $$
declare i public.issues;
begin
  select * into i from public.issues where id = p_issue;
  if i.id is null then raise exception 'Issue not found'; end if;
  if not (public.is_officer() or public.in_council(i.council_id)) then raise exception 'Not allowed'; end if;
  if p_status in ('escalated', 'closed') and not public.is_officer() then
    raise exception 'Only the Head of Education can escalate or close issues';
  end if;
  update public.issues set status = p_status, response = coalesce(p_response, response)
   where id = p_issue returning * into i;
  return i;
end $$;

-- Phone token for push notifications. A phone can move between accounts (sign out / sign in),
-- so the token is always re-assigned to the current user.
create or replace function public.register_device(p_token text, p_platform text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_active_user() then raise exception 'Your account is not activated yet'; end if;
  insert into public.device_tokens (token, user_id, platform, updated_at)
  values (p_token, auth.uid(), p_platform, now())
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
end $$;

create or replace function public.mark_message_read(p_message uuid) returns void
language sql security definer set search_path = public as $$
  insert into public.message_reads (message_id, user_id) values (p_message, auth.uid())
  on conflict do nothing
$$;

-- Officer: who has read an announcement
create or replace function public.announcement_reads(p_message uuid)
returns table (user_id uuid, full_name text, read_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, p.full_name, r.read_at
  from public.messages m
  join public.channels c on c.id = m.channel_id
  join public.profiles p on p.active and p.role = 'rep' and (c.audience = 'all' or p.academy = c.audience)
  left join public.message_reads r on r.message_id = m.id and r.user_id = p.id
  where m.id = p_message and public.is_officer()
  order by r.read_at nulls first, p.full_name
$$;

-- Officer: payroll rows (download as .xlsx in the app)
create or replace function public.payroll_export()
returns table (full_name text, personal_number text, program text, is_member boolean, status public.report_status,
               hours numeric, started_half_hours int, amount int)
language sql stable security definer set search_path = public as $$
  select o.full_name, d.personal_number, o.program, o.is_member, o.status,
         round(o.minutes / 60.0, 2), ceil(o.minutes / 30.0)::int, o.amount
  from public.report_overview o
  left join public.private_details d on d.user_id = o.user_id
  where public.is_officer() and o.status in ('submitted', 'approved', 'paid')
  order by o.full_name
$$;

-- Officer: start a new semester (old data stays, linked to the old semester)
create or replace function public.start_new_semester(p_name text, p_starts date, p_ends date,
                                                     p_deadline date, p_reminder date)
returns public.semesters
language plpgsql security definer set search_path = public as $$
declare old public.semesters; s public.semesters;
begin
  if not public.is_officer() then raise exception 'Not allowed'; end if;
  select * into old from public.semesters where is_current;
  update public.semesters set is_current = false where is_current;
  insert into public.semesters (name, starts_on, ends_on, report_deadline, reminder_date, hourly_rate,
                                half_hour_rate, escalate_after, agenda_call_days, agenda_deadline_days, is_current)
  values (p_name, p_starts, p_ends, p_deadline, p_reminder,
          coalesce(old.hourly_rate, 130), coalesce(old.half_hour_rate, 65),
          coalesce(old.escalate_after, 2), coalesce(old.agenda_call_days, 7),
          coalesce(old.agenda_deadline_days, 2), true)
  returning * into s;
  update public.profiles set quiz_passed = false where role = 'rep';
  insert into public.notifications (user_id, title, body, link)
  select id, 'New semester: ' || p_name, 'Please redo the SR quiz (at least 80 %) to stay appointed.', 'more'
  from public.profiles where role = 'rep' and active;
  return s;
end $$;

-- ---------- Automations (run daily, see pg_cron below) --------------
create or replace function public.run_automations() returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.semesters; m record; i record; u record;
        today date := public.local_today();
        out jsonb := '{"agenda_calls":0,"time_prompts":0,"escalated":0,"reminders":0}'::jsonb;
        n int;
begin
  if auth.uid() is not null and not public.is_officer() then raise exception 'Not allowed'; end if;
  select * into s from public.semesters where is_current;
  if s.id is null then return out; end if;

  -- 1) Ask for agenda input N days before each meeting
  for m in select * from public.meetings
           where not input_requested
             and (starts_at at time zone 'Europe/Stockholm')::date between today and today + s.agenda_call_days loop
    perform public.request_agenda_input(m.id);
    out := jsonb_set(out, '{agenda_calls}', to_jsonb((out->>'agenda_calls')::int + 1));
  end loop;

  -- 2) Day after a meeting: prompt every member who has not logged time for it
  for m in select * from public.meetings
           where (starts_at at time zone 'Europe/Stockholm')::date between today - 3 and today - 1 loop
    for u in select uid from public.council_member_ids(m.council_id) uid
             where not exists (select 1 from public.time_entries e where e.user_id = uid and e.meeting_id = m.id) loop
      insert into public.automation_log (key) values ('log:' || m.id || ':' || u.uid) on conflict do nothing;
      get diagnostics n = row_count;
      if n = 1 then
        perform public.notify_user(u.uid, 'Log your hours for ' || m.title,
                                   'Add the meeting and upload your notes.', 'log/' || m.id);
        out := jsonb_set(out, '{time_prompts}', to_jsonb((out->>'time_prompts')::int + 1));
      end if;
    end loop;
  end loop;

  -- 3) Escalate issues without answer after N meetings
  for i in select * from public.issues where status = 'awaiting' loop
    if public.meetings_without_answer(i.id) >= s.escalate_after then
      update public.issues set status = 'escalated',
             response = coalesce(response, '') || case when response is null then '' else E'\n' end ||
                        'Auto-escalated: no answer after ' || s.escalate_after || ' meetings'
       where id = i.id;
      out := jsonb_set(out, '{escalated}', to_jsonb((out->>'escalated')::int + 1));
    end if;
  end loop;

  -- 4) Deadline reminders: on reminder date and 3 days before the deadline
  if today in (s.reminder_date, s.report_deadline - 3) then
    insert into public.automation_log (key) values ('remind:' || s.id || ':' || today) on conflict do nothing;
    get diagnostics n = row_count;
    if n = 1 then
      out := jsonb_set(out, '{reminders}', to_jsonb(public.remind_unsubmitted()));
    end if;
  end if;
  return out;
end $$;

-- =====================================================================
-- Row Level Security
-- =====================================================================
alter table public.semesters        enable row level security;
alter table public.profiles         enable row level security;
alter table public.private_details  enable row level security;
alter table public.councils         enable row level security;
alter table public.council_members  enable row level security;
alter table public.meetings         enable row level security;
alter table public.time_entries     enable row level security;
alter table public.attachments      enable row level security;
alter table public.time_reports     enable row level security;
alter table public.agenda_items     enable row level security;
alter table public.issues           enable row level security;
alter table public.issue_events     enable row level security;
alter table public.channels         enable row level security;
alter table public.messages         enable row level security;
alter table public.message_reads    enable row level security;
alter table public.tutoring_posts   enable row level security;
alter table public.notifications    enable row level security;
alter table public.device_tokens    enable row level security;
alter table public.automation_log   enable row level security;  -- no policies: server only

-- semesters
create policy sem_read   on public.semesters for select to authenticated using (true);
create policy sem_write  on public.semesters for all    to authenticated using (public.is_officer()) with check (public.is_officer());
-- profiles
create policy prof_read  on public.profiles for select to authenticated using (id = auth.uid() or public.is_officer());
create policy prof_self  on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy prof_off   on public.profiles for all    to authenticated using (public.is_officer()) with check (public.is_officer());
-- private details
create policy pd_self    on public.private_details for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy pd_off     on public.private_details for select to authenticated using (public.is_officer());
-- councils & members
create policy c_read     on public.councils for select to authenticated using (true);
create policy c_write    on public.councils for all to authenticated using (public.is_officer()) with check (public.is_officer());
create policy cm_read    on public.council_members for select to authenticated using (true);
create policy cm_write   on public.council_members for all to authenticated using (public.is_officer()) with check (public.is_officer());
-- meetings
create policy m_read     on public.meetings for select to authenticated using (public.is_officer() or public.in_council(council_id));
create policy m_write    on public.meetings for all to authenticated using (public.is_officer()) with check (public.is_officer());
-- time entries
create policy te_read    on public.time_entries for select to authenticated using (user_id = auth.uid() or public.is_officer());
create policy te_ins     on public.time_entries for insert to authenticated with check (user_id = auth.uid());
create policy te_upd     on public.time_entries for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy te_del     on public.time_entries for delete to authenticated using (user_id = auth.uid());
-- attachments
create policy at_read    on public.attachments for select to authenticated using (uploaded_by = auth.uid() or public.is_officer());
create policy at_ins     on public.attachments for insert to authenticated
  with check (uploaded_by = auth.uid() and exists (select 1 from public.time_entries e where e.id = entry_id and e.user_id = auth.uid()));
create policy at_del     on public.attachments for delete to authenticated using (uploaded_by = auth.uid());
-- time reports: read only; changes go through RPC functions
create policy tr_read    on public.time_reports for select to authenticated using (user_id = auth.uid() or public.is_officer());
-- agenda
create policy ag_read    on public.agenda_items for select to authenticated using (user_id = auth.uid() or public.is_officer());
create policy ag_ins     on public.agenda_items for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from public.meetings m where m.id = meeting_id and public.in_council(m.council_id)));
create policy ag_upd_own on public.agenda_items for update to authenticated using (user_id = auth.uid() and status = 'new') with check (user_id = auth.uid() and status = 'new');
create policy ag_del_own on public.agenda_items for delete to authenticated using (user_id = auth.uid() and status = 'new');
create policy ag_off     on public.agenda_items for update to authenticated using (public.is_officer()) with check (public.is_officer());
-- issues
create policy is_read    on public.issues for select to authenticated using (public.is_officer() or public.in_council(council_id));
create policy is_ins     on public.issues for insert to authenticated
  with check (raised_by = auth.uid() and (public.is_officer() or public.in_council(council_id)) and status = 'awaiting');
create policy is_off     on public.issues for update to authenticated using (public.is_officer()) with check (public.is_officer());
create policy ie_read    on public.issue_events for select to authenticated
  using (exists (select 1 from public.issues i where i.id = issue_id and (public.is_officer() or public.in_council(i.council_id))));
-- channels & messages
create policy ch_read    on public.channels for select to authenticated using (public.is_officer() or audience = 'all' or audience = public.my_academy());
create policy ch_write   on public.channels for all to authenticated using (public.is_officer()) with check (public.is_officer());
create policy msg_read   on public.messages for select to authenticated
  using (exists (select 1 from public.channels c where c.id = channel_id));   -- channel RLS applies inside
create policy msg_ins    on public.messages for insert to authenticated
  with check (author_id = auth.uid() and exists (select 1 from public.channels c where c.id = channel_id));
create policy msg_del    on public.messages for delete to authenticated using (author_id = auth.uid() or public.is_officer());
create policy mr_read    on public.message_reads for select to authenticated using (user_id = auth.uid() or public.is_officer());
create policy mr_ins     on public.message_reads for insert to authenticated with check (user_id = auth.uid());
-- tutoring
create policy tu_read    on public.tutoring_posts for select to authenticated using (not hidden or author_id = auth.uid() or public.is_officer());
create policy tu_ins     on public.tutoring_posts for insert to authenticated with check (author_id = auth.uid() and not hidden);
create policy tu_upd     on public.tutoring_posts for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid() and not hidden);
create policy tu_del     on public.tutoring_posts for delete to authenticated using (author_id = auth.uid() or public.is_officer());
create policy tu_off     on public.tutoring_posts for update to authenticated using (public.is_officer()) with check (public.is_officer());
-- notifications & devices
create policy no_read    on public.notifications for select to authenticated using (user_id = auth.uid());
create policy no_upd     on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy dt_own     on public.device_tokens for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Accounts not yet approved by the officer see nothing except their own profile
do $outer$
declare t text;
begin
  foreach t in array array['semesters','councils','council_members','meetings','time_entries','attachments',
                           'time_reports','agenda_items','issues','issue_events','channels','messages',
                           'message_reads','tutoring_posts','device_tokens'] loop
    execute format('create policy only_active on public.%I as restrictive for all to authenticated
                    using (public.is_active_user()) with check (public.is_active_user())', t);
  end loop;
end $outer$;

-- Grants (Supabase exposes the public schema through PostgREST)
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke all on public.automation_log from authenticated, anon;
grant select on public.member_names, public.rep_directory, public.report_overview to authenticated;
revoke execute on function public.run_automations()            from public, anon;
revoke execute on function public.notify_user(uuid, text, text, text) from public, anon, authenticated;
grant  execute on function public.run_automations()            to authenticated;

-- =====================================================================
-- Storage bucket for meeting notes (only on Supabase)
-- =====================================================================
do $outer$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public) values ('meeting-notes', 'meeting-notes', false)
    on conflict (id) do nothing;
    -- files are stored as <user id>/<entry id>/<file name>
    execute $p$ create policy notes_own on storage.objects for all to authenticated
      using (bucket_id = 'meeting-notes' and (storage.foldername(name))[1] = auth.uid()::text)
      with check (bucket_id = 'meeting-notes' and (storage.foldername(name))[1] = auth.uid()::text) $p$;
    execute $p$ create policy notes_officer on storage.objects for select to authenticated
      using (bucket_id = 'meeting-notes' and public.is_officer()) $p$;
  end if;
end $outer$;

-- Realtime: live updates in the apps (only on Supabase)
do $outer$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.messages, public.notifications,
      public.time_reports, public.agenda_items, public.issues;
  end if;
end $outer$;

-- Daily automations at 07:05 Swedish time (only where pg_cron is available)
do $outer$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('mdsu-daily-automations', '5 6 * * *', 'select public.run_automations()');
  end if;
end $outer$;
