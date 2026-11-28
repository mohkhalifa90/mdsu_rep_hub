-- Follow-ups: the Head of Education is told about them, and "new since you last looked"
-- * New follow-ups and every update notify the council's reps AND the Head of Education
--   (never the person who did it). Before, the Head of Education got no follow-up notifications.
-- * profiles.last_seen remembers when someone last opened a page (mark_seen), so the app can
--   show what is new since then: highlighted cards and a number on the Follow-ups tab.

alter table public.issues add column if not exists last_actor uuid references public.profiles (id) on delete set null;
alter table public.profiles add column if not exists last_seen jsonb not null default '{}'::jsonb;

-- who hears about a follow-up: the council's reps and the Head of Education
create or replace function public.issue_audience(p_council uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  select uid from public.council_member_ids(p_council) uid
  union
  select p.id from public.profiles p where p.active and p.role in ('officer', 'admin')
$$;
revoke execute on function public.issue_audience(uuid) from public, anon, authenticated;

create or replace function public.on_issue_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  dash text := ' ' || chr(8211) || ' ';
  note text;
  me uuid := coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);
begin
  if tg_op = 'INSERT' then
    insert into public.issue_events (issue_id, actor, event) values (new.id, auth.uid(), 'Issue logged');
    insert into public.notifications (user_id, title, body, link)
    select uid, 'New follow-up: ' || new.title, left(coalesce(nullif(new.details, ''), new.title), 140),
           'followups/' || new.id
    from public.issue_audience(new.council_id) uid where uid <> me;
    return new;
  end if;
  note := case when new.response is distinct from old.response then new.response end;
  if new.status <> old.status or note is not null then
    new.updated_at := now();
    new.last_actor := auth.uid();
    insert into public.issue_events (issue_id, actor, event)
    values (new.id, auth.uid(), 'Status: ' || new.status || coalesce(dash || left(note, 500), ''));
    insert into public.notifications (user_id, title, body, link)
    select uid, 'Follow-up updated: ' || new.title,
           initcap(new.status::text) || coalesce(dash || left(note, 120), ''), 'followups/' || new.id
    from public.issue_audience(new.council_id) uid where uid <> me;
  end if;
  return new;
end $$;

-- I opened a page: remember when, and return the time before (to show what is new)
create or replace function public.mark_seen(p_key text) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare before timestamptz;
begin
  select (last_seen ->> p_key)::timestamptz into before from public.profiles where id = auth.uid();
  update public.profiles set last_seen = last_seen || jsonb_build_object(p_key, now()) where id = auth.uid();
  return coalesce(before, now() - interval '7 days');
end $$;
revoke execute on function public.mark_seen(text) from public, anon;
grant  execute on function public.mark_seen(text) to authenticated;

-- follow-ups new to me since I last opened the page (someone else created or changed them)
create or replace function public.new_followups_for_me() returns int
language sql stable security definer set search_path = public as $$
  with seen as (
    select coalesce((last_seen ->> 'followups')::timestamptz, now() - interval '7 days') t
    from public.profiles where id = auth.uid())
  select count(*)::int from public.issues i, seen
  where (public.is_officer() or public.in_council(i.council_id))
    and ((i.updated_at > seen.t and i.last_actor is distinct from auth.uid() and i.last_actor is not null)
         or (i.created_at > seen.t and i.raised_by <> auth.uid()))
$$;
grant execute on function public.new_followups_for_me() to authenticated;

create or replace function public.my_badges() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me record; result jsonb;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active then return '{}'::jsonb; end if;
  if me.role in ('officer', 'admin') then
    select jsonb_build_object(
      'reports', (select count(*) from public.time_reports r join public.semesters s on s.id = r.semester_id
                  where s.is_current and r.status = 'submitted'),
      'signups', (select count(*) from public.profiles where not active and approval = 'waiting'),
      'channels', (select coalesce(sum(unread), 0) from public.channel_overview()),
      'followups', public.new_followups_for_me())
    into result;
  else
    select jsonb_build_object(
      'channels', (select coalesce(sum(unread), 0) from public.channel_overview()),
      'followups', public.new_followups_for_me(),
      'meetings', (select count(*) from public.meetings mt
                   where mt.starts_at > now() and mt.starts_at < now() + interval '21 days'
                     and public.in_council(mt.council_id)
                     and not exists (select 1 from public.meeting_attendance a where a.meeting_id = mt.id and a.user_id = me.id)))
    into result;
  end if;
  return result;
end $$;
revoke execute on function public.my_badges() from public, anon;
grant  execute on function public.my_badges() to authenticated;
