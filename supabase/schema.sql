-- Master Campus PostgreSQL schema for Supabase.
-- Apply in Supabase SQL Editor. Government ID numbers are intentionally not stored here.
create extension if not exists pgcrypto;

-- Enum creation is guarded so a previous partial SQL Editor run can be resumed.
do $$ begin
  create type public.campus_role as enum ('student','teacher','admin','platform_admin');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type public.account_state as enum ('pending','active','suspended');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type public.membership_state as enum ('pending','active','rejected','left');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type public.session_state as enum ('scheduled','held','suspended');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type public.attendance_state as enum ('present','absent','late','excused');
exception when duplicate_object then null;
end $$;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.campus_role not null default 'student',
  account_status public.account_state not null default 'active',
  full_name text not null default '',
  email text not null default '',
  mobile text,
  gender text,
  address text,
  campus_id text unique,
  department text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Platform owner creates campuses; campus admins are explicitly assigned per campus.
create table if not exists public.platform_admins (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  granted_by uuid references public.profiles(id), granted_at timestamptz not null default now()
);
create table if not exists public.campuses (
  id uuid primary key default gen_random_uuid(),
  campus_code text not null unique,
  name text not null,
  address text,
  created_by uuid not null references public.profiles(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.campus_admins (
  campus_id uuid not null references public.campuses(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  granted_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  primary key(campus_id,user_id)
);
create table if not exists public.academic_sessions (
  id uuid primary key default gen_random_uuid(),
  campus_id uuid not null references public.campuses(id) on delete cascade,
  name text not null, starts_on date, ends_on date, is_active boolean not null default true,
  created_at timestamptz not null default now(), unique(campus_id,name), unique(campus_id,id)
);
create table if not exists public.campus_enrollments (
  id uuid primary key default gen_random_uuid(),
  campus_id uuid not null references public.campuses(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  branch_id uuid,
  session_id uuid references public.academic_sessions(id),
  student_code text,
  college_registration_number text,
  status public.account_state not null default 'pending',
  requested_at timestamptz not null default now(),
  reviewed_by uuid references public.profiles(id), reviewed_at timestamptz,
  unique(campus_id,user_id),
  -- The app code and the college-issued number are separate campus-scoped keys.
  unique(campus_id,student_code),
  -- Candidate key used to identify the student by their college registration.
  unique(campus_id,college_registration_number)
);
create sequence if not exists public.campus_student_code_seq;

-- Campus organisation: an admin owns branches; each branch offers subjects.
create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(),
  campus_id uuid not null references public.campuses(id) on delete cascade,
  name text not null,
  code text not null,
  description text,
  created_by uuid not null references public.profiles(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(campus_id,code), unique(campus_id,id)
);
-- A campus session can offer several branches; a branch can run in several sessions.
create table if not exists public.session_branches (
  campus_id uuid not null references public.campuses(id) on delete cascade,
  session_id uuid not null,
  branch_id uuid not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key(session_id,branch_id),
  foreign key(campus_id,session_id) references public.academic_sessions(campus_id,id) on delete cascade,
  foreign key(campus_id,branch_id) references public.branches(campus_id,id) on delete cascade
);
-- Older branch tables did not have a campus owner; add it during an in-place upgrade.
alter table public.branches
  add column if not exists campus_id uuid references public.campuses(id) on delete cascade;
do $$ begin alter table public.campus_enrollments add constraint campus_enrollments_branch_fk foreign key(branch_id) references public.branches(id) on delete set null; exception when duplicate_object then null; end $$;
create table if not exists public.subjects (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id) on delete cascade,
  name text not null,
  code text not null,
  created_at timestamptz not null default now(),
  unique(branch_id,code), unique(branch_id,name), unique(branch_id,id)
);
create table if not exists public.branch_teachers (
  branch_id uuid not null references public.branches(id) on delete cascade,
  subject_id uuid not null,
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  assigned_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  primary key(branch_id,subject_id,teacher_id),
  foreign key(branch_id,subject_id) references public.subjects(branch_id,id) on delete cascade
);

create table if not exists public.classes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  department text not null,
  course_level text,
  term text,
  description text,
  branch_id uuid not null references public.branches(id),
  academic_session_id uuid not null references public.academic_sessions(id),
  created_by uuid not null references public.profiles(id),
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  unique(id,branch_id)
);
-- Upgrade older branch/class schemas in place; the column can stay nullable for legacy rows.
alter table public.classes
  add column if not exists academic_session_id uuid references public.academic_sessions(id);
create or replace function public.validate_class_campus_session() returns trigger language plpgsql set search_path=public as $$
begin
 if not exists(select 1 from public.session_branches sb join public.academic_sessions s on s.id=sb.session_id join public.branches b on b.id=sb.branch_id where sb.session_id=new.academic_session_id and sb.branch_id=new.branch_id and s.is_active and b.is_active) then
  raise exception 'Choose a branch linked to this active academic session';
 end if;
 return new;
end $$;
drop trigger if exists validate_class_campus_session on public.classes;
create trigger validate_class_campus_session before insert or update of branch_id,academic_session_id on public.classes for each row execute function public.validate_class_campus_session();
create table if not exists public.class_subjects (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  branch_id uuid not null,
  subject_id uuid not null,
  created_at timestamptz not null default now(),
  unique(class_id,subject_id), unique(class_id,id),
  foreign key(class_id,branch_id) references public.classes(id,branch_id) on delete cascade,
  foreign key(branch_id,subject_id) references public.subjects(branch_id,id) on delete cascade
);
create table if not exists public.class_teachers (
  class_id uuid not null references public.classes(id) on delete cascade,
  teacher_id uuid not null references public.profiles(id) on delete cascade,
  added_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  primary key(class_id,teacher_id)
);
create table if not exists public.class_memberships (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  status public.membership_state not null default 'pending',
  registration_number text,
  requested_at timestamptz not null default now(),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  unique(class_id,student_id)
);

create table if not exists public.class_routines (
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references public.classes(id) on delete cascade,
  class_subject_id uuid not null,
  teacher_id uuid not null references public.profiles(id),
  weekday smallint not null check(weekday between 0 and 6),
  starts_at time not null,
  ends_at time not null check(ends_at>starts_at),
  room text,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  foreign key(class_id,class_subject_id) references public.class_subjects(class_id,id) on delete cascade
);

create table if not exists public.syllabus_units (
  id uuid primary key default gen_random_uuid(), class_id uuid not null references public.classes(id) on delete cascade,
  class_subject_id uuid,
  title text not null, description text, sort_order integer not null default 0, due_date date,
  created_by uuid not null references public.profiles(id), created_at timestamptz not null default now()
);
create table if not exists public.study_progress (
  id uuid primary key default gen_random_uuid(), unit_id uuid not null references public.syllabus_units(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade, is_complete boolean not null default false,
  updated_at timestamptz not null default now(), unique(unit_id,student_id)
);
create table if not exists public.assignments (
  id uuid primary key default gen_random_uuid(), class_id uuid not null references public.classes(id) on delete cascade,
  class_subject_id uuid,
  title text not null, description text, due_at timestamptz, max_score numeric(7,2),
  created_by uuid not null references public.profiles(id), created_at timestamptz not null default now()
);
create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(), assignment_id uuid not null references public.assignments(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade, storage_path text, submitted_at timestamptz,
  score numeric(7,2), teacher_feedback text, unique(assignment_id,student_id)
);
create table if not exists public.materials (
  id uuid primary key default gen_random_uuid(), class_id uuid not null references public.classes(id) on delete cascade,
  class_subject_id uuid,
  title text not null, description text, content_text text, storage_path text not null, mime_type text, file_size bigint,
  uploaded_by uuid not null references public.profiles(id), created_at timestamptz not null default now()
);
create table if not exists public.attendance_sessions (
  id uuid primary key default gen_random_uuid(), class_id uuid not null references public.classes(id) on delete cascade,
  class_subject_id uuid,
  session_date date not null, state public.session_state not null default 'scheduled', note text,
  recorded_by uuid references public.profiles(id), recorded_at timestamptz,
  unique(class_id,session_date)
);
create table if not exists public.attendance_records (
  id uuid primary key default gen_random_uuid(), session_id uuid not null references public.attendance_sessions(id) on delete cascade,
  student_id uuid not null references public.profiles(id) on delete cascade,
  status public.attendance_state not null, note text, marked_by uuid references public.profiles(id),
  created_at timestamptz not null default now(), unique(session_id,student_id)
);
do $$ begin alter table public.syllabus_units add constraint syllabus_class_subject_fk foreign key(class_id,class_subject_id) references public.class_subjects(class_id,id); exception when duplicate_object then null; end $$;
do $$ begin alter table public.assignments add constraint assignments_class_subject_fk foreign key(class_id,class_subject_id) references public.class_subjects(class_id,id); exception when duplicate_object then null; end $$;
do $$ begin alter table public.materials add constraint materials_class_subject_fk foreign key(class_id,class_subject_id) references public.class_subjects(class_id,id); exception when duplicate_object then null; end $$;
do $$ begin alter table public.attendance_sessions add constraint attendance_class_subject_fk foreign key(class_id,class_subject_id) references public.class_subjects(class_id,id); exception when duplicate_object then null; end $$;
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(), class_id uuid not null references public.classes(id) on delete cascade,
  reviewer_id uuid not null references public.profiles(id) on delete cascade,
  subject_id uuid not null references public.profiles(id) on delete cascade,
  reviewer_role public.campus_role not null, rating smallint not null check(rating between 1 and 5),
  body text, review_month date not null default date_trunc('month',current_date)::date,
  created_at timestamptz not null default now(), unique(class_id,reviewer_id,subject_id,review_month)
);
create table if not exists public.notices (
  id uuid primary key default gen_random_uuid(), title text not null, body text not null,
  campus_id uuid references public.campuses(id) on delete cascade,
  audience_role public.campus_role, department text, class_id uuid references public.classes(id) on delete cascade,
  created_by uuid not null references public.profiles(id), published_at timestamptz not null default now(), expires_at timestamptz
);
alter table public.notices
  add column if not exists campus_id uuid references public.campuses(id) on delete cascade;
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(), title text not null, description text,
  campus_id uuid references public.campuses(id) on delete cascade,
  starts_at timestamptz not null, ends_at timestamptz, location text,
  created_by uuid not null references public.profiles(id), created_at timestamptz not null default now()
);
alter table public.events
  add column if not exists campus_id uuid references public.campuses(id) on delete cascade;
create table if not exists public.generated_quizzes (
  id uuid primary key default gen_random_uuid(), class_id uuid not null references public.classes(id) on delete cascade,
  material_id uuid references public.materials(id) on delete set null,
  student_id uuid not null references public.profiles(id) on delete cascade,
  title text not null, questions jsonb not null, score numeric(7,2), completed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists class_memberships_student_idx on public.class_memberships(student_id,status);
create index if not exists attendance_session_date_idx on public.attendance_sessions(class_id,session_date desc);
create index if not exists attendance_student_idx on public.attendance_records(student_id);
create index if not exists materials_class_idx on public.materials(class_id,created_at desc);
create index if not exists assignments_class_idx on public.assignments(class_id,due_at);

create or replace function public.current_role() returns public.campus_role language sql stable security definer set search_path=public as $$ select role from public.profiles where id=auth.uid() $$;
create or replace function public.account_is_active() returns boolean language sql stable security definer set search_path=public as $$ select coalesce((select account_status='active' from public.profiles where id=auth.uid()),false) $$;
create or replace function public.is_platform_admin() returns boolean language sql stable security definer set search_path=public as $$ select public.current_role()='platform_admin' and public.account_is_active() $$;
create or replace function public.is_campus_admin() returns boolean language sql stable security definer set search_path=public as $$ select public.is_platform_admin() $$;
create or replace function public.is_campus_admin_for(target_campus uuid) returns boolean language sql stable security definer set search_path=public as $$
 select public.is_platform_admin() or (public.current_role()='admin' and public.account_is_active() and exists(select 1 from public.campus_admins ca where ca.campus_id=target_campus and ca.user_id=auth.uid()))
$$;
create or replace function public.campus_for_branch(target_branch uuid) returns uuid language sql stable security definer set search_path=public as $$ select b.campus_id from public.branches b where b.id=target_branch $$;
create or replace function public.campus_for_class(target_class uuid) returns uuid language sql stable security definer set search_path=public as $$ select b.campus_id from public.classes c join public.branches b on b.id=c.branch_id where c.id=target_class $$;
create or replace function public.is_campus_admin_for_class(target_class uuid) returns boolean language sql stable security definer set search_path=public as $$ select public.is_campus_admin_for(public.campus_for_class(target_class)) $$;
create or replace function public.create_campus_class(p_class_data jsonb,p_subject_ids uuid[])
returns public.classes language plpgsql security definer set search_path=public,pg_temp as $$
declare actor_id uuid:=auth.uid();target_branch uuid:=(p_class_data->>'branch_id')::uuid;target_session uuid:=(p_class_data->>'academic_session_id')::uuid;target_campus uuid;target_subject uuid;created_class public.classes;
begin
 if actor_id is null then raise exception 'Sign in as a campus admin to create a class'; end if;
 select b.campus_id into target_campus from public.branches b where b.id=target_branch and b.is_active;
 if target_campus is null then raise exception 'Selected branch is not active or has no campus'; end if;
 if not (public.is_platform_admin() or exists(select 1 from public.campus_admins ca join public.profiles p on p.id=ca.user_id where ca.campus_id=target_campus and ca.user_id=actor_id and p.role='admin' and p.account_status='active')) then raise exception 'Your admin account is not assigned to the selected branch campus'; end if;
 if not exists(select 1 from public.session_branches sb join public.academic_sessions s on s.id=sb.session_id and s.campus_id=sb.campus_id where sb.campus_id=target_campus and sb.branch_id=target_branch and sb.session_id=target_session and s.is_active) then raise exception 'Select an active academic session linked to this branch'; end if;
 if coalesce(array_length(p_subject_ids,1),0)=0 then raise exception 'Select at least one subject for this class'; end if;
 foreach target_subject in array p_subject_ids loop if not exists(select 1 from public.subjects s where s.id=target_subject and s.branch_id=target_branch) then raise exception 'A selected subject does not belong to the selected branch'; end if; end loop;
 insert into public.classes(code,name,department,course_level,term,description,branch_id,academic_session_id,created_by) values(upper(trim(p_class_data->>'code')),trim(p_class_data->>'name'),coalesce(nullif(trim(p_class_data->>'department'),''),''),nullif(trim(p_class_data->>'course_level'),''),nullif(trim(p_class_data->>'term'),''),nullif(trim(p_class_data->>'description'),''),target_branch,target_session,actor_id) returning * into created_class;
 foreach target_subject in array p_subject_ids loop insert into public.class_subjects(class_id,branch_id,subject_id) values(created_class.id,target_branch,target_subject) on conflict(class_id,subject_id) do nothing; end loop;
 insert into public.class_teachers(class_id,teacher_id,added_by) select created_class.id,bt.teacher_id,actor_id from public.branch_teachers bt where bt.branch_id=target_branch and bt.subject_id=any(p_subject_ids) on conflict(class_id,teacher_id) do nothing;
 return created_class;
end $$;
revoke all on function public.create_campus_class(jsonb,uuid[]) from public;
grant execute on function public.create_campus_class(jsonb,uuid[]) to authenticated;
create or replace function public.is_campus_member(target_campus uuid) returns boolean language sql stable security definer set search_path=public as $$
 select public.is_platform_admin() or public.is_campus_admin_for(target_campus) or exists(select 1 from public.campus_enrollments e where e.campus_id=target_campus and e.user_id=auth.uid() and e.status='active')
$$;
create or replace function public.is_campus_admin_for_profile(target_user uuid) returns boolean language sql stable security definer set search_path=public as $$
 select public.is_platform_admin() or exists(select 1 from public.campus_admins own where own.user_id=auth.uid() and (target_user=own.user_id or exists(select 1 from public.campus_enrollments e where e.user_id=target_user and e.campus_id=own.campus_id) or exists(select 1 from public.campus_admins other where other.user_id=target_user and other.campus_id=own.campus_id)))
$$;
create or replace function public.my_campus_id() returns uuid language sql stable security definer set search_path=public as $$
 select campus_id from public.campus_admins where user_id=auth.uid() order by created_at limit 1
$$;
create or replace function public.assign_campus_admin(target_campus uuid,admin_email text) returns void language plpgsql security definer set search_path=public as $$
declare target_user uuid;
begin
 if not public.is_platform_admin() then raise exception 'Only a platform administrator can assign campus administrators'; end if;
 select id into target_user from public.profiles where lower(email)=lower(trim(admin_email));
 if target_user is null then raise exception 'Create this person account first, then assign campus access'; end if;
 if not exists(select 1 from public.campuses where id=target_campus and is_active) then raise exception 'Campus was not found or is inactive'; end if;
 if exists(select 1 from public.campus_admins where user_id=target_user and campus_id<>target_campus) then raise exception 'This account is already assigned to a different campus'; end if;
 update public.profiles set role='admin',account_status='active' where id=target_user;
 insert into public.campus_admins(campus_id,user_id,granted_by) values(target_campus,target_user,auth.uid()) on conflict do nothing;
 update public.campus_enrollments set status='active',reviewed_by=auth.uid(),reviewed_at=now() where campus_id=target_campus and user_id=target_user;
end $$;
create or replace function public.review_campus_enrollment(target_enrollment uuid,approve boolean) returns void language plpgsql security definer set search_path=public as $$
declare enrollment public.campus_enrollments;
begin
 select * into enrollment from public.campus_enrollments where id=target_enrollment;
 if not found or not public.is_campus_admin_for(enrollment.campus_id) then raise exception 'You do not have access to this campus registration'; end if;
 update public.campus_enrollments set status=case when approve then 'active'::public.account_state else 'suspended'::public.account_state end,reviewed_by=auth.uid(),reviewed_at=now() where id=target_enrollment;
 update public.profiles set account_status=case when approve then 'active'::public.account_state else 'suspended'::public.account_state end where id=enrollment.user_id;
end $$;
create or replace function public.create_campus(campus_name text,campus_address text default null) returns public.campuses language plpgsql security definer set search_path=public as $$
declare result public.campuses;
begin
 if not public.is_platform_admin() then raise exception 'Only a platform administrator can create campuses'; end if;
 insert into public.campuses(campus_code,name,address,created_by)
 values('MC-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),trim(campus_name),nullif(trim(campus_address),''),auth.uid()) returning * into result;
 return result;
end $$;
create or replace function public.enroll_signup_user() returns trigger language plpgsql security definer set search_path=public as $$
declare c public.campuses; branch_value uuid; session_value uuid; generated_code text;
begin
 if new.role not in ('student','teacher') then return new; end if;
 select * into c from public.campuses where upper(campus_code)=upper(coalesce(new.raw_user_meta_data->>'campus_code','')) and is_active;
 if not found then
  if nullif(trim(coalesce(new.raw_user_meta_data->>'campus_code','')),'') is null then return new; end if;
  raise exception 'Campus ID was not found or is inactive';
 end if;
 if new.raw_user_meta_data->>'branch_id' is not null then
  select id into branch_value from public.branches where id=(new.raw_user_meta_data->>'branch_id')::uuid and campus_id=c.id and is_active;
  if branch_value is null then raise exception 'Selected branch does not belong to this campus'; end if;
 end if;
 if new.raw_user_meta_data->>'session_id' is not null then
  select id into session_value from public.academic_sessions where id=(new.raw_user_meta_data->>'session_id')::uuid and campus_id=c.id and is_active;
  if session_value is null then raise exception 'Selected session does not belong to this campus'; end if;
 end if;
 if coalesce(new.raw_user_meta_data->>'requested_role','student')='student' then
  generated_code:=c.campus_code||'-'||lpad(nextval('public.campus_student_code_seq')::text,6,'0');
  insert into public.campus_enrollments(campus_id,user_id,branch_id,session_id,student_code,status) values(c.id,new.id,branch_value,session_value,generated_code,'pending');
  update public.profiles set campus_id=generated_code,account_status='pending' where id=new.id;
 else
  insert into public.campus_enrollments(campus_id,user_id,branch_id,session_id,status) values(c.id,new.id,branch_value,session_value,'pending');
  update public.profiles set account_status='pending' where id=new.id;
 end if;
 return new;
end $$;
drop trigger if exists on_auth_user_enroll on auth.users;
create trigger on_auth_user_enroll after insert on auth.users for each row execute function public.enroll_signup_user();
create or replace function public.teaches_class_direct(target uuid) returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from public.class_teachers ct join public.profiles p on p.id=ct.teacher_id where ct.class_id=target and ct.teacher_id=auth.uid() and p.role='teacher' and p.account_status='active') $$;
create or replace function public.teaches_class(target uuid) returns boolean language sql stable security definer set search_path=public as $$ select public.teaches_class_direct(target) $$;
create or replace function public.teaches_class_subject(target_class uuid,target_subject uuid) returns boolean language sql stable security definer set search_path=public as $$ select public.teaches_class_direct(target_class) $$;
create or replace function public.is_active_student_in(target uuid) returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from public.class_memberships cm join public.profiles p on p.id=cm.student_id where cm.class_id=target and cm.student_id=auth.uid() and cm.status='active' and p.role='student' and p.account_status='active') $$;
revoke all on function public.current_role(), public.account_is_active(), public.is_platform_admin(), public.is_campus_admin(), public.is_campus_admin_for(uuid), public.campus_for_branch(uuid), public.campus_for_class(uuid), public.is_campus_admin_for_class(uuid), public.is_campus_member(uuid), public.is_campus_admin_for_profile(uuid), public.my_campus_id(), public.assign_campus_admin(uuid,text), public.create_campus(text,text), public.review_campus_enrollment(uuid,boolean), public.teaches_class(uuid), public.teaches_class_direct(uuid), public.teaches_class_subject(uuid,uuid), public.is_active_student_in(uuid) from public;
grant execute on function public.current_role(), public.account_is_active(), public.is_platform_admin(), public.is_campus_admin(), public.is_campus_admin_for(uuid), public.campus_for_branch(uuid), public.campus_for_class(uuid), public.is_campus_admin_for_class(uuid), public.is_campus_member(uuid), public.is_campus_admin_for_profile(uuid), public.my_campus_id(), public.assign_campus_admin(uuid,text), public.create_campus(text,text), public.review_campus_enrollment(uuid,boolean), public.teaches_class(uuid), public.teaches_class_direct(uuid), public.teaches_class_subject(uuid,uuid), public.is_active_student_in(uuid) to authenticated;

-- Provision a profile from Supabase Auth metadata. Campus-admin signup creates
-- an isolated campus; public signup cannot create a platform administrator.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare requested text; new_role public.campus_role; new_state public.account_state; created_campus public.campuses;
begin
  if coalesce(new.raw_app_meta_data->>'platform_admin','false')='true' then
    new_role := 'platform_admin'::public.campus_role;
    new_state := 'active'::public.account_state;
  else
  requested := coalesce(new.raw_user_meta_data->>'requested_role','student');
  if requested not in ('student','teacher','admin') then requested := 'student'; end if;
  new_role := requested::public.campus_role;
  new_state := case when new_role='teacher' then 'pending'::public.account_state else 'active'::public.account_state end;
  end if;
  insert into public.profiles(id,role,account_status,full_name,email,mobile,gender,address,campus_id,department)
  values(new.id,new_role,new_state,coalesce(new.raw_user_meta_data->>'full_name',''),coalesce(new.email,''),
    nullif(new.raw_user_meta_data->>'mobile',''),nullif(new.raw_user_meta_data->>'gender',''),
    nullif(new.raw_user_meta_data->>'address',''),case when new_role='admin' then nullif(new.raw_user_meta_data->>'campus_id','') else null end,nullif(new.raw_user_meta_data->>'department',''));
  if new_role='platform_admin' then
    insert into public.platform_admins(user_id) values(new.id) on conflict do nothing;
  elsif new_role='admin' then
    if nullif(trim(coalesce(new.raw_user_meta_data->>'campus_name','')),'') is null then
      raise exception 'Enter a campus name to create the campus administrator account';
    end if;
    insert into public.campuses(campus_code,name,address,created_by)
    values('MC-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),trim(new.raw_user_meta_data->>'campus_name'),nullif(trim(new.raw_user_meta_data->>'campus_address'),''),new.id)
    returning * into created_campus;
    insert into public.campus_admins(campus_id,user_id,granted_by) values(created_campus.id,new.id,new.id);
    update public.profiles set campus_id=created_campus.campus_code where id=new.id;
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create or replace function public.protect_profile_privileges() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is not null and pg_trigger_depth()=1 and not public.is_platform_admin() and new.role is distinct from old.role then
   raise exception 'Only the Platform Admin can change account roles';
 end if;
 if auth.uid() is not null and pg_trigger_depth()=1 and not public.is_platform_admin() and not public.is_campus_admin_for_profile(old.id) and new.account_status is distinct from old.account_status then
   raise exception 'Role and account status are managed by campus administration';
 end if;
 new.updated_at := now(); return new;
end $$;
drop trigger if exists protect_profile_privileges on public.profiles;
create trigger protect_profile_privileges before update on public.profiles for each row execute function public.protect_profile_privileges();

alter table public.profiles enable row level security;
alter table public.platform_admins enable row level security;
alter table public.campuses enable row level security;
alter table public.campus_admins enable row level security;
alter table public.academic_sessions enable row level security;
alter table public.session_branches enable row level security;
alter table public.campus_enrollments enable row level security;
alter table public.branches enable row level security;
alter table public.subjects enable row level security;
alter table public.branch_teachers enable row level security;
alter table public.classes enable row level security;
alter table public.class_subjects enable row level security;
alter table public.class_routines enable row level security;
alter table public.class_teachers enable row level security;
alter table public.class_memberships enable row level security;
alter table public.syllabus_units enable row level security;
alter table public.study_progress enable row level security;
alter table public.assignments enable row level security;
alter table public.submissions enable row level security;
alter table public.materials enable row level security;
alter table public.attendance_sessions enable row level security;
alter table public.attendance_records enable row level security;
alter table public.reviews enable row level security;
alter table public.notices enable row level security;
alter table public.events enable row level security;
alter table public.generated_quizzes enable row level security;

drop policy if exists "Profiles visible to self, campus admins, and shared class teachers" on public.profiles;
create policy "Profiles visible to self, campus admins, and shared class teachers" on public.profiles for select to authenticated using (
 id=auth.uid() or public.is_platform_admin() or public.is_campus_admin_for_profile(id) or exists(
  select 1 from public.class_memberships cm where cm.student_id=profiles.id and cm.status='active' and public.teaches_class(cm.class_id)
 ) or exists(select 1 from public.class_teachers ct where ct.teacher_id=profiles.id and ct.teacher_id=auth.uid())
 or (public.current_role()='student' and exists(select 1 from public.class_teachers ct where ct.teacher_id=profiles.id and public.is_active_student_in(ct.class_id)))
);
drop policy if exists "Users can update their own contact profile" on public.profiles;
drop policy if exists "Users can update their own contact profile" on public.profiles;
create policy "Users can update their own contact profile" on public.profiles for update to authenticated using(id=auth.uid() or public.is_platform_admin() or public.is_campus_admin_for_profile(id)) with check(id=auth.uid() or public.is_platform_admin() or public.is_campus_admin_for_profile(id));
drop policy if exists "Platform administrators read platform access" on public.platform_admins;
drop policy if exists "Platform administrators read platform access" on public.platform_admins;
create policy "Platform administrators read platform access" on public.platform_admins for select to authenticated using(public.is_platform_admin() or user_id=auth.uid());
drop policy if exists "Platform administrators manage campuses" on public.campuses;
drop policy if exists "Platform administrators manage campuses" on public.campuses;
create policy "Platform administrators manage campuses" on public.campuses for all to authenticated using(public.is_platform_admin()) with check(public.is_platform_admin());
drop policy if exists "Public may find active campuses by ID" on public.campuses;
drop policy if exists "Public may find active campuses by ID" on public.campuses;
create policy "Public may find active campuses by ID" on public.campuses for select to anon,authenticated using(is_active);
drop policy if exists "Platform administrators manage campus admins" on public.campus_admins;
drop policy if exists "Platform administrators manage campus admins" on public.campus_admins;
create policy "Platform administrators manage campus admins" on public.campus_admins for all to authenticated using(public.is_platform_admin()) with check(public.is_platform_admin());
drop policy if exists "Campus admins can identify their assigned campus" on public.campus_admins;
drop policy if exists "Campus admins can identify their assigned campus" on public.campus_admins;
create policy "Campus admins can identify their assigned campus" on public.campus_admins for select to authenticated using(user_id=auth.uid());
drop policy if exists "Campus users read active sessions" on public.academic_sessions;
drop policy if exists "Campus users read active sessions" on public.academic_sessions;
create policy "Campus users read active sessions" on public.academic_sessions for select to anon,authenticated using(is_active);
drop policy if exists "Platform administrators manage sessions" on public.academic_sessions;
drop policy if exists "Platform administrators manage sessions" on public.academic_sessions;
create policy "Platform administrators manage sessions" on public.academic_sessions for all to authenticated using(public.is_platform_admin()) with check(public.is_platform_admin());
drop policy if exists "Campus admins manage their academic sessions" on public.academic_sessions;
create policy "Campus admins manage their academic sessions" on public.academic_sessions for all to authenticated using(public.is_campus_admin_for(campus_id)) with check(public.is_campus_admin_for(campus_id));
drop policy if exists "Public can see active session branches" on public.session_branches;
create policy "Public can see active session branches" on public.session_branches for select to anon,authenticated using(exists(select 1 from public.academic_sessions s join public.branches b on b.campus_id=s.campus_id where s.id=session_branches.session_id and b.id=session_branches.branch_id and s.is_active and b.is_active));
drop policy if exists "Campus admins add session branches" on public.session_branches;
create policy "Campus admins add session branches" on public.session_branches for insert to authenticated with check(public.is_campus_admin_for(campus_id));
grant select on public.session_branches to anon,authenticated;
grant insert on public.session_branches to authenticated;
drop policy if exists "Enrollment visible to student and platform admins" on public.campus_enrollments;
drop policy if exists "Enrollment visible to student and platform admins" on public.campus_enrollments;
create policy "Enrollment visible to student and platform admins" on public.campus_enrollments for select to authenticated using(user_id=auth.uid() or public.is_campus_admin_for(campus_id));
drop policy if exists "Campus admins review campus enrollments" on public.campus_enrollments;
drop policy if exists "Campus admins review campus enrollments" on public.campus_enrollments;
create policy "Campus admins review campus enrollments" on public.campus_enrollments for update to authenticated using(public.is_campus_admin_for(campus_id)) with check(public.is_campus_admin_for(campus_id));
drop policy if exists "Campus admins see enrolled profiles" on public.profiles;
drop policy if exists "Campus admins see enrolled profiles" on public.profiles;
create policy "Campus admins see enrolled profiles" on public.profiles for select to authenticated using(public.is_campus_admin_for_profile(id));
drop policy if exists "Campus admins update enrolled profiles" on public.profiles;
drop policy if exists "Campus admins update enrolled profiles" on public.profiles;
create policy "Campus admins update enrolled profiles" on public.profiles for update to authenticated using(public.is_campus_admin_for_profile(id)) with check(public.is_campus_admin_for_profile(id));
create or replace function public.protect_profile_authority_fields() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if pg_trigger_depth()=1 and new.campus_id is distinct from old.campus_id and auth.uid() is not null and not public.is_platform_admin() then
  raise exception 'The generated campus registration code cannot be changed from the profile';
 end if;
 if new.role is distinct from old.role and auth.uid() is not null and pg_trigger_depth()=1 and not public.is_platform_admin() then
  raise exception 'Only the Platform Admin can change account roles';
 end if;
 if new.account_status is distinct from old.account_status and auth.uid() is not null and pg_trigger_depth()=1 and not public.is_platform_admin() and not public.is_campus_admin_for_profile(old.id) then
  raise exception 'Only the campus administrator can change account status';
 end if;
 return new;
end $$;
drop trigger if exists protect_profile_authority_fields on public.profiles;
create trigger protect_profile_authority_fields before update on public.profiles for each row execute function public.protect_profile_authority_fields();
drop policy if exists "Active campus reads branches" on public.branches;
drop policy if exists "Active campus reads branches" on public.branches;
create policy "Active campus reads branches" on public.branches for select to authenticated using(is_active and public.is_campus_member(campus_id));
drop policy if exists "Visitors may find active campus branches" on public.branches;
drop policy if exists "Visitors may find active campus branches" on public.branches;
create policy "Visitors may find active campus branches" on public.branches for select to anon using(is_active);
drop policy if exists "Admins manage branches" on public.branches;
drop policy if exists "Admins manage branches" on public.branches;
create policy "Admins manage branches" on public.branches for all to authenticated using(public.is_campus_admin_for(campus_id)) with check(public.is_campus_admin_for(campus_id));
drop policy if exists "Active campus reads branch subjects" on public.subjects;
drop policy if exists "Active campus reads branch subjects" on public.subjects;
create policy "Active campus reads branch subjects" on public.subjects for select to authenticated using(public.is_campus_member((select campus_id from public.branches where id=branch_id)));
drop policy if exists "Visitors may find active campus subjects" on public.subjects;
drop policy if exists "Visitors may find active campus subjects" on public.subjects;
create policy "Visitors may find active campus subjects" on public.subjects for select to anon using(true);
drop policy if exists "Admins manage branch subjects" on public.subjects;
drop policy if exists "Admins manage branch subjects" on public.subjects;
create policy "Admins manage branch subjects" on public.subjects for all to authenticated using(public.is_campus_admin_for((select campus_id from public.branches where id=branch_id))) with check(public.is_campus_admin_for((select campus_id from public.branches where id=branch_id)));
drop policy if exists "Campus sees relevant branch subject assignments" on public.branch_teachers;
drop policy if exists "Campus sees relevant branch subject assignments" on public.branch_teachers;
create policy "Campus sees relevant branch subject assignments" on public.branch_teachers for select to authenticated using(public.is_campus_admin_for(public.campus_for_branch(branch_id)) or teacher_id=auth.uid() or exists(select 1 from public.class_subjects cs where cs.branch_id=branch_teachers.branch_id and cs.subject_id=branch_teachers.subject_id and public.is_active_student_in(cs.class_id)));
drop policy if exists "Admins manage branch teacher assignments" on public.branch_teachers;
drop policy if exists "Admins manage branch teacher assignments" on public.branch_teachers;
create policy "Admins manage branch teacher assignments" on public.branch_teachers for all to authenticated using(public.is_campus_admin_for(public.campus_for_branch(branch_id))) with check(public.is_campus_admin_for(public.campus_for_branch(branch_id)));
drop policy if exists "Campus reads class subjects" on public.class_subjects;
drop policy if exists "Campus reads class subjects" on public.class_subjects;
create policy "Campus reads class subjects" on public.class_subjects for select to authenticated using(public.is_campus_admin_for_class(class_id) or public.is_active_student_in(class_id) or public.teaches_class_subject(class_id,id));
drop policy if exists "Teachers attach their assigned subjects to classes" on public.class_subjects;
drop policy if exists "Teachers attach their assigned subjects to classes" on public.class_subjects;
create policy "Teachers attach their assigned subjects to classes" on public.class_subjects for insert to authenticated with check(public.is_campus_admin_for_class(class_id) or (exists(select 1 from public.classes c join public.branch_teachers bt on bt.branch_id=c.branch_id and bt.subject_id=class_subjects.subject_id where c.id=class_id and c.created_by=auth.uid() and bt.teacher_id=auth.uid())));
drop policy if exists "Admins manage class subjects" on public.class_subjects;
drop policy if exists "Admins manage class subjects" on public.class_subjects;
create policy "Admins manage class subjects" on public.class_subjects for all to authenticated using(public.is_campus_admin_for_class(class_id)) with check(public.is_campus_admin_for_class(class_id));
drop policy if exists "Campus reads class routines" on public.class_routines;
drop policy if exists "Campus reads class routines" on public.class_routines;
create policy "Campus reads class routines" on public.class_routines for select to authenticated using(public.is_campus_admin_for_class(class_id) or public.is_active_student_in(class_id) or public.teaches_class_subject(class_id,class_subject_id));
drop policy if exists "Assigned teachers manage their class routines" on public.class_routines;
drop policy if exists "Assigned teachers manage their class routines" on public.class_routines;
create policy "Assigned teachers manage their class routines" on public.class_routines for all to authenticated using(public.is_campus_admin_for_class(class_id) or (teacher_id=auth.uid() and public.teaches_class_subject(class_id,class_subject_id))) with check(public.is_campus_admin_for_class(class_id) or (teacher_id=auth.uid() and created_by=auth.uid() and public.teaches_class_subject(class_id,class_subject_id)));
drop policy if exists "Authenticated campus can list classes" on public.classes;
drop policy if exists "Authenticated campus can list classes" on public.classes;
create policy "Authenticated campus can list classes" on public.classes for select to authenticated using(not is_archived and (public.is_platform_admin() or public.is_campus_admin_for_class(id) or public.is_active_student_in(id) or public.teaches_class(id) or exists(select 1 from public.campus_enrollments e where e.campus_id=public.campus_for_branch(classes.branch_id) and e.branch_id=classes.branch_id and e.session_id=classes.academic_session_id and e.user_id=auth.uid() and e.status='active')));
drop policy if exists "Admins or assigned teachers create branch classes" on public.classes;
drop policy if exists "Admins or assigned teachers create branch classes" on public.classes;
create policy "Admins or assigned teachers create branch classes" on public.classes for insert to authenticated with check(public.is_campus_admin_for(public.campus_for_branch(branch_id)) or (created_by=auth.uid() and branch_id is not null and public.current_role()='teacher' and public.account_is_active() and exists(select 1 from public.branch_teachers bt where bt.branch_id=classes.branch_id and bt.teacher_id=auth.uid())));
drop policy if exists "Class teachers and admins update classes" on public.classes;
drop policy if exists "Class teachers and admins update classes" on public.classes;
create policy "Class teachers and admins update classes" on public.classes for update to authenticated using(public.is_campus_admin_for_class(id) or public.teaches_class(id)) with check(public.is_campus_admin_for_class(id) or public.teaches_class(id));
drop policy if exists "Class staff see teaching assignments" on public.class_teachers;
drop policy if exists "Class staff see teaching assignments" on public.class_teachers;
create policy "Class staff see teaching assignments" on public.class_teachers for select to authenticated using(public.is_campus_admin_for_class(class_id) or teacher_id=auth.uid() or public.teaches_class(class_id) or public.is_active_student_in(class_id));
drop policy if exists "Admins manage class teachers" on public.class_teachers;
drop policy if exists "Admins manage class teachers" on public.class_teachers;
create policy "Admins manage class teachers" on public.class_teachers for all to authenticated using(public.is_campus_admin_for_class(class_id)) with check(public.is_campus_admin_for_class(class_id));
drop policy if exists "Verified creator links self on legacy classes" on public.class_teachers;
create policy "Verified creator links self on legacy classes" on public.class_teachers for insert to authenticated with check(
 teacher_id=auth.uid() and public.current_role()='teacher' and public.account_is_active() and
 exists(select 1 from public.classes c where c.id=class_id and c.created_by=auth.uid() and c.branch_id is null)
);
drop policy if exists "Membership visible to student, class staff, admin" on public.class_memberships;
drop policy if exists "Membership visible to student, class staff, admin" on public.class_memberships;
create policy "Membership visible to student, class staff, admin" on public.class_memberships for select to authenticated using(student_id=auth.uid() or public.is_campus_admin_for_class(class_id) or public.teaches_class(class_id));
drop policy if exists "Students request their own class membership" on public.class_memberships;
drop policy if exists "Students request their own class membership" on public.class_memberships;
create policy "Students request their own class membership" on public.class_memberships for insert to authenticated with check(student_id=auth.uid() and public.current_role()='student' and public.account_is_active() and status='pending' and exists(select 1 from public.classes c join public.branches b on b.id=c.branch_id join public.campus_enrollments e on e.campus_id=b.campus_id and e.branch_id=c.branch_id and e.session_id=c.academic_session_id where c.id=class_id and e.user_id=auth.uid() and e.status='active'));
drop policy if exists "Class teachers review membership requests" on public.class_memberships;
drop policy if exists "Class teachers review membership requests" on public.class_memberships;
create policy "Class teachers review membership requests" on public.class_memberships for update to authenticated using(public.is_campus_admin_for_class(class_id) or public.teaches_class(class_id)) with check(public.is_campus_admin_for_class(class_id) or public.teaches_class(class_id));

drop policy if exists "Enrolled students and assigned subject teachers read syllabus" on public.syllabus_units;
drop policy if exists "Enrolled students and assigned subject teachers read syllabus" on public.syllabus_units;
create policy "Enrolled students and assigned subject teachers read syllabus" on public.syllabus_units for select to authenticated using(public.is_campus_admin_for_class(class_id) or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)) or public.is_active_student_in(class_id));
drop policy if exists "Assigned subject teachers manage syllabus" on public.syllabus_units;
drop policy if exists "Assigned subject teachers manage syllabus" on public.syllabus_units;
create policy "Assigned subject teachers manage syllabus" on public.syllabus_units for all to authenticated using(public.is_campus_admin_for_class(class_id) or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id))) with check(public.is_campus_admin_for_class(class_id) or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)));
drop policy if exists "Students manage own learning progress" on public.study_progress;
drop policy if exists "Students manage own learning progress" on public.study_progress;
create policy "Students manage own learning progress" on public.study_progress for all to authenticated using(student_id=auth.uid() and public.is_active_student_in((select class_id from public.syllabus_units where id=unit_id))) with check(student_id=auth.uid() and public.is_active_student_in((select class_id from public.syllabus_units where id=unit_id)));
drop policy if exists "Class members and assigned subject teachers read assignments" on public.assignments;
drop policy if exists "Class members and assigned subject teachers read assignments" on public.assignments;
create policy "Class members and assigned subject teachers read assignments" on public.assignments for select to authenticated using(public.is_campus_admin_for_class(class_id) or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)) or public.is_active_student_in(class_id));
drop policy if exists "Assigned subject teachers manage assignments" on public.assignments;
drop policy if exists "Assigned subject teachers manage assignments" on public.assignments;
create policy "Assigned subject teachers manage assignments" on public.assignments for all to authenticated using(public.is_campus_admin_for_class(class_id) or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id))) with check(public.is_campus_admin_for_class(class_id) or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)));
drop policy if exists "Students and assigned subject staff read submissions" on public.submissions;
drop policy if exists "Students and assigned subject staff read submissions" on public.submissions;
create policy "Students and assigned subject staff read submissions" on public.submissions for select to authenticated using(student_id=auth.uid() or public.is_platform_admin() or exists(select 1 from public.assignments a where a.id=assignment_id and (public.is_campus_admin_for_class(a.class_id) or public.teaches_class_direct(a.class_id) or public.teaches_class_subject(a.class_id,a.class_subject_id))));
drop policy if exists "Students submit own assignment" on public.submissions;
drop policy if exists "Students submit own assignment" on public.submissions;
create policy "Students submit own assignment" on public.submissions for insert to authenticated with check(student_id=auth.uid() and exists(select 1 from public.assignments a where a.id=assignment_id and public.is_active_student_in(a.class_id)));
drop policy if exists "Students update own submission and assigned teachers grade" on public.submissions;
drop policy if exists "Students update own submission and assigned teachers grade" on public.submissions;
create policy "Students update own submission and assigned teachers grade" on public.submissions for update to authenticated using(student_id=auth.uid() or public.is_platform_admin() or exists(select 1 from public.assignments a where a.id=assignment_id and (public.is_campus_admin_for_class(a.class_id) or public.teaches_class_direct(a.class_id) or public.teaches_class_subject(a.class_id,a.class_subject_id)))) with check(student_id=auth.uid() or public.is_platform_admin() or exists(select 1 from public.assignments a where a.id=assignment_id and (public.is_campus_admin_for_class(a.class_id) or public.teaches_class_direct(a.class_id) or public.teaches_class_subject(a.class_id,a.class_subject_id))));
drop policy if exists "Enrolled class and assigned teachers read materials" on public.materials;
drop policy if exists "Enrolled class and assigned teachers read materials" on public.materials;
create policy "Enrolled class and assigned teachers read materials" on public.materials for select to authenticated using(public.is_campus_admin_for_class(class_id) or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)) or public.is_active_student_in(class_id));
drop policy if exists "Assigned subject teachers manage materials" on public.materials;
drop policy if exists "Assigned subject teachers manage materials" on public.materials;
create policy "Assigned subject teachers manage materials" on public.materials for all to authenticated using(public.is_campus_admin_for_class(class_id) or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id))) with check(public.is_campus_admin_for_class(class_id) or (class_subject_id is null and public.teaches_class_direct(class_id)) or (class_subject_id is not null and public.teaches_class_subject(class_id,class_subject_id)));

