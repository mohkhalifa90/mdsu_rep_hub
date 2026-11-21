-- Sign-up control
-- Only university / union emails can sign up (unchanged). In addition the Head of Education can
-- close sign-up completely and create accounts herself (Edge Function admin-create-user):
-- the new account is active at once and must change the temporary password on first sign-in.

create table if not exists public.app_settings (
  id           boolean primary key default true check (id),
  signup_open  boolean not null default true
);
insert into public.app_settings default values on conflict do nothing;
alter table public.app_settings enable row level security;
drop policy if exists as_read  on public.app_settings;
drop policy if exists as_write on public.app_settings;
create policy as_read  on public.app_settings for select to authenticated using (true);
create policy as_write on public.app_settings for update to authenticated
  using (public.is_officer()) with check (public.is_officer());
grant select, update on public.app_settings to authenticated;

-- The sign-in screen (not signed in yet) asks whether "Create account" should be shown
create or replace function public.signup_open() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select signup_open from public.app_settings), true)
$$;
grant execute on function public.signup_open() to anon, authenticated;

-- Accounts the Head of Education is creating right now (written only by the Edge Function)
create table if not exists public.account_invites (
  email       text primary key check (email = lower(email)),
  created_at  timestamptz not null default now()
);
alter table public.account_invites enable row level security;   -- no policies: service role only

alter table public.profiles add column if not exists must_change_password boolean not null default false;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare dom text := lower(split_part(coalesce(new.email, ''), '@', 2));
        invited boolean;
begin
  delete from public.account_invites where email = lower(coalesce(new.email, ''));
  invited := found;
  if not invited then
    if not public.signup_open() then
      raise exception 'SIGNUP_CLOSED: ask the Head of Education to create an account for you';
    end if;
    if exists (select 1 from public.allowed_email_domains)
       and not exists (select 1 from public.allowed_email_domains where domain = dom) then
      raise exception 'EMAIL_DOMAIN_NOT_ALLOWED: use your student email (@student.mdu.se)';
    end if;
  end if;
  insert into public.profiles (id, email, full_name, active, must_change_password)
  values (new.id, new.email,
          coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', split_part(new.email, '@', 1)),
          invited, invited)
  on conflict (id) do nothing;
  return new;
end $$;

-- The user has chosen their own password
create or replace function public.password_changed() returns void
language sql security definer set search_path = public as $$
  update public.profiles set must_change_password = false where id = auth.uid()
$$;
revoke execute on function public.password_changed() from public, anon;
grant  execute on function public.password_changed() to authenticated;
