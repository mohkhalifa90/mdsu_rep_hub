-- Payslip link: when a report is marked as paid, the notification links to the payroll app
-- (e.g. Fortnox) where the representative sees the payslip, tax and details. The Head of Education
-- sets the link once under Automations & settings. Reps also get a button on their paid report.
alter table public.app_settings
  add column if not exists payslip_url   text check (payslip_url is null or payslip_url ~ '^https?://'),
  add column if not exists payslip_label text;

create or replace function public.review_time_report(p_report uuid, p_action text, p_comment text default null)
returns public.time_reports
language plpgsql security definer set search_path = public as $$
declare rep public.time_reports; mins int; halves int; amt int; url text; label text;
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
    select payslip_url, coalesce(nullif(payslip_label, ''), 'Fortnox') into url, label from public.app_settings;
    -- with a payslip link the notification opens it (salary details, tax …)
    perform public.notify_user(rep.user_id, 'Time report paid',
      rep.approved_amount || ' SEK has been paid.'
        || case when nullif(url, '') is not null then ' Tap to see your payslip (tax and details) in ' || label || '.' else '' end,
      coalesce(nullif(url, ''), 'hours'));
  else
    raise exception 'Unknown action %', p_action;
  end if;
  return rep;
end $$;
