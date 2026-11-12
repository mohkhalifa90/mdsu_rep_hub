-- More kinds of work a representative can log (not only meetings)
alter type public.activity_type add value if not exists 'materials';  -- preparing material: presentations, surveys, guides
alter type public.activity_type add value if not exists 'task';       -- task given by MDSU / Head of Education
alter type public.activity_type add value if not exists 'other';      -- other education-related work (described)
