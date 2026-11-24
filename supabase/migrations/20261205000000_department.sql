-- Department instead of Academy
-- Each representative belongs to a department (institution). The choices are the councils in
-- "Department (Institutional)" (type general) in Programmes & seats. The old academy field stays
-- in the database only because channel audiences still use it.

alter table public.profiles add column if not exists department text;

create or replace view public.rep_directory as
  select id, full_name, program, academy, study_year, email, department
  from public.profiles where active and role = 'rep' and share_contact and public.is_active_user();
grant select on public.rep_directory to authenticated;
