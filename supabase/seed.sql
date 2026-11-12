-- Starting data for MDSU Rep Hub. Edit names to match your real councils.

insert into public.semesters (name, starts_on, ends_on, report_deadline, reminder_date, is_current)
values ('Autumn 2026', '2026-08-24', '2027-01-17', '2027-01-17', '2026-12-20', true);

insert into public.councils (name, type, academy) values
  ('SIEC (all representatives)',                     'siec',    null),
  ('Program council – Computer Science',             'program', 'IDT'),
  ('Program council – Product Design',               'program', 'IDT'),
  ('Program council – Nursing',                      'program', 'HVV'),
  ('Program council – Business Administration',      'program', 'EST'),
  ('Program council – Teacher Education',            'program', 'UKK'),
  ('Academy council IDT – Education',                'academy', 'IDT'),
  ('Academy council HVV – Education',                'academy', 'HVV'),
  ('Academy council EST – Education',                'academy', 'EST'),
  ('Academy council UKK – Education',                'academy', 'UKK'),
  ('General council – Library & study environment',  'general', null);

-- Channels like the Teams team (the migration creates them too; this only adds missing ones)
insert into public.channels (name, description, audience, officer_only, sort_order)
select v.* from (values
  ('Allmänt', 'General information and discussion for all student representatives', 'all', false, 1),
  ('SIEC', 'Student Influence and Education Committee – only moderators post here', 'all', true, 2),
  ('SSOC', 'Student Study environment and Organisation Committee', 'all', false, 3),
  ('Student input', 'Share what students say – surveys, class visits, feedback', 'all', false, 4),
  ('Student Representative Resources', 'Material for representatives: guides, templates, slides', 'all', true, 5)
) as v(name, description, audience, officer_only, sort_order)
where not exists (select 1 from public.channels c where c.name = v.name);

-- After the Head of Education has signed in once, make them officer:
-- update public.profiles set role = 'officer', active = true where email = 'utbildning@mdsu.se';
