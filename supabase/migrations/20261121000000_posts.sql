-- Posts from the Head of Education (news, instructions, the final agenda of a meeting).
--   * A post goes to all representatives or to the members of one council.
--   * A post can carry one file (bucket 'posts').
--   * A post tied to a meeting is that meeting's final agenda; it shows on the meeting page.
--   * Every new post notifies its readers.

create table if not exists public.posts (
  id          uuid primary key default gen_random_uuid(),
  author_id   uuid default auth.uid() references public.profiles (id) on delete set null,
  title       text not null check (length(btrim(title)) > 0),
  body        text not null default '',
  council_id  uuid references public.councils (id) on delete cascade,   -- null = all representatives
  meeting_id  uuid references public.meetings (id) on delete cascade,   -- set = final agenda of this meeting
  file_path   text,
  file_name   text,
  created_at  timestamptz not null default now()
);
create index if not exists posts_created_idx on public.posts (created_at desc);
create index if not exists posts_meeting_idx on public.posts (meeting_id);

-- A final agenda goes to the meeting's council
create or replace function public.post_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.meeting_id is not null then
    select council_id into new.council_id from public.meetings where id = new.meeting_id;
  end if;
  return new;
end $$;
drop trigger if exists posts_before_insert on public.posts;
create trigger posts_before_insert before insert on public.posts
  for each row execute function public.post_defaults();

create or replace function public.on_post_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare mt text;
begin
  if new.meeting_id is not null then
    select title into mt from public.meetings where id = new.meeting_id;
  end if;
  insert into public.notifications (user_id, title, body, link)
  select p.id,
         case when new.meeting_id is not null then 'Final agenda: ' || coalesce(mt, new.title)
              else 'From the Head of Education: ' || new.title end,
         left(coalesce(nullif(new.body, ''), new.file_name, ''), 140),
         case when new.meeting_id is not null then 'agenda/' || new.meeting_id else 'posts/' || new.id end
  from public.profiles p
  where p.active and p.role = 'rep'
    and (new.council_id is null or p.id in (select public.council_member_ids(new.council_id)));
  return new;
end $$;
drop trigger if exists posts_after_insert on public.posts;
create trigger posts_after_insert after insert on public.posts
  for each row execute function public.on_post_insert();

alter table public.posts enable row level security;
drop policy if exists posts_read    on public.posts;
drop policy if exists posts_officer on public.posts;
drop policy if exists only_active   on public.posts;
create policy posts_read on public.posts for select to authenticated
  using (public.is_officer() or council_id is null or public.in_council(council_id));
create policy posts_officer on public.posts for all to authenticated
  using (public.is_officer()) with check (public.is_officer());
create policy only_active on public.posts as restrictive for all to authenticated
  using (public.is_active_user()) with check (public.is_active_user());
grant select, insert, update, delete on public.posts to authenticated;

-- ---------- Files, realtime (only on Supabase) ----------
do $outer$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public) values ('posts', 'posts', false) on conflict (id) do nothing;
    execute $p$ drop policy if exists posts_files_read   on storage.objects $p$;
    execute $p$ drop policy if exists posts_files_upload on storage.objects $p$;
    execute $p$ drop policy if exists posts_files_delete on storage.objects $p$;
    execute $p$ create policy posts_files_read on storage.objects for select to authenticated
      using (bucket_id = 'posts' and public.is_active_user()) $p$;
    execute $p$ create policy posts_files_upload on storage.objects for insert to authenticated
      with check (bucket_id = 'posts' and public.is_officer()) $p$;
    execute $p$ create policy posts_files_delete on storage.objects for delete to authenticated
      using (bucket_id = 'posts' and public.is_officer()) $p$;
  end if;
end $outer$;

do $outer$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.posts;
  end if;
exception when duplicate_object then null;
end $outer$;
