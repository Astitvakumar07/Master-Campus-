-- Keep the app-generated campus student code unique within a campus.
-- The separately entered college registration number is added in migration 12.
-- Auth UUIDs remain the stable primary key for account and membership FKs.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.campus_enrollments'::regclass
      and contype='u'
      and pg_get_constraintdef(oid)='UNIQUE (campus_id, student_code)'
  ) then
    alter table public.campus_enrollments
      add constraint campus_enrollments_registration_candidate_key
      unique (campus_id, student_code);
  end if;
end $$;
