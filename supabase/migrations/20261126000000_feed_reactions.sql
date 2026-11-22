-- Channels as a feed (Dania's feedback)
-- * Every channel: only the Head of Education posts, representatives comment under posts.
-- * She can tag representatives (they get a notification), react to comments, and edit or delete her posts.
--   Everyone can edit/delete their own comments; she can delete any.
-- * Comments on the tutoring board.

-- ---------- all channels are feeds ----------
update public.channels set officer_only = true where not officer_only;
alter table public.channels alter column officer_only set default true;

-- ---------- edit, tags ----------
alter table public.messages
  add column if not exists edited_at timestamptz,
  add column if not exists mentions  uuid[] not null default '{}';

grant update on public.messages to authenticated;
drop policy if exists msg_upd on public.messages;
create policy msg_upd on public.messages for update to authenticated
  using (author_id = auth.uid()) with check (author_id = auth.uid());

-- Only the text, file and tags can change; marks the message as edited
create or replace function public.on_message_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.channel_id <> old.channel_id or new.author_id <> old.author_id
     or new.parent_id is distinct from old.parent_id or new.created_at <> old.created_at then
    raise exception 'Only the text can be changed';
  end if;
  if not public.is_officer() then
    new.is_announcement := old.is_announcement;
    new.mentions := old.mentions;
  end if;
  if new.body is distinct from old.body or new.file_path is distinct from old.file_path then
    new.edited_at := now();
  end if;
  return new;
end $$;
drop trigger if exists messages_before_update on public.messages;
create trigger messages_before_update before update on public.messages
  for each row execute function public.on_message_update();

-- Tagged people get a notification (only tags by the Head of Education count)
create or replace function public.notify_mentions() returns trigger
language plpgsql security definer set search_path = public as $$
declare ch record;
begin
  if not exists (select 1 from public.profiles where id = new.author_id and role in ('officer', 'admin')) then
    return new;
  end if;
  select * into ch from public.channels where id = new.channel_id;
  insert into public.notifications (user_id, title, body, link)
  select u, 'The Head of Education tagged you in ' || ch.name, left(coalesce(new.body, ''), 140), 'chat/' || new.channel_id
  from unnest(new.mentions) u
  where u <> new.author_id
    and (tg_op = 'INSERT' or not (u = any (old.mentions)))
    and exists (select 1 from public.profiles p where p.id = u and p.active);
  return new;
end $$;
drop trigger if exists messages_mentions on public.messages;
create trigger messages_mentions after insert or update of mentions on public.messages
  for each row execute function public.notify_mentions();

-- Non-officers cannot tag on insert either
create or replace function public.strip_mentions() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.profiles where id = new.author_id and role in ('officer', 'admin')) then
    new.mentions := '{}';
  end if;
  return new;
end $$;
drop trigger if exists messages_strip_mentions on public.messages;
create trigger messages_strip_mentions before insert on public.messages
  for each row execute function public.strip_mentions();

-- ---------- reactions ----------
create table if not exists public.message_reactions (
  message_id  uuid not null references public.messages (id) on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  emoji       text not null check (char_length(emoji) between 1 and 8),
  created_at  timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);
alter table public.message_reactions enable row level security;
drop policy if exists re_read on public.message_reactions;
drop policy if exists re_ins on public.message_reactions;
drop policy if exists re_del on public.message_reactions;
create policy re_read on public.message_reactions for select to authenticated
  using (exists (select 1 from public.messages m where m.id = message_id));    -- message RLS applies inside
create policy re_ins on public.message_reactions for insert to authenticated
  with check (user_id = auth.uid() and public.is_active_user()
              and exists (select 1 from public.messages m where m.id = message_id));
create policy re_del on public.message_reactions for delete to authenticated using (user_id = auth.uid());
grant select, insert, delete on public.message_reactions to authenticated;

-- A reaction from the Head of Education is worth a notification
create or replace function public.on_reaction() returns trigger
language plpgsql security definer set search_path = public as $$
declare m record;
begin
  if not public.is_officer() then return new; end if;
  select * into m from public.messages where id = new.message_id;
  if m.author_id <> new.user_id then
    insert into public.notifications (user_id, title, body, link)
    values (m.author_id, 'The Head of Education reacted ' || new.emoji, left(coalesce(m.body, ''), 140), 'chat/' || m.channel_id);
  end if;
  return new;
end $$;
drop trigger if exists reactions_notify on public.message_reactions;
create trigger reactions_notify after insert on public.message_reactions
  for each row execute function public.on_reaction();

-- ---------- tutoring comments ----------
create table if not exists public.tutoring_comments (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.tutoring_posts (id) on delete cascade,
  author_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body        text not null check (char_length(trim(body)) > 0),
  created_at  timestamptz not null default now()
);
create index if not exists tutoring_comments_post_idx on public.tutoring_comments (post_id, created_at);
alter table public.tutoring_comments enable row level security;
drop policy if exists tc_read on public.tutoring_comments;
drop policy if exists tc_ins on public.tutoring_comments;
drop policy if exists tc_del on public.tutoring_comments;
create policy tc_read on public.tutoring_comments for select to authenticated
  using (exists (select 1 from public.tutoring_posts p where p.id = post_id));   -- post RLS applies inside
create policy tc_ins on public.tutoring_comments for insert to authenticated
  with check (author_id = auth.uid() and public.is_active_user()
              and exists (select 1 from public.tutoring_posts p where p.id = post_id and not p.hidden));
create policy tc_del on public.tutoring_comments for delete to authenticated
  using (author_id = auth.uid() or public.is_officer());
grant select, insert, delete on public.tutoring_comments to authenticated;

create or replace function public.on_tutoring_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  select * into p from public.tutoring_posts where id = new.post_id;
  if p.author_id <> new.author_id then
    insert into public.notifications (user_id, title, body, link)
    values (p.author_id, 'New comment on your tutoring post (' || p.course || ')', left(new.body, 140), 'tutoring');
  end if;
  return new;
end $$;
drop trigger if exists tutoring_comments_notify on public.tutoring_comments;
create trigger tutoring_comments_notify after insert on public.tutoring_comments
  for each row execute function public.on_tutoring_comment();

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.message_reactions; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.tutoring_comments; exception when duplicate_object then null; end;
  end if;
end $$;
