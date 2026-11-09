-- PDF/CSV attachments and resource links for teacher-led learning.
-- Safe to re-run. Existing files, assignments and materials are preserved.

alter table public.assignments
  add column if not exists attachment_path text,
  add column if not exists resource_url text,
  add column if not exists mime_type text,
  add column if not exists file_size bigint;

alter table public.syllabus_units
  add column if not exists attachment_path text,
  add column if not exists resource_url text,
  add column if not exists mime_type text,
  add column if not exists file_size bigint;

alter table public.materials
  add column if not exists resource_url text,
  add column if not exists mime_type text,
  add column if not exists file_size bigint;

-- A material can now be either a private Storage file or a shared external link.
alter table public.materials alter column storage_path drop not null;
do $$ begin
  if not exists (
    select 1 from pg_constraint
    where conname='materials_require_file_or_link'
      and conrelid='public.materials'::regclass
  ) then
    alter table public.materials
      add constraint materials_require_file_or_link
      check (nullif(storage_path,'') is not null or nullif(resource_url,'') is not null);
  end if;
end $$;