drop policy if exists "Class members and campus admins read attendance sessions" on public.attendance_sessions;
drop policy if exists "Class members and campus admins read attendance sessions" on public.attendance_sessions;
create policy "Class members and campus admins read attendance sessions" on public.attendance_sessions for select to authenticated using(public.is_campus_admin_for_class(class_id) or public.teaches_class(class_id) or public.is_active_student_in(class_id));
drop policy if exists "Class teachers record attendance or suspend sessions" on public.attendance_sessions;
drop policy if exists "Class teachers record attendance or suspend sessions" on public.attendance_sessions;
create policy "Class teachers record attendance or suspend sessions" on public.attendance_sessions for all to authenticated using(public.is_campus_admin_for_class(class_id) or public.teaches_class(class_id)) with check(public.is_campus_admin_for_class(class_id) or public.teaches_class(class_id));
drop policy if exists "Students and class staff read attendance records" on public.attendance_records;
drop policy if exists "Students and class staff read attendance records" on public.attendance_records;
create policy "Students and class staff read attendance records" on public.attendance_records for select to authenticated using(student_id=auth.uid() or public.is_platform_admin() or exists(select 1 from public.attendance_sessions s where s.id=session_id and (public.is_campus_admin_for_class(s.class_id) or public.teaches_class(s.class_id))));
drop policy if exists "Class staff manage attendance records" on public.attendance_records;
drop policy if exists "Class staff manage attendance records" on public.attendance_records;
create policy "Class staff manage attendance records" on public.attendance_records for all to authenticated using(public.is_platform_admin() or exists(select 1 from public.attendance_sessions s where s.id=session_id and (public.is_campus_admin_for_class(s.class_id) or public.teaches_class(s.class_id)))) with check(public.is_platform_admin() or exists(select 1 from public.attendance_sessions s where s.id=session_id and (public.is_campus_admin_for_class(s.class_id) or public.teaches_class(s.class_id))));

