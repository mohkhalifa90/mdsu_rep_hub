-- Channels with something new stand out
-- * channel_overview(): a channel's unread number also counts my unread notifications that point
--   into it (comments, tags, reactions) – so the Head of Education sees where the new things are.
-- * Opening a channel marks those notifications as read (the bell number goes down too).
-- * The Channels tab shows the total for the Head of Education as well.

create or replace function public.channel_overview()
returns table (channel_id uuid, last_body text, last_file text, last_at timestamptz, last_author uuid, unread int)
language sql stable set search_path = public as $$
  select c.id, lm.body, lm.file_name, lm.created_at, lm.author_id,
         greatest(
           -- posts from the Head of Education I have not opened
           (select count(*)::int from public.messages m
              join public.profiles a on a.id = m.author_id and a.role in ('officer', 'admin')
             where m.channel_id = c.id and m.parent_id is null and m.author_id <> auth.uid()
               and m.created_at > now() - interval '60 days'
               and not exists (select 1 from public.message_reads r where r.message_id = m.id and r.user_id = auth.uid())),
           -- my unread notifications about this channel
           (select count(*)::int from public.notifications n
             where n.user_id = auth.uid() and n.read_at is null
               and (n.link = 'chat/' || c.id or n.link like 'chat/' || c.id || '/%')))
  from public.channels c
  left join lateral (select m.body, m.file_name, m.created_at, m.author_id from public.messages m
                      where m.channel_id = c.id and m.parent_id is null
                      order by m.created_at desc limit 1) lm on true
  where public.is_officer() or c.audience = 'all' or c.audience = public.my_academy()
$$;
revoke execute on function public.channel_overview() from public, anon;
grant  execute on function public.channel_overview() to authenticated;

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
  update public.notifications set read_at = now()
   where user_id = auth.uid() and read_at is null
     and (link = 'chat/' || p_channel or link like 'chat/' || p_channel || '/%');
  return n;
end $$;
revoke execute on function public.mark_channel_read(uuid) from public, anon;
grant  execute on function public.mark_channel_read(uuid) to authenticated;

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
      'channels', (select coalesce(sum(unread), 0) from public.channel_overview()))
    into result;
  else
    select jsonb_build_object(
      'channels', (select coalesce(sum(unread), 0) from public.channel_overview()),
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

-- ---------- profile card ----------
-- Tap a name or photo to see the person. Email is shown when they share their contact details,
-- when they are the Head of Education, or when the Head of Education is looking.
create or replace function public.profile_card(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p record; show_email boolean;
begin
  if not public.is_active_user() then raise exception 'Not allowed'; end if;
  select * into p from public.profiles where id = p_user and active;
  if p.id is null then return null; end if;
  show_email := p.share_contact or p.role in ('officer', 'admin') or public.is_officer() or p.id = auth.uid();
  return jsonb_build_object(
    'id', p.id,
    'full_name', p.full_name,
    'role', p.role,
    'program', p.program,
    'department', p.department,
    'study_year', p.study_year,
    'avatar_url', p.avatar_url,
    'email', case when show_email then p.email end,
    'councils', coalesce((select jsonb_agg(c.name order by c.name)
                            from public.council_members cm join public.councils c on c.id = cm.council_id
                           where cm.user_id = p.id and c.type <> 'siec'), '[]'::jsonb));
end $$;
revoke execute on function public.profile_card(uuid) from public, anon;
grant  execute on function public.profile_card(uuid) to authenticated;
