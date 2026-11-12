-- 1) Only university / union email addresses can create an account.
--    Edit the list in Supabase → Table Editor → allowed_email_domains.
create table if not exists public.allowed_email_domains (
  domain text primary key check (domain = lower(domain) and domain !~ '@')
);
alter table public.allowed_email_domains enable row level security;
create policy aed_read  on public.allowed_email_domains for select to authenticated using (true);
create policy aed_write on public.allowed_email_domains for all to authenticated
  using (public.is_officer()) with check (public.is_officer());
grant select, insert, update, delete on public.allowed_email_domains to authenticated;

insert into public.allowed_email_domains (domain) values
  ('student.mdu.se'),   -- students
  ('mdu.se'),           -- university staff
  ('mdsu.se')           -- the student union
on conflict do nothing;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare dom text := lower(split_part(coalesce(new.email, ''), '@', 2));
begin
  if exists (select 1 from public.allowed_email_domains)
     and not exists (select 1 from public.allowed_email_domains where domain = dom) then
    raise exception 'EMAIL_DOMAIN_NOT_ALLOWED: use your student email (@student.mdu.se)';
  end if;
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end $$;

-- 2) Deleting a user (Supabase → Authentication → Users → Delete user) removes all their data.
--    Issues they raised stay for the council (only the name link is cleared).
alter table public.issues alter column raised_by drop not null;
alter table public.issues drop constraint if exists issues_raised_by_fkey,
  add constraint issues_raised_by_fkey foreign key (raised_by) references public.profiles (id) on delete set null;
alter table public.issue_events drop constraint if exists issue_events_actor_fkey,
  add constraint issue_events_actor_fkey foreign key (actor) references public.profiles (id) on delete set null;
alter table public.time_reports drop constraint if exists time_reports_reviewed_by_fkey,
  add constraint time_reports_reviewed_by_fkey foreign key (reviewed_by) references public.profiles (id) on delete set null;

-- The report lock must not block deleting a whole user
create or replace function public.guard_time_entry() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if tg_op = 'DELETE' and not exists (select 1 from public.profiles where id = old.user_id) then
    return old;  -- the user is being deleted
  end if;
  if tg_op = 'UPDATE'
     and new.council_id is null and old.council_id is not null
     and (to_jsonb(new) - 'council_id') = (to_jsonb(old) - 'council_id') then
    return new;  -- only the council link was cleared (council deleted)
  end if;
  r := case when tg_op = 'DELETE' then old else new end;
  if public.report_locked(r.user_id, r.semester_id) then
    raise exception 'Your time report is already submitted. Ask the Head of Education to return it.';
  end if;
  if tg_op = 'UPDATE' and public.report_locked(old.user_id, old.semester_id) then
    raise exception 'Your time report is already submitted.';
  end if;
  return r;
end $$;