drop policy if exists "Review participants and admins can read reviews" on public.reviews;
drop policy if exists "Review participants and admins can read reviews" on public.reviews;
create policy "Review participants and admins can read reviews" on public.reviews for select to authenticated using(public.is_campus_admin_for_class(class_id) or reviewer_id=auth.uid() or subject_id=auth.uid() or public.teaches_class(class_id));
drop policy if exists "Students rate teachers and teachers rate students" on public.reviews;
create policy "Students rate teachers and teachers rate students" on public.reviews for insert to authenticated with check(
 reviewer_id=auth.uid() and public.account_is_active() and (
  (public.current_role()='student' and reviews.reviewer_role='student' and public.is_active_student_in(reviews.class_id) and (exists(select 1 from public.class_teachers ct where ct.class_id=reviews.class_id and ct.teacher_id=reviews.subject_id) or exists(select 1 from public.class_subjects cs join public.branch_teachers bt on bt.branch_id=cs.branch_id and bt.subject_id=cs.subject_id where cs.class_id=reviews.class_id and bt.teacher_id=reviews.subject_id))) or
  (public.current_role()='teacher' and reviews.reviewer_role='teacher' and public.teaches_class(reviews.class_id) and exists(select 1 from public.class_memberships cm where cm.class_id=reviews.class_id and cm.student_id=reviews.subject_id and cm.status='active'))
 ));
