-- Food preferences (allergies) for meetings with food
-- * The Head of Education marks a meeting "Food is served" (on by default).
-- * A rep who attends in the room picks their food preference for that meeting.
--   Their last choice is filled in automatically next time, and they can change it.
-- * The Head of Education sees the counts and names per meeting and in the Excel export.

alter table public.meetings add column if not exists serves_food boolean not null default true;
alter table public.meeting_attendance add column if not exists food text[];
alter table public.meeting_attendance add column if not exists food_other text;

-- the choices the app offers
create or replace function public.food_choices() returns text[] language sql immutable as $$
  select array['none', 'vegetarian', 'vegan', 'lactose_free', 'gluten_free', 'other']
$$;

-- my last food choice, to fill in for the next meeting
create or replace function public.last_food(p_user uuid)
returns table (food text[], food_other text) language sql stable security definer set search_path = public as $$
  select a.food, a.food_other from public.meeting_attendance a
   where a.user_id = p_user and a.food is not null
   order by a.updated_at desc limit 1
$$;
revoke execute on function public.last_food(uuid) from public, anon, authenticated;

-- Attending in the room carries the last food choice over
create or replace function public.set_attendance(p_meeting uuid, p_mode public.attendance_mode)
returns void language plpgsql security definer set search_path = public as $$
declare lf record;
begin
  if not exists (select 1 from public.meetings m where m.id = p_meeting and public.in_council(m.council_id)) then
    raise exception 'You are not in this council';
  end if;
  if not public.is_officer() and exists (select 1 from public.meetings m where m.id = p_meeting and m.starts_at < now()) then
    raise exception 'The meeting has started. Ask the Head of Education to add you if you were there.';
  end if;
  if p_mode is null then
    delete from public.meeting_attendance where meeting_id = p_meeting and user_id = auth.uid();
  else
    select * into lf from public.last_food(auth.uid());
    insert into public.meeting_attendance (meeting_id, user_id, mode, food, food_other)
    values (p_meeting, auth.uid(), p_mode,
            case when p_mode = 'offline' then lf.food end,
            case when p_mode = 'offline' then lf.food_other end)
    on conflict (meeting_id, user_id) do update
      set mode = excluded.mode, updated_at = now(),
          food = case when excluded.mode = 'offline'
                      then coalesce(public.meeting_attendance.food, excluded.food) end,
          food_other = case when excluded.mode = 'offline'
                      then coalesce(public.meeting_attendance.food_other, excluded.food_other) end;
  end if;
end $$;

-- A rep sets their food preference for a meeting they attend in the room
create or replace function public.set_food(p_meeting uuid, p_food text[], p_other text default null)
returns void language plpgsql security definer set search_path = public as $$
declare clean text[];
begin
  if not exists (select 1 from public.meeting_attendance
                  where meeting_id = p_meeting and user_id = auth.uid() and mode = 'offline') then
    raise exception 'Choose "In the room" first';
  end if;
  if not public.is_officer() and exists (select 1 from public.meetings m where m.id = p_meeting and m.starts_at < now()) then
    raise exception 'The meeting has started';
  end if;
  select array_agg(distinct f) into clean from unnest(coalesce(p_food, '{}')) f where f = any (public.food_choices());
  if clean is null then raise exception 'Choose a food preference (or None)'; end if;
  -- "None" cannot go with anything else
  if 'none' = any (clean) and array_length(clean, 1) > 1 then clean := array['none']; end if;
  if 'other' = any (clean) and coalesce(trim(p_other), '') = '' then
    raise exception 'Write what "Other" means (e.g. nut allergy)';
  end if;
  update public.meeting_attendance
     set food = clean,
         food_other = case when 'other' = any (clean) then left(trim(p_other), 200) end,
         updated_at = now()
   where meeting_id = p_meeting and user_id = auth.uid();
end $$;
revoke execute on function public.set_food(uuid, text[], text) from public, anon;
grant  execute on function public.set_food(uuid, text[], text) to authenticated;
