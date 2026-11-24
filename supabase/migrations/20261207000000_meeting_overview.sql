-- Meetings page for the Head of Education: one row per meeting with everything the list shows
-- (who answered, topics, food answers, whether the final agenda is posted).

create or replace function public.meeting_overview()
returns table (meeting_id uuid, members int, room int, online int, absent int,
               topics int, new_topics int, food_missing int, agenda_posted boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_officer() then raise exception 'Only the Head of Education'; end if;
  return query
  select m.id,
         (case when c.type = 'siec'
               then (select count(*) from profiles p where p.active and p.role = 'rep')
               else (select count(*) from council_members cm join profiles p on p.id = cm.user_id
                      where cm.council_id = c.id and p.active and p.role = 'rep') end)::int,
         (select count(*) from meeting_attendance a where a.meeting_id = m.id and a.mode = 'offline')::int,
         (select count(*) from meeting_attendance a where a.meeting_id = m.id and a.mode = 'online')::int,
         (select count(*) from meeting_attendance a where a.meeting_id = m.id and a.mode = 'absent')::int,
         (select count(*) from agenda_items i where i.meeting_id = m.id and i.status <> 'declined')::int,
         (select count(*) from agenda_items i where i.meeting_id = m.id and i.status = 'new')::int,
         (case when m.serves_food
               then (select count(*) from meeting_attendance a
                      where a.meeting_id = m.id and a.mode = 'offline' and a.food is null) else 0 end)::int,
         exists (select 1 from posts po where po.meeting_id = m.id)
  from meetings m join councils c on c.id = m.council_id;
end $$;
revoke execute on function public.meeting_overview() from public, anon;
grant  execute on function public.meeting_overview() to authenticated;

-- ---------- Posts: pinned posts and "seen by" ----------
alter table public.posts add column if not exists pinned boolean not null default false;

create table if not exists public.post_reads (
  post_id  uuid not null references public.posts (id) on delete cascade,
  user_id  uuid not null references public.profiles (id) on delete cascade,
  read_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);
alter table public.post_reads enable row level security;
drop policy if exists post_reads_officer on public.post_reads;
create policy post_reads_officer on public.post_reads for select to authenticated using (public.is_officer());

-- A rep opened the posts page: these posts are seen
create or replace function public.mark_posts_seen(p_posts uuid[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_active_user() or public.is_officer() then return; end if;
  insert into public.post_reads (post_id, user_id)
  select p.id, auth.uid() from public.posts p
   where p.id = any (p_posts) and (p.council_id is null or public.in_council(p.council_id))
  on conflict do nothing;
end $$;
revoke execute on function public.mark_posts_seen(uuid[]) from public, anon;
grant  execute on function public.mark_posts_seen(uuid[]) to authenticated;

-- who a post is for: every active rep, or the reps of its council (SIEC = everyone)
create or replace function public.post_audience(p_post uuid) returns table (user_id uuid)
language sql stable security definer set search_path = public as $$
  select pr.id from public.posts p
  join public.profiles pr on pr.active and pr.role = 'rep'
  left join public.councils c on c.id = p.council_id
  where p.id = p_post
    and (p.council_id is null or c.type = 'siec'
         or exists (select 1 from public.council_members cm where cm.council_id = p.council_id and cm.user_id = pr.id))
$$;
revoke execute on function public.post_audience(uuid) from public, anon, authenticated;

-- Head of Education: per post, how many of its readers have seen it
create or replace function public.post_seen()
returns table (post_id uuid, seen int, audience int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_officer() then raise exception 'Only the Head of Education'; end if;
  return query
  select p.id,
         (select count(*) from public.post_reads r join public.post_audience(p.id) a on a.user_id = r.user_id
           where r.post_id = p.id)::int,
         (select count(*) from public.post_audience(p.id))::int
  from public.posts p where p.created_at > now() - interval '365 days';
end $$;
revoke execute on function public.post_seen() from public, anon;
grant  execute on function public.post_seen() to authenticated;

-- Head of Education: who has not seen a post yet
create or replace function public.post_not_seen(p_post uuid) returns table (user_id uuid)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_officer() then raise exception 'Only the Head of Education'; end if;
  return query
  select a.user_id from public.post_audience(p_post) a
   where not exists (select 1 from public.post_reads r where r.post_id = p_post and r.user_id = a.user_id);
end $$;
revoke execute on function public.post_not_seen(uuid) from public, anon;
grant  execute on function public.post_not_seen(uuid) to authenticated;
