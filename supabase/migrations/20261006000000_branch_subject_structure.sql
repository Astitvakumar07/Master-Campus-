-- Upgrade the original class-only schema to branches, subjects and scoped teaching.
-- Apply once after 20261005000000_master_campus.sql (or after schema.sql).
create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(), name text not null, code text not null unique,
  description text, created_by uuid not null references public.profiles(id),
  is_active boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.subjects (
  id uuid primary key default gen_random_uuid(), branch_id uuid not null references public.branches(id) on delete cascade,
  name text not null, code text not null, created_at timestamptz not null default now(),
  unique(branch_id,code), unique(branch_id,name), unique(branch_id,id)
);
create table if not exists public.branch_teachers (
  branch_id uuid not null references public.branches(id) on delete cascade, subject_id uuid not null,
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  assigned_by uuid not null references public.profiles(id), created_at timestamptz not null default now(),
  primary key(branch_id,subject_id,teacher_id),
  foreign key(branch_id,subject_id) references public.subjects(branch_id,id) on delete cascade
);
alter table public.classes add column if not exists branch_id uuid references public.branches(id);
do $$ begin
 if not exists(select 1 from pg_constraint where conname='classes_id_branch_id_key') then
  alter table public.classes add constraint classes_id_branch_id_key unique(id,branch_id);
 end if;
end $$;
create table if not exists public.class_subjects (
  id uuid primary key default gen_random_uuid(), class_id uuid not null references public.classes(id) on delete cascade,
  branch_id uuid not null, subject_id uuid not null, created_at timestamptz not null default now(),
  unique(class_id,subject_id), unique(class_id,id),
  foreign key(class_id,branch_id) references public.classes(id,branch_id) on delete cascade,
  foreign key(branch_id,subject_id) references public.subjects(branch_id,id) on delete cascade
);
create table if not exists public.class_routines (
  id uuid primary key default gen_random_uuid(), class_id uuid not null references public.classes(id) on delete cascade,
  class_subject_id uuid not null, teacher_id uuid not null references public.profiles(id),
  weekday smallint not null check(weekday between 0 and 6), starts_at time not null,
  ends_at time not null check(ends_at>starts_at), room text,
  created_by uuid not null references public.profiles(id), created_at timestamptz not null default now(),
  foreign key(class_id,class_subject_id) references public.class_subjects(class_id,id) on delete cascade
);
alter table public.syllabus_units add column if not exists class_subject_id uuid;
alter table public.assignments add column if not exists class_subject_id uuid;
alter table public.materials add column if not exists class_subject_id uuid;
alter table public.attendance_sessions add column if not exists class_subject_id uuid;
do $$ begin
 if not exists(select 1 from pg_constraint where conname='syllabus_class_subject_fk') then alter table public.syllabus_units add constraint syllabus_class_subject_fk foreign key(class_id,class_subject_id) references public.class_subjects(class_id,id); end if;
 if not exists(select 1 from pg_constraint where conname='assignments_class_subject_fk') then alter table public.assignments add constraint assignments_class_subject_fk foreign key(class_id,class_subject_id) references public.class_subjects(class_id,id); end if;
 if not exists(select 1 from pg_constraint where conname='materials_class_subject_fk') then alter table public.materials add constraint materials_class_subject_fk foreign key(class_id,class_subject_id) references public.class_subjects(class_id,id); end if;
 if not exists(select 1 from pg_constraint where conname='attendance_class_subject_fk') then alter table public.attendance_sessions add constraint attendance_class_subject_fk foreign key(class_id,class_subject_id) references public.class_subjects(class_id,id); end if;
end $$;

