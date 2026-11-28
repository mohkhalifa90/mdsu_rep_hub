-- A closed follow-up is finished: only the Head of Education can open it again or add to it.
create or replace function public.set_issue_status(p_issue uuid, p_status public.issue_status, p_response text default null)
returns public.issues
language plpgsql security definer set search_path = public as $$
declare i public.issues;
begin
  select * into i from public.issues where id = p_issue;
  if i.id is null then raise exception 'Issue not found'; end if;
  if not (public.is_officer() or public.in_council(i.council_id)) then raise exception 'Not allowed'; end if;
  if not public.is_officer() then
    if i.status = 'closed' then
      raise exception 'This follow-up is closed. Ask the Head of Education to open it again.';
    end if;
    if p_status in ('escalated', 'closed') then
      raise exception 'Only the Head of Education can escalate or close issues';
    end if;
  end if;
  update public.issues set status = p_status, response = coalesce(p_response, response)
   where id = p_issue returning * into i;
  return i;
end $$;
