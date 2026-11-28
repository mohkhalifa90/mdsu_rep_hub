-- Follow-ups as a thread
-- * The issue stays as it was written; every change is a new update underneath (who, status, note).
-- * A history line carries the note only when a new note was written (no repeat of the old answer).
-- * The notification opens that follow-up directly (link followups/<issue id>).

create or replace function public.on_issue_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  dash text := ' ' || chr(8211) || ' ';
  note text := case when new.response is distinct from old.response then new.response end;
begin
  if tg_op = 'INSERT' then
    insert into public.issue_events (issue_id, actor, event) values (new.id, auth.uid(), 'Issue logged');
    return new;
  end if;
  if new.status <> old.status or note is not null then
    new.updated_at := now();
    insert into public.issue_events (issue_id, actor, event)
    values (new.id, auth.uid(), 'Status: ' || new.status || coalesce(dash || left(note, 500), ''));
    insert into public.notifications (user_id, title, body, link)
    select uid, 'Follow-up updated: ' || new.title,
           initcap(new.status::text) || coalesce(dash || left(note, 120), ''), 'followups/' || new.id
    from public.council_member_ids(new.council_id) uid
    where uid <> coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid);
  end if;
  return new;
end $$;

-- ---------- edit or delete the issue itself ----------
-- The Head of Education can always edit or delete. The person who raised it can do so only until
-- someone else has posted an update, so answers never end up under a changed question.
alter table public.issues add column if not exists edited_at timestamptz;

create or replace function public.can_change_issue(p_issue uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_officer() or exists (
    select 1 from public.issues i
     where i.id = p_issue and i.raised_by = auth.uid()
       and not exists (select 1 from public.issue_events e
                        where e.issue_id = i.id and e.event <> 'Issue logged' and e.event <> 'Issue edited'
                          and e.actor is distinct from auth.uid()))
$$;
grant execute on function public.can_change_issue(uuid) to authenticated;

create or replace function public.edit_issue(p_issue uuid, p_title text, p_details text, p_responsible text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_change_issue(p_issue) then
    raise exception 'Only the Head of Education can change this follow-up now that others have answered';
  end if;
  if coalesce(trim(p_title), '') = '' then raise exception 'Write the issue'; end if;
  update public.issues
     set title = trim(p_title), details = coalesce(trim(p_details), ''),
         responsible = nullif(trim(p_responsible), ''), edited_at = now()
   where id = p_issue;
  insert into public.issue_events (issue_id, actor, event) values (p_issue, auth.uid(), 'Issue edited');
end $$;
revoke execute on function public.edit_issue(uuid, text, text, text) from public, anon;
grant  execute on function public.edit_issue(uuid, text, text, text) to authenticated;

create or replace function public.delete_issue(p_issue uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.can_change_issue(p_issue) then
    raise exception 'Only the Head of Education can delete this follow-up now that others have answered';
  end if;
  delete from public.issues where id = p_issue;
end $$;
revoke execute on function public.delete_issue(uuid) from public, anon;
grant  execute on function public.delete_issue(uuid) to authenticated;
