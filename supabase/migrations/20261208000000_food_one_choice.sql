-- Food preference: one choice only, and changes close with the agenda input deadline
-- * A rep picks exactly one option (None, Vegetarian, Vegan, Lactose free, Gluten free or Other).
-- * After the meeting's input deadline a rep who already answered cannot change it any more
--   (the food is ordered); someone who has not answered can still answer once.
-- * The last choice carried to the next meeting is a single option too.

create or replace function public.set_food(p_meeting uuid, p_food text[], p_other text default null)
returns void language plpgsql security definer set search_path = public as $$
declare clean text[]; mt record; current_food text[];
begin
  select * into mt from public.meetings where id = p_meeting;
  select food into current_food from public.meeting_attendance
   where meeting_id = p_meeting and user_id = auth.uid() and mode = 'offline';
  if not found then raise exception 'Choose "In the room" first'; end if;
  if not public.is_officer() then
    if mt.starts_at < now() then raise exception 'The meeting has started'; end if;
    if current_food is not null and mt.input_deadline is not null
       and (now() at time zone 'Europe/Stockholm')::date > mt.input_deadline then
      raise exception 'Food choices closed on % – ask the Head of Education', to_char(mt.input_deadline, 'DD Mon');
    end if;
  end if;
  select array_agg(distinct f) into clean from unnest(coalesce(p_food, '{}')) f where f = any (public.food_choices());
  if clean is null then raise exception 'Choose a food preference (or None)'; end if;
  if array_length(clean, 1) > 1 then raise exception 'Choose one food preference'; end if;
  if clean[1] = 'other' and coalesce(trim(p_other), '') = '' then
    raise exception 'Write what "Other" means (e.g. nut allergy)';
  end if;
  update public.meeting_attendance
     set food = clean,
         food_other = case when clean[1] = 'other' then left(trim(p_other), 200) end,
         updated_at = now()
   where meeting_id = p_meeting and user_id = auth.uid();
end $$;
revoke execute on function public.set_food(uuid, text[], text) from public, anon;
grant  execute on function public.set_food(uuid, text[], text) to authenticated;

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
            case when p_mode = 'offline' then lf.food[1:1] end,
            case when p_mode = 'offline' and lf.food[1] = 'other' then lf.food_other end)
    on conflict (meeting_id, user_id) do update
      set mode = excluded.mode, updated_at = now(),
          food = case when excluded.mode = 'offline'
                      then coalesce(public.meeting_attendance.food, excluded.food) end,
          food_other = case when excluded.mode = 'offline'
                      then coalesce(public.meeting_attendance.food_other, excluded.food_other) end;
  end if;
end $$;
