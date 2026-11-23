-- The study year is worked out from the cohort, not typed by hand.
-- A rep in cohort HT2025 is in year 2 from August 2026, year 3 from August 2027, and so on
-- (VT cohorts move up in January). profiles.study_year is kept in step with the roster, so
-- every screen (Representatives, rep directory, the rep's profile) shows the same year.
-- Reps without a cohort keep the year that was set by hand.

create or replace function public.cohort_year(p_cohort text, p_at date default current_date) returns int
language sql stable as $$
  select case when p_cohort ~ '^(HT|VT)[0-9]{4}$' then
    greatest(1, floor(((extract(year from p_at)::int - substr(p_cohort, 3)::int) * 12
                       + extract(month from p_at)::int
                       - case when left(p_cohort, 2) = 'HT' then 8 else 1 end) / 12.0)::int + 1)
  end
$$;

create or replace function public.refresh_study_years(p_email text default null) returns void
language sql security definer set search_path = public as $$
  update public.profiles p set study_year = y.yr
  from (select r.email, min(public.cohort_year(r.cohort)) as yr
        from public.roster r join public.councils c on c.id = r.council_id
        where c.type = 'program' and r.cohort is not null and (p_email is null or r.email = p_email)
        group by r.email) y
  where lower(p.email) = y.email and p.study_year is distinct from y.yr
$$;
revoke execute on function public.refresh_study_years(text) from public, anon;
grant  execute on function public.refresh_study_years(text) to authenticated;

create or replace function public.roster_year_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.refresh_study_years(case when tg_op = 'DELETE' then old.email else new.email end);
  return null;
end $$;
drop trigger if exists roster_year on public.roster;
create trigger roster_year after insert or update or delete on public.roster
  for each row execute function public.roster_year_sync();

create or replace function public.profile_year_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.refresh_study_years(lower(trim(coalesce(new.email, ''))));
  return null;
end $$;
drop trigger if exists profiles_year on public.profiles;
create trigger profiles_year after insert on public.profiles
  for each row execute function public.profile_year_sync();

select public.refresh_study_years();
