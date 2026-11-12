-- MDSU Rep Hub – update 3
-- 1) Pay rounded per activity, like the official "Timrapport" Excel sheet:
--    each row is rounded up to started half hours, then the rows are added up.
-- 2) Start time per activity (Fr.o.m. / T.o.m. in the time report).
-- 3) Home address for the time report (Bostadsadress); personal number optional until filled in.
-- 4) Channels like the Teams team "Student representatives at MDU" + files in channels.

-- ---------- 1) Pay per activity ----------
create or replace function public.half_hours(p_user uuid, p_semester uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(ceil(minutes / 30.0)), 0)::int
  from public.time_entries where user_id = p_user and semester_id = p_semester
$$;

-- ---------- 2) Start time ----------
alter table public.time_entries add column if not exists start_time time;

-- ---------- 3) Address ----------
alter table public.private_details alter column personal_number drop not null;
alter table public.private_details add column if not exists address text;

-- report_overview: amount = started half hours (per activity) × half-hour rate. New column half_hours at the end.
create or replace view public.report_overview with (security_invoker = true) as
  select p.id                                   as user_id,
         p.full_name, p.program, p.academy, p.is_member,
         s.id                                   as semester_id,
         s.name                                 as semester_name,
         coalesce(r.status, 'draft')            as status,
         r.id                                   as report_id,
         r.submitted_at, r.is_late, r.reviewer_comment,
         coalesce(sum(e.minutes), 0)::int       as minutes,
         count(e.id)::int                       as entries,
         count(e.id) filter (where not exists (select 1 from public.attachments a where a.entry_id = e.id))::int
                                                as entries_without_notes,
         coalesce(r.approved_amount,
                  case when p.is_member then coalesce(sum(ceil(e.minutes / 30.0)), 0)::int * s.half_hour_rate else 0 end)
                                                as amount,
         exists (select 1 from public.private_details d where d.user_id = p.id and d.personal_number is not null)
                                                as has_personal_number,
         coalesce(sum(ceil(e.minutes / 30.0)), 0)::int as half_hours
  from public.profiles p
  cross join public.semesters s
  left join public.time_reports r on r.user_id = p.id and r.semester_id = s.id
  left join public.time_entries e on e.user_id = p.id and e.semester_id = s.id
  where s.is_current and p.role = 'rep' and p.active
    and (p.id = auth.uid() or public.is_officer())
  group by p.id, s.id, r.id;

create or replace function public.review_time_report(p_report uuid, p_action text, p_comment text default null)
returns public.time_reports
language plpgsql security definer set search_path = public as $$
declare rep public.time_reports; mins int; halves int; amt int;
begin
  if not public.is_officer() then raise exception 'Only the Head of Education can review reports'; end if;
  select * into rep from public.time_reports where id = p_report for update;
  if rep.id is null then raise exception 'Report not found'; end if;

  if p_action = 'approve' then
    if rep.status <> 'submitted' then raise exception 'Only submitted reports can be approved'; end if;
    select coalesce(sum(minutes), 0) into mins from public.time_entries
     where user_id = rep.user_id and semester_id = rep.semester_id;
    halves := public.half_hours(rep.user_id, rep.semester_id);
    select case when p.is_member then halves * s.half_hour_rate else 0 end into amt
      from public.profiles p, public.semesters s where p.id = rep.user_id and s.id = rep.semester_id;
    update public.time_reports set status = 'approved', approved_minutes = mins, approved_amount = amt,
           reviewed_at = now(), reviewed_by = auth.uid(), reviewer_comment = p_comment
     where id = p_report returning * into rep;
    perform public.notify_user(rep.user_id, 'Time report approved', amt || ' SEK will be paid out', 'hours');
  elsif p_action = 'return' then
    if rep.status <> 'submitted' then raise exception 'Only submitted reports can be returned'; end if;
    update public.time_reports set status = 'returned', reviewed_at = now(), reviewed_by = auth.uid(),
           reviewer_comment = coalesce(p_comment, 'Please check your report')
     where id = p_report returning * into rep;
    perform public.notify_user(rep.user_id, 'Time report returned', rep.reviewer_comment, 'hours');
  elsif p_action = 'paid' then
    if rep.status <> 'approved' then raise exception 'Only approved reports can be marked as paid'; end if;
    update public.time_reports set status = 'paid' where id = p_report returning * into rep;
    perform public.notify_user(rep.user_id, 'Time report paid', rep.approved_amount || ' SEK', 'hours');
  else
    raise exception 'Unknown action %', p_action;
  end if;
  return rep;
end $$;

-- Payroll rows now also carry address and email for the time report sheets
drop function if exists public.payroll_export();
create or replace function public.payroll_export()
returns table (user_id uuid, full_name text, email text, personal_number text, address text, program text,
               is_member boolean, status public.report_status, hours numeric, started_half_hours int, amount int)
language sql stable security definer set search_path = public as $$
  select o.user_id, o.full_name, p.email, d.personal_number, d.address, o.program, o.is_member, o.status,
         round(o.minutes / 60.0, 2), o.half_hours, o.amount
  from public.report_overview o
  join public.profiles p on p.id = o.user_id
  left join public.private_details d on d.user_id = o.user_id
  where public.is_officer() and o.status in ('submitted', 'approved', 'paid')
  order by o.full_name
$$;

-- ---------- 4) Channels like Teams + files ----------
alter table public.channels add column if not exists sort_order int not null default 100;
alter table public.messages add column if not exists file_path text;
alter table public.messages add column if not exists file_name text;

-- Rename the starting channels to the Teams names (keeps their messages)
update public.channels set name = 'Allmänt', description = 'General information and discussion for all student representatives',
       officer_only = false, sort_order = 1
 where name = 'SR Lounge';
update public.channels set name = 'SIEC', description = 'Student Influence and Education Committee – only moderators post here',
       officer_only = true, sort_order = 2
 where name = 'Announcements';
insert into public.channels (name, description, audience, officer_only, sort_order)
select v.name, v.description, 'all', v.officer_only, v.sort_order
from (values
  ('Allmänt', 'General information and discussion for all student representatives', false, 1),
  ('SIEC', 'Student Influence and Education Committee – only moderators post here', true, 2),
  ('SSOC', 'Student Study environment and Organisation Committee', false, 3),
  ('Student input', 'Share what students say – surveys, class visits, feedback', false, 4),
  ('Student Representative Resources', 'Material for representatives: guides, templates, slides', true, 5)
) as v(name, description, officer_only, sort_order)
where not exists (select 1 from public.channels c where c.name = v.name);
-- The academy channels from the first version are removed if nobody used them
delete from public.channels c
 where c.name in ('EST representatives', 'HVV representatives', 'IDT representatives', 'UKK representatives')
   and not exists (select 1 from public.messages m where m.channel_id = c.id);

-- Storage for channel files (only on Supabase)
do $outer$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public) values ('channel-files', 'channel-files', false)
    on conflict (id) do nothing;
    execute $p$ create policy channel_files_read on storage.objects for select to authenticated
      using (bucket_id = 'channel-files' and public.is_active_user()) $p$;
    execute $p$ create policy channel_files_upload on storage.objects for insert to authenticated
      with check (bucket_id = 'channel-files' and public.is_active_user()
                  and (storage.foldername(name))[1] = auth.uid()::text) $p$;
    execute $p$ create policy channel_files_delete on storage.objects for delete to authenticated
      using (bucket_id = 'channel-files' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_officer())) $p$;
  end if;
end $outer$;
