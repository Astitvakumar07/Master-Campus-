-- Store the registration number issued by the college, separately from the
-- app-generated campus student code. It is a campus-scoped candidate key.
alter table public.campus_enrollments
  add column if not exists college_registration_number text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.campus_enrollments'::regclass
      and contype='u'
      and pg_get_constraintdef(oid)='UNIQUE (campus_id, college_registration_number)'
  ) then
    alter table public.campus_enrollments
      add constraint campus_enrollments_college_registration_key
      unique (campus_id, college_registration_number);
  end if;
end $$;
