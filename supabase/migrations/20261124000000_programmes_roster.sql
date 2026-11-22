-- Phase 4: programmes, seats and the roster of representatives
--
-- * Every programme council is one programme in one city with one way of teaching
--   (e.g. "Ekonomprogrammet · ESK · Campus"). It knows its intake (HT, VT or both),
--   its length and its programme director.
-- * Seats: one per active cohort. Intake every term (HT & VT) → one seat per term of the
--   programme (3 years = 6, 3.5 years = 7). Intake once a year → one seat per year (rounded up).
--   The Head of Education can set another number. Central councils have a plain number of seats.
-- * The roster says which representative (by email) sits on which council, and for programmes
--   in which cohort (e.g. HT2025). People without an account yet can be on the roster: as soon as
--   they sign up with that email they become members of the council. More reps than seats is
--   allowed – the app marks them as extra.
-- * Sign-ups: the Head of Education is told about every new sign-up, and new sign-ups are told
--   apart from former reps whose account was switched off.

-- ---------- Councils get programme details ----------
alter table public.councils
  add column if not exists city           text check (city in ('ESK', 'VÄS')),
  add column if not exists study_mode     text check (study_mode in ('campus', 'distans')),
  add column if not exists intake         text check (intake in ('HT', 'VT', 'HT_VT')),
  add column if not exists length_years   numeric(3,1) check (length_years > 0 and length_years <= 8),
  add column if not exists seats          int check (seats >= 0 and seats <= 50),
  add column if not exists director_name  text,
  add column if not exists director_email text,
  add column if not exists institution    text,
  add column if not exists cancelled      boolean not null default false,
  add column if not exists notes          text;

-- ---------- Roster ----------
create table if not exists public.roster (
  id          uuid primary key default gen_random_uuid(),
  council_id  uuid not null references public.councils (id) on delete cascade,
  email       text not null check (email = lower(trim(email)) and email like '%@%'),
  cohort      text check (cohort ~ '^(HT|VT)[0-9]{4}$'),
  note        text,
  created_at  timestamptz not null default now(),
  unique (council_id, email)
);
create index if not exists roster_email_idx on public.roster (email);
alter table public.roster enable row level security;
drop policy if exists ro_off on public.roster;
drop policy if exists ro_own on public.roster;
create policy ro_off on public.roster for all to authenticated using (public.is_officer()) with check (public.is_officer());
create policy ro_own on public.roster for select to authenticated
  using (email = (select lower(p.email) from public.profiles p where p.id = auth.uid()));
grant select, insert, update, delete on public.roster to authenticated;

-- Roster and council membership stay in step (in both directions)
create or replace function public.roster_to_members() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.council_members (council_id, user_id)
    select new.council_id, p.id from public.profiles p where lower(p.email) = new.email
    on conflict do nothing;
    return new;
  else
    delete from public.council_members cm using public.profiles p
    where cm.council_id = old.council_id and cm.user_id = p.id and lower(p.email) = old.email;
    return old;
  end if;
end $$;
drop trigger if exists roster_sync on public.roster;
create trigger roster_sync after insert or delete on public.roster
  for each row execute function public.roster_to_members();

create or replace function public.members_to_roster() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.roster (council_id, email)
    select new.council_id, lower(trim(p.email)) from public.profiles p
    where p.id = new.user_id and p.email like '%@%'
    on conflict do nothing;
    return new;
  else
    delete from public.roster r using public.profiles p
    where r.council_id = old.council_id and p.id = old.user_id and r.email = lower(trim(p.email));
    return old;
  end if;
end $$;
drop trigger if exists members_sync on public.council_members;
create trigger members_sync after insert or delete on public.council_members
  for each row execute function public.members_to_roster();

-- Existing memberships go on the roster
insert into public.roster (council_id, email)
select cm.council_id, lower(trim(p.email)) from public.council_members cm
join public.profiles p on p.id = cm.user_id where p.email like '%@%'
on conflict do nothing;

-- ---------- Sign-ups ----------
alter table public.profiles add column if not exists approval text not null default 'waiting'
  check (approval in ('waiting', 'approved', 'rejected'));
update public.profiles set approval = 'approved' where active and approval = 'waiting';

create or replace function public.profile_approval() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.active and not coalesce(old.active, false) then new.approval := 'approved'; end if;
  return new;
end $$;
drop trigger if exists profiles_approval on public.profiles;
create trigger profiles_approval before update on public.profiles
  for each row execute function public.profile_approval();

-- A new profile: join the councils the roster has for that email; tell the officer about sign-ups
create or replace function public.on_profile_created() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.council_members (council_id, user_id)
  select r.council_id, new.id from public.roster r where r.email = lower(trim(coalesce(new.email, '')))
  on conflict do nothing;
  if not new.active then
    insert into public.notifications (user_id, title, body, link)
    select p.id, 'New sign-up: ' || new.full_name, coalesce(new.email, '') || ' is waiting for your approval', 'today'
    from public.profiles p where p.active and p.role in ('officer', 'admin');
  else
    update public.profiles set approval = 'approved' where id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists profiles_created on public.profiles;
create trigger profiles_created after insert on public.profiles
  for each row execute function public.on_profile_created();

-- Reps cannot change protected columns themselves (now also the approval)
create or replace function public.guard_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_officer() and auth.uid() is not null then
    if new.role <> old.role or new.is_member <> old.is_member or new.quiz_passed <> old.quiz_passed
       or new.active <> old.active or new.email is distinct from old.email
       or new.approval <> old.approval then
      raise exception 'Only the Head of Education can change role, membership, quiz or status';
    end if;
  end if;
  return new;
end $$;
