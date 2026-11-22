-- Notifications open the exact post, and one reaction per person
-- * Links now point at the message / post: chat/<channel>/<message>, posts/<id>, tutoring/<id>,
--   so tapping a notification opens that channel with the post on top (highlighted).
-- * One reaction per person on each post or comment: choosing another emoji replaces it.

-- ---------- one reaction per person ----------
delete from public.message_reactions a using public.message_reactions b
 where a.message_id = b.message_id and a.user_id = b.user_id
   and (a.created_at < b.created_at or (a.created_at = b.created_at and a.emoji > b.emoji));
alter table public.message_reactions drop constraint if exists message_reactions_pkey;
alter table public.message_reactions add primary key (message_id, user_id);

delete from public.item_reactions a using public.item_reactions b
 where a.kind = b.kind and a.item_id = b.item_id and a.user_id = b.user_id
   and (a.created_at < b.created_at or (a.created_at = b.created_at and a.emoji > b.emoji));
alter table public.item_reactions drop constraint if exists item_reactions_pkey;
alter table public.item_reactions add primary key (kind, item_id, user_id);

-- ---------- links to the exact message ----------
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
             'chat/' || new.channel_id || '/' || new.id
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
           'chat/' || new.channel_id || '/' || new.id
    from public.profiles p
    where p.active and p.role = 'rep' and (ch.audience = 'all' or p.academy = ch.audience);
  end if;
  return new;
end $$;

create or replace function public.notify_mentions() returns trigger
language plpgsql security definer set search_path = public as $$
declare ch record;
begin
  select * into ch from public.channels where id = new.channel_id;
  perform public.notify_tags(new.author_id, new.mentions, case when tg_op = 'UPDATE' then old.mentions end,
                             ch.name, new.body, 'chat/' || new.channel_id || '/' || new.id);
  return new;
end $$;

create or replace function public.on_reaction() returns trigger
language plpgsql security definer set search_path = public as $$
declare m record;
begin
  if not public.is_officer() then return new; end if;
  select * into m from public.messages where id = new.message_id;
  if m.author_id <> new.user_id then
    insert into public.notifications (user_id, title, body, link)
    values (m.author_id, 'The Head of Education reacted ' || new.emoji, left(coalesce(m.body, ''), 140),
            'chat/' || m.channel_id || '/' || m.id);
  end if;
  return new;
end $$;

create or replace function public.item_info(p_kind text, p_id uuid, out author uuid, out link text, out label text)
language plpgsql stable security definer set search_path = public as $$
declare c record;
begin
  if p_kind = 'comment' then
    select * into c from public.item_comments where id = p_id;
    author := c.author_id;
    select i.link, i.label into link, label from public.item_info(c.kind, c.item_id) i;
    return;
  end if;
  if p_kind = 'post' then
    select author_id, 'posts/' || id, 'post: ' || title into author, link, label from public.posts where id = p_id;
  else
    select author_id, 'tutoring/' || id, 'tutoring post (' || course || ')' into author, link, label
    from public.tutoring_posts where id = p_id;
  end if;
end $$;

create or replace function public.post_tags() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'posts' then
    perform public.notify_tags(new.author_id, new.mentions, case when tg_op = 'UPDATE' then old.mentions end,
                               'a post: ' || new.title, new.body, 'posts/' || new.id);
  else
    perform public.notify_tags(new.author_id, new.mentions, case when tg_op = 'UPDATE' then old.mentions end,
                               'the tutoring board (' || new.course || ')', new.body, 'tutoring/' || new.id);
  end if;
  return new;
end $$;

-- ---------- a colour per channel ----------
alter table public.channels add column if not exists color text check (color ~ '^[a-z]+$');