drop policy if exists "Review authors may revise their own monthly feedback" on public.reviews;
drop policy if exists "Review authors may revise their own monthly feedback" on public.reviews;
create policy "Review authors may revise their own monthly feedback" on public.reviews for update to authenticated using(reviewer_id=auth.uid()) with check(reviewer_id=auth.uid());
drop policy if exists "Campus notices visible to intended audience" on public.notices;
drop policy if exists "Campus notices visible to intended audience" on public.notices;
create policy "Campus notices visible to intended audience" on public.notices for select to authenticated using(public.is_platform_admin() or (public.is_campus_member(campus_id) and public.account_is_active() and (audience_role is null or audience_role=public.current_role()) and (department is null or department=(select department from public.profiles where id=auth.uid())) and (class_id is null or public.teaches_class(class_id) or public.is_active_student_in(class_id) or public.is_campus_admin_for_class(class_id))));
drop policy if exists "Admins and active teachers publish notices" on public.notices;
drop policy if exists "Admins and active teachers publish notices" on public.notices;
create policy "Admins and active teachers publish notices" on public.notices for insert to authenticated with check((public.is_campus_admin_for(campus_id) or (created_by=auth.uid() and public.current_role()='teacher' and public.account_is_active() and public.is_campus_member(campus_id))) and (class_id is null or public.campus_for_class(class_id)=campus_id));
drop policy if exists "Campus reads events" on public.events;
drop policy if exists "Campus reads events" on public.events;
create policy "Campus reads events" on public.events for select to authenticated using(public.is_campus_member(campus_id));
drop policy if exists "Campus admins manage events" on public.events;
drop policy if exists "Campus admins manage events" on public.events;
create policy "Campus admins manage events" on public.events for all to authenticated using(public.is_campus_admin_for(campus_id)) with check(public.is_campus_admin_for(campus_id));
drop policy if exists "Students read their own generated quizzes" on public.generated_quizzes;
drop policy if exists "Students read their own generated quizzes" on public.generated_quizzes;
create policy "Students read their own generated quizzes" on public.generated_quizzes for select to authenticated using(student_id=auth.uid() or public.is_campus_admin_for_class(class_id) or public.teaches_class(class_id));
drop policy if exists "Active students create own class quizzes" on public.generated_quizzes;
drop policy if exists "Active students create own class quizzes" on public.generated_quizzes;
create policy "Active students create own class quizzes" on public.generated_quizzes for insert to authenticated with check(student_id=auth.uid() and public.current_role()='student' and public.is_active_student_in(class_id));
drop policy if exists "Students update their own quiz attempts" on public.generated_quizzes;
drop policy if exists "Students update their own quiz attempts" on public.generated_quizzes;
create policy "Students update their own quiz attempts" on public.generated_quizzes for update to authenticated using(student_id=auth.uid()) with check(student_id=auth.uid());

