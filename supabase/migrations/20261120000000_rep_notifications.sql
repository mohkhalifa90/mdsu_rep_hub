-- Notifications the representatives asked for, and "no topics this time".
--   * A new meeting notifies the representatives of that council right away.
--   * Every message the Head of Education posts in a channel notifies its members
--     (announcements as before, ordinary posts too).
--   * A representative can say "I have no topics for this meeting".

-- ---------- 1. New meeting → notify the council ----------
create or replace function public.on_meeting_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.semesters;
begin
  if new.starts_at <= now() then return new; end if;
  select * into s from public.semesters where is_current;

  insert into public.notifications (user_id, title, body, link)
  select uid, 'New meeting: ' || new.title,
         to_char(new.starts_at at time zone 'Europe/Stockholm', 'DD Mon, HH24:MI') ||
         coalesce(' · ' || nullif(new.location, ''), '') ||
         '. Say how you attend' ||
         coalesce(' and send your topics by ' || to_char(new.input_deadline, 'DD Mon'), '') || '.',
         'agenda/' || new.id
  from public.council_member_ids(new.council_id) uid;

  -- Inside the agenda-call window this already is the request for input,
  -- so the morning automation does not send a second one.
  if s.id is not null and
     (new.starts_at at time zone 'Europe/Stockholm')::date <= public.local_today() + s.agenda_call_days then
    update public.meetings set input_requested = true where id = new.id;
  end if;
  return new;
end $$;

drop trigger if exists meetings_after_insert on public.meetings;
create trigger meetings_after_insert after insert on public.meetings
  for each row execute function public.on_meeting_insert();

-- ---------- 2. Posts by the Head of Education → notify ----------
create or replace function public.on_message_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare ch record; by_officer boolean;
begin
  select * into ch from public.channels where id = new.channel_id;
  by_officer := exists (select 1 from public.profiles where id = new.author_id and role in ('officer','admin'));
  if ch.officer_only and not by_officer then
    raise exception 'Only the Head of Education can post in %', ch.name;
  end if;
  if new.is_announcement and not by_officer then
    raise exception 'Only the Head of Education can post announcements';
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

-- ---------- 3. "No topics this time" ----------
create table if not exists public.meeting_no_input (
  meeting_id  uuid not null references public.meetings (id) on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (meeting_id, user_id)
);

create or replace function public.set_no_input(p_meeting uuid, p_no_input boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.meetings m where m.id = p_meeting and public.in_council(m.council_id)) then
    raise exception 'You are not in this council';
  end if;
  if p_no_input then
    insert into public.meeting_no_input (meeting_id, user_id) values (p_meeting, auth.uid())
    on conflict do nothing;
  else
    delete from public.meeting_no_input where meeting_id = p_meeting and user_id = auth.uid();
  end if;
end $$;

alter table public.meeting_no_input enable row level security;
drop policy if exists mni_read    on public.meeting_no_input;
drop policy if exists mni_off     on public.meeting_no_input;
drop policy if exists only_active on public.meeting_no_input;
create policy mni_read on public.meeting_no_input for select to authenticated using (user_id = auth.uid() or public.is_officer());
create policy mni_off  on public.meeting_no_input for all    to authenticated using (public.is_officer()) with check (public.is_officer());
create policy only_active on public.meeting_no_input as restrictive for all to authenticated
  using (public.is_active_user()) with check (public.is_active_user());
grant select, insert, update, delete on public.meeting_no_input to authenticated;
