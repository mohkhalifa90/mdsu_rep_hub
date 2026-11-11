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

insert into public.channels (name, description, audience, officer_only) values
  ('Announcements',       'Official information from the Head of Education', 'all', true),
  ('SR Lounge',           'All student representatives – share, ask, connect', 'all', false),
  ('EST representatives', 'Reps in the EST academy', 'EST', false),
  ('HVV representatives', 'Reps in the HVV academy', 'HVV', false),
  ('IDT representatives', 'Reps in the IDT academy', 'IDT', false),
  ('UKK representatives', 'Reps in the UKK academy', 'UKK', false);

-- After the Head of Education has signed in once, make them officer:
-- update public.profiles set role = 'officer', active = true where email = 'utbildning@mdsu.se';