-- Run after creating private Storage buckets `class-materials` and `assignment-submissions`.
drop policy if exists "Class members read class materials" on storage.objects;
create policy "Class members read class materials" on storage.objects for select to authenticated using(
 bucket_id='class-materials' and name ~ '^[0-9a-fA-F-]{36}/' and
 (public.is_campus_admin_for_class(split_part(name,'/',1)::uuid) or public.is_active_student_in(split_part(name,'/',1)::uuid) or public.teaches_class_direct(split_part(name,'/',1)::uuid) or (name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/' and public.teaches_class_subject(split_part(name,'/',1)::uuid,split_part(name,'/',2)::uuid)))
);
drop policy if exists "Class teachers upload or delete class materials" on storage.objects;
create policy "Class teachers upload or delete class materials" on storage.objects for all to authenticated using(
 bucket_id='class-materials' and name ~ '^[0-9a-fA-F-]{36}/' and (public.is_campus_admin_for_class(split_part(name,'/',1)::uuid) or public.teaches_class_direct(split_part(name,'/',1)::uuid) or (name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/' and public.teaches_class_subject(split_part(name,'/',1)::uuid,split_part(name,'/',2)::uuid)))
) with check(bucket_id='class-materials' and name ~ '^[0-9a-fA-F-]{36}/' and (public.is_campus_admin_for_class(split_part(name,'/',1)::uuid) or public.teaches_class_direct(split_part(name,'/',1)::uuid) or (name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/' and public.teaches_class_subject(split_part(name,'/',1)::uuid,split_part(name,'/',2)::uuid))));
drop policy if exists "Students read their own assignment submissions and assigned teachers read class work" on storage.objects;
create policy "Students read their own assignment submissions and assigned teachers read class work" on storage.objects for select to authenticated using(
 bucket_id='assignment-submissions' and name ~ '^[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}/' and (
  split_part(name,'/',2)=auth.uid()::text or public.is_platform_admin() or exists(
   select 1 from public.assignments a where a.id=split_part(name,'/',1)::uuid and (public.is_campus_admin_for_class(a.class_id) or public.teaches_class_direct(a.class_id) or public.teaches_class_subject(a.class_id,a.class_subject_id))
  )
 )
);
drop policy if exists "Students upload their own assignment submission" on storage.objects;
create policy "Students upload their own assignment submission" on storage.objects for insert to authenticated with check(
 bucket_id='assignment-submissions' and split_part(name,'/',2)=auth.uid()::text and exists(
  select 1 from public.assignments a where a.id=split_part(name,'/',1)::uuid and public.is_active_student_in(a.class_id)
 )
);
-- Bootstrap the first platform administrator only after creating and verifying their account:
-- update public.profiles set role='platform_admin', account_status='active' where email='your-platform-admin@domain.com';
-- insert into public.platform_admins(user_id) select id from public.profiles where email='your-platform-admin@domain.com' on conflict do nothing;
