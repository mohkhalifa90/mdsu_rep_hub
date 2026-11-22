-- The same interactions everywhere: comments, reactions, tags, edit/delete
-- * Channels: representatives can tag people in their comments too.
-- * Posts from the Head of Education and the tutoring board: comments, emoji reactions (also on
--   comments), tags, edit/delete – one shared design (item_comments / item_reactions).

-- ---------- tags in channels: everyone ----------
drop trigger if exists messages_strip_mentions on public.messages;

create or replace function public.notify_tags(p_author uuid, p_new uuid[], p_old uuid[], p_where text, p_body text, p_link text)
returns void language plpgsql security definer set search_path = public as $$
declare who text;
begin
  select case when role in ('officer', 'admin') then 'The Head of Education' else full_name end into who
  from public.profiles where id = p_author;
  insert into public.notifications (user_id, title, body, link)
  select u, coalesce(who, 'Someone') || ' tagged you in ' || p_where, left(coalesce(p_body, ''), 140), p_link
  from unnest(coalesce(p_new, '{}')) u
  where u <> p_author and not (u = any (coalesce(p_old, '{}')))
    and exists (select 1 from public.profiles p where p.id = u and p.active);
end $$;

create or replace function public.notify_mentions() returns trigger
language plpgsql security definer set search_path = public as $$
declare ch record;
begin
  select * into ch from public.channels where id = new.channel_id;
  perform public.notify_tags(new.author_id, new.mentions, case when tg_op = 'UPDATE' then old.mentions end,
                             ch.name, new.body, 'chat/' || new.channel_id);
  return new;
end $$;

create or replace function public.on_message_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.channel_id <> old.channel_id or new.author_id <> old.author_id
     or new.parent_id is distinct from old.parent_id or new.created_at <> old.created_at then
    raise exception 'Only the text can be changed';
  end if;
  if not public.is_officer() then new.is_announcement := old.is_announcement; end if;
  if new.body is distinct from old.body or new.file_path is distinct from old.file_path then
    new.edited_at := now();
  end if;
  return new;
end $$;

-- ---------- tags and "edited" on posts and tutoring posts ----------
alter table public.posts
  add column if not exists mentions uuid[] not null default '{}',
  add column if not exists edited_at timestamptz;
alter table public.tutoring_posts
  add column if not exists mentions uuid[] not null default '{}',
  add column if not exists edited_at timestamptz;

create or replace function public.mark_edited() returns trigger
language plpgsql as $$
begin
  if new.body is distinct from old.body or (to_jsonb(new) ->> 'title') is distinct from (to_jsonb(old) ->> 'title')
     or (to_jsonb(new) ->> 'course') is distinct from (to_jsonb(old) ->> 'course') then
    new.edited_at := now();
  end if;
  return new;
end $$;
drop trigger if exists posts_edited on public.posts;
create trigger posts_edited before update on public.posts for each row execute function public.mark_edited();
drop trigger if exists tutoring_edited on public.tutoring_posts;
create trigger tutoring_edited before update on public.tutoring_posts for each row execute function public.mark_edited();

create or replace function public.post_tags() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'posts' then
    perform public.notify_tags(new.author_id, new.mentions, case when tg_op = 'UPDATE' then old.mentions end,
                               'a post: ' || new.title, new.body, 'posts/' || new.id);
  else
    perform public.notify_tags(new.author_id, new.mentions, case when tg_op = 'UPDATE' then old.mentions end,
                               'the tutoring board (' || new.course || ')', new.body, 'tutoring');
  end if;
  return new;
end $$;
drop trigger if exists posts_tags on public.posts;
create trigger posts_tags after insert or update of mentions on public.posts for each row execute function public.post_tags();
drop trigger if exists tutoring_tags on public.tutoring_posts;
create trigger tutoring_tags after insert or update of mentions on public.tutoring_posts
  for each row execute function public.post_tags();

-- ---------- comments and reactions on posts / tutoring ----------
create table if not exists public.item_comments (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('post', 'tutoring')),
  item_id     uuid not null,
  author_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body        text not null check (char_length(trim(body)) > 0),
  mentions    uuid[] not null default '{}',
  edited_at   timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists item_comments_item_idx on public.item_comments (kind, item_id, created_at);

create table if not exists public.item_reactions (
  kind        text not null check (kind in ('post', 'tutoring', 'comment')),
  item_id     uuid not null,
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  emoji       text not null check (char_length(emoji) between 1 and 8),
  created_at  timestamptz not null default now(),
  primary key (kind, item_id, user_id, emoji)
);

