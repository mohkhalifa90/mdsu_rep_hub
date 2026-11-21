-- Phase 5
-- 1) Channels where only the Head of Education posts (SIEC, SR Resources) work like a feed:
--    her messages are posts, representatives can comment under them.
-- 2) "Seen by" for every message from the Head of Education in every channel.
-- 3) Meetings: a representative says before the meeting if they attend. Only attendees
--    (in the room or online) can log time for a meeting; the Head of Education can add
--    someone afterwards.

-- ---------- 1) Comments ----------
alter table public.messages add column if not exists parent_id uuid references public.messages (id) on delete cascade;
create index if not exists messages_parent_idx on public.messages (parent_id);

create or replace function public.on_message_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare ch record; by_officer boolean; parent record;
begin
  select * into ch from public.channels where id = new.channel_id;
  by_officer := exists (select 1 from public.profiles where id = new.author_id and role in ('officer','admin'));
  if new.is_announcement and not by_officer then
    raise exception 'Only the Head of Education can post announcements';
  end if;

  if new.parent_id is not null then
    -- a comment under a post
    select * into parent from public.messages where id = new.parent_id;
    if parent.id is null or parent.channel_id <> new.channel_id or parent.parent_id is not null then
      raise exception 'You can only comment on a post in the same channel';
    end if;
    new.is_announcement := false;
    if not by_officer then
      insert into public.notifications (user_id, title, body, link)
      select p.id, 'New comment in ' || ch.name, left(coalesce(nullif(new.body, ''), new.file_name, ''), 140),
             'chat/' || new.channel_id
      from public.profiles p where p.active and p.role in ('officer', 'admin') and p.id <> new.author_id;
    end if;
    return new;
  end if;

  if ch.officer_only and not by_officer then
    raise exception 'Only the Head of Education can post in % – you can comment on her posts', ch.name;
  end if;
  if by_officer then
    insert into public.notifications (user_id, title, body, link)
    select p.id,
           case when new.is_announcement then 'New announcement' else 'Head of Education in ' || ch.name end,
           left(coalesce(nullif(new.body, ''), new.file_name, 'New file'), 140),
           'chat/' || new.channel_id
    from public.profiles p
    where p.active and p.role = 'rep' and (ch.audience = 'all' or p.academy = ch.audience);
  end if;
  return new;
end $$;

update public.channels set description = 'Student Influence and Education Committee – posts from the Head of Education, comment below'
 where name = 'SIEC' and description like '%only moderators post here%';

-- ---------- 2) Seen by ----------
-- Opening a channel marks every message from the Head of Education in it as seen.
create or replace function public.mark_channel_read(p_channel uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_active_user() then return 0; end if;
  insert into public.message_reads (message_id, user_id)
  select m.id, auth.uid() from public.messages m
  join public.profiles a on a.id = m.author_id and a.role in ('officer', 'admin')
  where m.channel_id = p_channel and m.author_id <> auth.uid()
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.mark_channel_read(uuid) from public, anon;
grant  execute on function public.mark_channel_read(uuid) to authenticated;

-- ---------- 3) Attendance decides who logs time ----------
-- Representatives answer before the meeting starts; after that only the Head of Education changes it.
create or replace function public.set_attendance(p_meeting uuid, p_mode public.attendance_mode)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.meetings m where m.id = p_meeting and public.in_council(m.council_id)) then
    raise exception 'You are not in this council';
  end if;
  if not public.is_officer() and exists (select 1 from public.meetings m where m.id = p_meeting and m.starts_at < now()) then
    raise exception 'The meeting has started. Ask the Head of Education to add you if you were there.';
  end if;
  if p_mode is null then
    delete from public.meeting_attendance where meeting_id = p_meeting and user_id = auth.uid();
  else
    insert into public.meeting_attendance (meeting_id, user_id, mode) values (p_meeting, auth.uid(), p_mode)
    on conflict (meeting_id, user_id) do update set mode = excluded.mode, updated_at = now();
  end if;
end $$;

-- Head of Education: set or remove anyone's attendance, also after the meeting
create or replace function public.set_attendance_for(p_meeting uuid, p_user uuid, p_mode public.attendance_mode)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() then raise exception 'Only the Head of Education can do this'; end if;
  if p_mode is null then
    delete from public.meeting_attendance where meeting_id = p_meeting and user_id = p_user;
  else
    insert into public.meeting_attendance (meeting_id, user_id, mode) values (p_meeting, p_user, p_mode)
    on conflict (meeting_id, user_id) do update set mode = excluded.mode, updated_at = now();
  end if;
end $$;
revoke execute on function public.set_attendance_for(uuid, uuid, public.attendance_mode) from public, anon;
grant  execute on function public.set_attendance_for(uuid, uuid, public.attendance_mode) to authenticated;

create or replace function public.guard_meeting_time() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.meeting_id is not distinct from old.meeting_id
     and new.activity = old.activity then
    return new;
  end if;
  if new.activity in ('council_meeting', 'siec_meeting') and new.meeting_id is null then
    raise exception 'Choose the meeting you attended.';
  end if;
  if new.meeting_id is not null and not exists (
       select 1 from public.meeting_attendance a
       where a.meeting_id = new.meeting_id and a.user_id = new.user_id and a.mode in ('offline', 'online')) then
    raise exception 'You were not registered as attending this meeting. Ask the Head of Education to add you.';
  end if;
  return new;
end $$;
drop trigger if exists time_entries_meeting_guard on public.time_entries;
create trigger time_entries_meeting_guard before insert or update on public.time_entries
  for each row execute function public.guard_meeting_time();

-- The day-after prompt "Log your hours" goes only to those who attended
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
    for u in select a.user_id as uid from public.meeting_attendance a
             where a.meeting_id = m.id and a.mode in ('offline', 'online')
               and not exists (select 1 from public.time_entries e where e.user_id = a.user_id and e.meeting_id = m.id) loop
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