create or replace function public.teaches_class_direct(target uuid) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.class_teachers ct join public.profiles p on p.id=ct.teacher_id where ct.class_id=target and ct.teacher_id=auth.uid() and p.role='teacher' and p.account_status='active')
$$;
create or replace function public.teaches_class(target uuid) returns boolean language sql stable security definer set search_path=public as $$
 select public.teaches_class_direct(target) or exists(select 1 from public.class_subjects cs join public.branch_teachers bt on bt.branch_id=cs.branch_id and bt.subject_id=cs.subject_id join public.profiles p on p.id=bt.teacher_id where cs.class_id=target and bt.teacher_id=auth.uid() and p.role='teacher' and p.account_status='active')
$$;
create or replace function public.teaches_class_subject(target_class uuid,target_subject uuid) returns boolean language sql stable security definer set search_path=public as $$
 select public.teaches_class_direct(target_class) or exists(select 1 from public.class_subjects cs join public.branch_teachers bt on bt.branch_id=cs.branch_id and bt.subject_id=cs.subject_id join public.profiles p on p.id=bt.teacher_id where cs.class_id=target_class and cs.id=target_subject and bt.teacher_id=auth.uid() and p.role='teacher' and p.account_status='active')
$$;
create or replace function public.protect_profile_authority_fields() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if (new.role is distinct from old.role or new.account_status is distinct from old.account_status) and auth.uid() is not null and not public.is_campus_admin() then
  raise exception 'Only a campus administrator may change account role or status';
 end if;
 return new;
end $$;
revoke all on function public.teaches_class_direct(uuid),public.teaches_class_subject(uuid,uuid) from public;
grant execute on function public.teaches_class_direct(uuid),public.teaches_class_subject(uuid,uuid) to authenticated;

alter table public.branches enable row level security;
alter table public.subjects enable row level security;
alter table public.branch_teachers enable row level security;
alter table public.class_subjects enable row level security;
alter table public.class_routines enable row level security;
drop policy if exists "Active campus reads branches" on public.branches;
create policy "Active campus reads branches" on public.branches for select to authenticated using(is_active and public.account_is_active());
drop policy if exists "Admins manage branches" on public.branches;
create policy "Admins manage branches" on public.branches for all to authenticated using(public.is_campus_admin()) with check(public.is_campus_admin());
drop policy if exists "Active campus reads branch subjects" on public.subjects;
create policy "Active campus reads branch subjects" on public.subjects for select to authenticated using(public.account_is_active());
drop policy if exists "Admins manage branch subjects" on public.subjects;
create policy "Admins manage branch subjects" on public.subjects for all to authenticated using(public.is_campus_admin()) with check(public.is_campus_admin());
drop policy if exists "Campus sees relevant branch subject assignments" on public.branch_teachers;
create policy "Campus sees relevant branch subject assignments" on public.branch_teachers for select to authenticated using(public.is_campus_admin() or teacher_id=auth.uid() or exists(select 1 from public.class_subjects cs where cs.branch_id=branch_teachers.branch_id and cs.subject_id=branch_teachers.subject_id and public.is_active_student_in(cs.class_id)));
drop policy if exists "Admins manage branch teacher assignments" on public.branch_teachers;
create policy "Admins manage branch teacher assignments" on public.branch_teachers for all to authenticated using(public.is_campus_admin()) with check(public.is_campus_admin());
drop policy if exists "Campus reads class subjects" on public.class_subjects;
create policy "Campus reads class subjects" on public.class_subjects for select to authenticated using(public.is_campus_admin() or public.is_active_student_in(class_id) or public.teaches_class_subject(class_id,id));
drop policy if exists "Teachers attach their assigned subjects to classes" on public.class_subjects;
create policy "Teachers attach their assigned subjects to classes" on public.class_subjects for insert to authenticated with check(public.is_campus_admin() or exists(select 1 from public.classes c join public.branch_teachers bt on bt.branch_id=c.branch_id and bt.subject_id=class_subjects.subject_id where c.id=class_id and c.created_by=auth.uid() and bt.teacher_id=auth.uid()));
drop policy if exists "Admins manage class subjects" on public.class_subjects;
create policy "Admins manage class subjects" on public.class_subjects for all to authenticated using(public.is_campus_admin()) with check(public.is_campus_admin());
drop policy if exists "Campus reads class routines" on public.class_routines;
create policy "Campus reads class routines" on public.class_routines for select to authenticated using(public.is_campus_admin() or public.is_active_student_in(class_id) or public.teaches_class_subject(class_id,class_subject_id));
drop policy if exists "Assigned teachers manage their class routines" on public.class_routines;
create policy "Assigned teachers manage their class routines" on public.class_routines for all to authenticated using(public.is_campus_admin() or (teacher_id=auth.uid() and public.teaches_class_subject(class_id,class_subject_id))) with check(public.is_campus_admin() or (teacher_id=auth.uid() and created_by=auth.uid() and public.teaches_class_subject(class_id,class_subject_id)));