-- Can the signed-in person see this item? (uses the item's own access rules)
create or replace function public.can_see_item(p_kind text, p_id uuid) returns boolean
language sql stable security invoker set search_path = public as $$
  select case p_kind
    when 'post'     then exists (select 1 from public.posts where id = p_id)
    when 'tutoring' then exists (select 1 from public.tutoring_posts where id = p_id and not hidden)
    when 'comment'  then exists (select 1 from public.item_comments where id = p_id)
    else false end
$$;

-- Who wrote it, and where a notification should take them
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
    select author_id, 'tutoring', 'tutoring post (' || course || ')' into author, link, label
    from public.tutoring_posts where id = p_id;
  end if;
end $$;

alter table public.item_comments enable row level security;
alter table public.item_reactions enable row level security;
drop policy if exists ic_read on public.item_comments;
drop policy if exists ic_ins on public.item_comments;
drop policy if exists ic_upd on public.item_comments;
drop policy if exists ic_del on public.item_comments;
create policy ic_read on public.item_comments for select to authenticated using (public.can_see_item(kind, item_id));
create policy ic_ins on public.item_comments for insert to authenticated
  with check (author_id = auth.uid() and public.is_active_user() and public.can_see_item(kind, item_id));
create policy ic_upd on public.item_comments for update to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());
create policy ic_del on public.item_comments for delete to authenticated using (author_id = auth.uid() or public.is_officer());
grant select, insert, update, delete on public.item_comments to authenticated;

drop policy if exists ir_read on public.item_reactions;
drop policy if exists ir_ins on public.item_reactions;
drop policy if exists ir_del on public.item_reactions;
create policy ir_read on public.item_reactions for select to authenticated using (public.can_see_item(kind, item_id));
create policy ir_ins on public.item_reactions for insert to authenticated
  with check (user_id = auth.uid() and public.is_active_user() and public.can_see_item(kind, item_id));
create policy ir_del on public.item_reactions for delete to authenticated using (user_id = auth.uid());
grant select, insert, delete on public.item_reactions to authenticated;

-- comment: only the text and tags change; tell the item's author and the tagged people
create or replace function public.on_item_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare i record;
begin
  if tg_op = 'UPDATE' then
    if new.kind <> old.kind or new.item_id <> old.item_id or new.author_id <> old.author_id then
      raise exception 'Only the text can be changed';
    end if;
    if new.body is distinct from old.body then new.edited_at := now(); end if;
    return new;
  end if;
  return new;
end $$;
drop trigger if exists item_comments_before on public.item_comments;
create trigger item_comments_before before update on public.item_comments
  for each row execute function public.on_item_comment();

create or replace function public.after_item_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare i record;
begin
  select * into i from public.item_info(new.kind, new.item_id);
  if tg_op = 'INSERT' and i.author is not null and i.author <> new.author_id then
    insert into public.notifications (user_id, title, body, link)
    values (i.author, 'New comment on your ' || i.label, left(new.body, 140), i.link);
  end if;
  perform public.notify_tags(new.author_id, new.mentions, case when tg_op = 'UPDATE' then old.mentions end,
                             'a comment on a ' || i.label, new.body, i.link);
  return new;
end $$;
drop trigger if exists item_comments_after on public.item_comments;
create trigger item_comments_after after insert or update of mentions on public.item_comments
  for each row execute function public.after_item_comment();

-- a reaction from the Head of Education is worth a notification
create or replace function public.on_item_reaction() returns trigger
language plpgsql security definer set search_path = public as $$
declare i record;
begin
  if not public.is_officer() then return new; end if;
  select * into i from public.item_info(new.kind, new.item_id);
  if i.author is not null and i.author <> new.user_id then
    insert into public.notifications (user_id, title, body, link)
    values (i.author, 'The Head of Education reacted ' || new.emoji, 'On your ' || i.label, i.link);
  end if;
  return new;
end $$;
drop trigger if exists item_reactions_notify on public.item_reactions;
create trigger item_reactions_notify after insert on public.item_reactions
  for each row execute function public.on_item_reaction();

-- deleting a post / comment removes what hangs on it
create or replace function public.cleanup_item() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text := case tg_table_name when 'posts' then 'post' when 'tutoring_posts' then 'tutoring' else 'comment' end;
begin
  if k <> 'comment' then
    delete from public.item_reactions where kind = 'comment'
      and item_id in (select id from public.item_comments where kind = k and item_id = old.id);
    delete from public.item_comments where kind = k and item_id = old.id;
  end if;
  delete from public.item_reactions where kind = k and item_id = old.id;
  return old;
end $$;
drop trigger if exists posts_cleanup on public.posts;
create trigger posts_cleanup after delete on public.posts for each row execute function public.cleanup_item();
drop trigger if exists tutoring_cleanup on public.tutoring_posts;
create trigger tutoring_cleanup after delete on public.tutoring_posts for each row execute function public.cleanup_item();
drop trigger if exists item_comments_cleanup on public.item_comments;
create trigger item_comments_cleanup after delete on public.item_comments for each row execute function public.cleanup_item();

-- ---------- tutoring comments move to the shared table ----------
do $$ begin
  if to_regclass('public.tutoring_comments') is not null then
    insert into public.item_comments (id, kind, item_id, author_id, body, created_at)
    select id, 'tutoring', post_id, author_id, body, created_at from public.tutoring_comments
    on conflict (id) do nothing;
    drop table public.tutoring_comments;
  end if;
end $$;
drop function if exists public.on_tutoring_comment();

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.item_comments; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.item_reactions; exception when duplicate_object then null; end;
  end if;
end $$;
