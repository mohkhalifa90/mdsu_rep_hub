-- Lets the Head of Education delete a council that already has logged hours.
-- The hours stay (they are part of the pay), only the link to the council is cleared.

alter table public.time_entries
  drop constraint if exists time_entries_council_id_fkey,
  add constraint time_entries_council_id_fkey
    foreign key (council_id) references public.councils (id) on delete set null;

-- Locked reports may still lose their council link when a council is deleted
create or replace function public.guard_time_entry() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if tg_op = 'UPDATE'
     and new.council_id is null and old.council_id is not null
     and (to_jsonb(new) - 'council_id') = (to_jsonb(old) - 'council_id') then
    return new;   -- only the council link was cleared
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
