-- Attendance: before each meeting a representative says how they attend
-- (in the room, online or not at all). The Head of Education sees names and counts
-- and can download them as an Excel sheet.

do $$ begin
  create type public.attendance_mode as enum ('offline', 'online', 'absent');
exception when duplicate_object then null; end $$;

create table if not exists public.meeting_attendance (
  meeting_id  uuid not null references public.meetings (id) on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  mode        public.attendance_mode not null,
  updated_at  timestamptz not null default now(),
  primary key (meeting_id, user_id)
);

-- A representative answers for themself (null = remove the answer)
create or replace function public.set_attendance(p_meeting uuid, p_mode public.attendance_mode)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.meetings m where m.id = p_meeting and public.in_council(m.council_id)) then
    raise exception 'You are not in this council';
  end if;
  if p_mode is null then
    delete from public.meeting_attendance where meeting_id = p_meeting and user_id = auth.uid();
  else
    insert into public.meeting_attendance (meeting_id, user_id, mode) values (p_meeting, auth.uid(), p_mode)
    on conflict (meeting_id, user_id) do update set mode = excluded.mode, updated_at = now();
  end if;
end $$;

-- The agenda request now also asks reps how they will attend
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
         '. Ask your classmates for input now, and say if you attend in the room or online.', 'agenda/' || m.id
  from public.council_member_ids(m.council_id) uid;
  get diagnostics n = row_count;
  return n;
end $$;

alter table public.meeting_attendance enable row level security;
drop policy if exists ma_read     on public.meeting_attendance;
drop policy if exists ma_off      on public.meeting_attendance;
drop policy if exists only_active on public.meeting_attendance;
create policy ma_read on public.meeting_attendance for select to authenticated using (user_id = auth.uid() or public.is_officer());
create policy ma_off  on public.meeting_attendance for all    to authenticated using (public.is_officer()) with check (public.is_officer());
create policy only_active on public.meeting_attendance as restrictive for all to authenticated
  using (public.is_active_user()) with check (public.is_active_user());
grant select, insert, update, delete on public.meeting_attendance to authenticated;

do $outer$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.meeting_attendance;
  end if;
exception when duplicate_object then null;
end $outer$;
