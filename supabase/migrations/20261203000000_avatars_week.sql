-- Profile photos and the weekly summary on Today
-- * Everyone can add a profile photo; it shows next to posts, comments and in lists.
-- * weekly_summary(): what happened in the last 7 days compared with the 7 days before (Head of Education).

-- ---------- profile photos ----------
alter table public.profiles add column if not exists avatar_url text;

create or replace view public.member_names as
  select id, full_name, program, academy, study_year, role, avatar_url from public.profiles
  where active and public.is_active_user();
grant select on public.member_names to authenticated;

do $outer$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
    execute $p$ drop policy if exists avatars_upload on storage.objects $p$;
    execute $p$ drop policy if exists avatars_delete on storage.objects $p$;
    execute $p$ create policy avatars_upload on storage.objects for insert to authenticated
      with check (bucket_id = 'avatars' and public.is_active_user()
                  and (storage.foldername(name))[1] = auth.uid()::text) $p$;
    execute $p$ create policy avatars_delete on storage.objects for delete to authenticated
      using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text) $p$;
  end if;
end $outer$;

-- ---------- weekly summary ----------
create or replace function public.weekly_summary() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  t0 timestamptz := now() - interval '7 days';
  t1 timestamptz := now() - interval '14 days';
  out jsonb := '{}'::jsonb;
begin
  if not public.is_officer() then raise exception 'Only the Head of Education'; end if;

  out := out || jsonb_build_object('reports', jsonb_build_array(
    (select count(*) from time_reports where submitted_at >= t0),
    (select count(*) from time_reports where submitted_at >= t1 and submitted_at < t0)));

  out := out || jsonb_build_object('new_reps', jsonb_build_array(
    (select count(*) from profiles where role = 'rep' and created_at >= t0),
    (select count(*) from profiles where role = 'rep' and created_at >= t1 and created_at < t0)));

  out := out || jsonb_build_object('answered', jsonb_build_array(
    (select count(distinct issue_id) from issue_events where event like 'Status: answered%' and at >= t0),
    (select count(distinct issue_id) from issue_events where event like 'Status: answered%' and at >= t1 and at < t0)));

  out := out || jsonb_build_object('meetings', jsonb_build_array(
    (select count(*) from meetings where starts_at >= t0 and starts_at < now()),
    (select count(*) from meetings where starts_at >= t1 and starts_at < t0)));

  out := out || jsonb_build_object('comments', jsonb_build_array(
    (select count(*) from messages m join profiles p on p.id = m.author_id
      where p.role = 'rep' and m.created_at >= t0),
    (select count(*) from messages m join profiles p on p.id = m.author_id
      where p.role = 'rep' and m.created_at >= t1 and m.created_at < t0)));
  return out;
end $$;
revoke execute on function public.weekly_summary() from public, anon;
grant execute on function public.weekly_summary() to authenticated;
