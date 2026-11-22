-- Appearance: everyone chooses light/dark mode, a colour and a banner picture.
-- Saved on the profile, so the choice follows the person to every device.
alter table public.profiles add column if not exists ui_prefs jsonb not null default '{}'::jsonb;

-- Own banner pictures (public bucket: pictures only, each person writes in their own folder)
do $outer$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public) values ('banners', 'banners', true) on conflict (id) do nothing;
    execute $p$ drop policy if exists banners_upload on storage.objects $p$;
    execute $p$ drop policy if exists banners_delete on storage.objects $p$;
    execute $p$ create policy banners_upload on storage.objects for insert to authenticated
      with check (bucket_id = 'banners' and public.is_active_user()
                  and (storage.foldername(name))[1] = auth.uid()::text) $p$;
    execute $p$ create policy banners_delete on storage.objects for delete to authenticated
      using (bucket_id = 'banners' and (storage.foldername(name))[1] = auth.uid()::text) $p$;
  end if;
end $outer$;