drop policy if exists "Admins or active teachers create classes" on public.classes;
drop policy if exists "Admins or assigned teachers create branch classes" on public.classes;
create policy "Admins or assigned teachers create branch classes" on public.classes for insert to authenticated with check(public.is_campus_admin() or (created_by=auth.uid() and branch_id is not null and public.current_role()='teacher' and public.account_is_active() and exists(select 1 from public.branch_teachers bt where bt.branch_id=classes.branch_id and bt.teacher_id=auth.uid())));
drop policy if exists "Verified class creator links self as teacher" on public.class_teachers;
drop policy if exists "Verified creator links self on legacy classes" on public.class_teachers;
create policy "Verified creator links self on legacy classes" on public.class_teachers for insert to authenticated with check(teacher_id=auth.uid() and public.current_role()='teacher' and public.account_is_active() and exists(select 1 from public.classes c where c.id=class_id and c.created_by=auth.uid() and c.branch_id is null));

drop policy if exists "Enrolled students and class staff read syllabus" on public.syllabus_units;
drop policy if exists "Enrolled students and assigned subject teachers read syllabus" on public.syllabus_units;
drop policy if exists "Class teachers manage syllabus" on public.syllabus_units;
drop policy if exists "Assigned subject teachers manage syllabus" on public.syllabus_units;
create policy "Enrolled students and assigned subject teachers read syllabus" on public.syllabus_units for select to authenticated using(public.is_campus_admin() or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)) or public.is_active_student_in(class_id));
create policy "Assigned subject teachers manage syllabus" on public.syllabus_units for all to authenticated using(public.is_campus_admin() or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id))) with check(public.is_campus_admin() or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)));
drop policy if exists "Class staff and active students read assignments" on public.assignments;
drop policy if exists "Class members and assigned subject teachers read assignments" on public.assignments;
drop policy if exists "Class teachers manage assignments" on public.assignments;
drop policy if exists "Assigned subject teachers manage assignments" on public.assignments;
create policy "Class members and assigned subject teachers read assignments" on public.assignments for select to authenticated using(public.is_campus_admin() or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)) or public.is_active_student_in(class_id));
create policy "Assigned subject teachers manage assignments" on public.assignments for all to authenticated using(public.is_campus_admin() or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id))) with check(public.is_campus_admin() or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)));
drop policy if exists "Enrolled class can read materials" on public.materials;
drop policy if exists "Enrolled class and assigned teachers read materials" on public.materials;
drop policy if exists "Class teachers manage materials" on public.materials;
drop policy if exists "Assigned subject teachers manage materials" on public.materials;
create policy "Enrolled class and assigned teachers read materials" on public.materials for select to authenticated using(public.is_campus_admin() or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)) or public.is_active_student_in(class_id));
create policy "Assigned subject teachers manage materials" on public.materials for all to authenticated using(public.is_campus_admin() or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id))) with check(public.is_campus_admin() or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)));
drop policy if exists "Students and class staff read submissions" on public.submissions;
drop policy if exists "Students and assigned subject staff read submissions" on public.submissions;
create policy "Students and assigned subject staff read submissions" on public.submissions for select to authenticated using(student_id=auth.uid() or public.is_campus_admin() or exists(select 1 from public.assignments a where a.id=assignment_id and (public.teaches_class_direct(a.class_id) or public.teaches_class_subject(a.class_id,a.class_subject_id))));
drop policy if exists "Students update own submission and teachers grade" on public.submissions;
drop policy if exists "Students update own submission and assigned teachers grade" on public.submissions;
create policy "Students update own submission and assigned teachers grade" on public.submissions for update to authenticated using(student_id=auth.uid() or public.is_campus_admin() or exists(select 1 from public.assignments a where a.id=assignment_id and (public.teaches_class_direct(a.class_id) or public.teaches_class_subject(a.class_id,a.class_subject_id)))) with check(student_id=auth.uid() or public.is_campus_admin() or exists(select 1 from public.assignments a where a.id=assignment_id and (public.teaches_class_direct(a.class_id) or public.teaches_class_subject(a.class_id,a.class_subject_id))));
drop policy if exists "Students rate teachers and teachers rate students" on public.reviews;
drop policy if exists "Students rate their class teachers and teachers rate students" on public.reviews;
create policy "Students rate their class teachers and teachers rate students" on public.reviews for insert to authenticated with check(reviewer_id=auth.uid() and public.account_is_active() and ((public.current_role()='student' and reviews.reviewer_role='student' and public.is_active_student_in(reviews.class_id) and (exists(select 1 from public.class_teachers ct where ct.class_id=reviews.class_id and ct.teacher_id=reviews.subject_id) or exists(select 1 from public.class_subjects cs join public.branch_teachers bt on bt.branch_id=cs.branch_id and bt.subject_id=cs.subject_id where cs.class_id=reviews.class_id and bt.teacher_id=reviews.subject_id))) or (public.current_role()='teacher' and reviews.reviewer_role='teacher' and public.teaches_class(reviews.class_id) and exists(select 1 from public.class_memberships cm where cm.class_id=reviews.class_id and cm.student_id=reviews.subject_id and cm.status='active'))));
drop policy if exists "Class members read class materials" on storage.objects;
create policy "Class members read class materials" on storage.objects for select to authenticated using(bucket_id='class-materials' and name ~ '^[0-9a-fA-F-]{36}/' and (public.is_campus_admin() or public.is_active_student_in(split_part(name,'/',1)::uuid) or public.teaches_class_direct(split_part(name,'/',1)::uuid) or (name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/' and public.teaches_class_subject(split_part(name,'/',1)::uuid,split_part(name,'/',2)::uuid))));
drop policy if exists "Class teachers upload or delete class materials" on storage.objects;
create policy "Class teachers upload or delete class materials" on storage.objects for all to authenticated using(bucket_id='class-materials' and name ~ '^[0-9a-fA-F-]{36}/' and (public.is_campus_admin() or public.teaches_class_direct(split_part(name,'/',1)::uuid) or (name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/' and public.teaches_class_subject(split_part(name,'/',1)::uuid,split_part(name,'/',2)::uuid)))) with check(bucket_id='class-materials' and name ~ '^[0-9a-fA-F-]{36}/' and (public.is_campus_admin() or public.teaches_class_direct(split_part(name,'/',1)::uuid) or (name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/' and public.teaches_class_subject(split_part(name,'/',1)::uuid,split_part(name,'/',2)::uuid))));
drop policy if exists "Students read their own assignment submissions and teachers read class work" on storage.objects;
drop policy if exists "Students read their own assignment submissions and assigned teachers read class work" on storage.objects;
create policy "Students read their own assignment submissions and assigned teachers read class work" on storage.objects for select to authenticated using(bucket_id='assignment-submissions' and name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/' and (split_part(name,'/',2)=auth.uid()::text or public.is_campus_admin() or exists(select 1 from public.assignments a where a.id=split_part(name,'/',1)::uuid and (public.teaches_class_direct(a.class_id) or public.teaches_class_subject(a.class_id,a.class_subject_id)))));
