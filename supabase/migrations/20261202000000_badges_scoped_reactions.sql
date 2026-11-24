-- UX package
-- * Numbers on the tabs: new posts in channels, meetings to answer (reps); reports to review and
--   sign-ups waiting (Head of Education).
-- * Reactions carry where they belong (channel / posts / tutoring), so a screen only loads its own.

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
      'signups', (select count(*) from public.profiles where not active and approval = 'waiting'))
    into result;
  else
    select jsonb_build_object(
      -- posts from the Head of Education I have not opened yet
      'channels', (select count(*) from public.messages m
                   join public.channels ch on ch.id = m.channel_id
                   join public.profiles a on a.id = m.author_id and a.role in ('officer', 'admin')
                   where m.parent_id is null and (ch.audience = 'all' or ch.audience = me.academy)
                     and m.created_at > me.created_at - interval '30 days'
                     and not exists (select 1 from public.message_reads r where r.message_id = m.id and r.user_id = me.id)),
      -- meetings in the next 3 weeks I have not said whether I attend
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

-- ---------- reactions know their place ----------
alter table public.message_reactions add column if not exists channel_id uuid;
update public.message_reactions r set channel_id = m.channel_id from public.messages m
 where m.id = r.message_id and r.channel_id is null;
create or replace function public.reaction_channel() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select channel_id into new.channel_id from public.messages where id = new.message_id;
  return new;
end $$;
drop trigger if exists reactions_channel on public.message_reactions;
create trigger reactions_channel before insert on public.message_reactions
  for each row execute function public.reaction_channel();
create index if not exists message_reactions_channel_idx on public.message_reactions (channel_id);

alter table public.item_reactions add column if not exists area text;
update public.item_reactions r set area = case when r.kind = 'comment'
    then (select c.kind from public.item_comments c where c.id = r.item_id) else r.kind end
 where area is null;
create or replace function public.reaction_area() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.area := case when new.kind = 'comment'
    then (select c.kind from public.item_comments c where c.id = new.item_id) else new.kind end;
  return new;
end $$;
drop trigger if exists reactions_area on public.item_reactions;
create trigger reactions_area before insert on public.item_reactions
  for each row execute function public.reaction_area();
create index if not exists item_reactions_area_idx on public.item_reactions (area);
