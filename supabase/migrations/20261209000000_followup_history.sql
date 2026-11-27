-- Follow-ups: fix the garbled dash in the history ("â€"") and keep the text safe from file encodings
-- The dash is now written as chr(8211), so it stays right however the SQL file is opened or pasted.

create or replace function public.on_issue_change() returns trigger
language plpgsql security definer set search_path = public as $$
declare dash text := ' ' || chr(8211) || ' ';
begin
  if tg_op = 'INSERT' then
    insert into public.issue_events (issue_id, actor, event) values (new.id, auth.uid(), 'Issue logged');
  elsif new.status <> old.status or new.response is distinct from old.response then
    new.updated_at := now();
    insert into public.issue_events (issue_id, actor, event)
    values (new.id, auth.uid(), 'Status: ' || new.status || coalesce(dash || left(new.response, 200), ''));
    insert into public.notifications (user_id, title, body, link)
    select uid, 'Follow-up updated: ' || new.title,
           initcap(new.status::text) || coalesce(dash || left(new.response, 120), ''), 'followups'
    from public.council_member_ids(new.council_id) uid;
  end if;
  return new;
end $$;

-- repair what is already saved (the dash read as Windows-1252: â € “ or â € plus a control character)
update public.issue_events
   set event = replace(replace(event, chr(226) || chr(8364) || chr(8220), chr(8211)),
                       chr(226) || chr(8364) || chr(147), chr(8211))
 where event like '%' || chr(226) || chr(8364) || '%';
update public.notifications
   set body = replace(replace(body, chr(226) || chr(8364) || chr(8220), chr(8211)),
                      chr(226) || chr(8364) || chr(147), chr(8211))
 where body like '%' || chr(226) || chr(8364) || '%';
