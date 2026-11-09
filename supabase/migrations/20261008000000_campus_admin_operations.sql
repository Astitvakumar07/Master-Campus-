-- Campus operations: support inbox, emergency contacts and an admin activity trail.
-- Safe to re-run; does not modify existing enrollment or attendance records.

alter table public.profiles
  add column if not exists guardian_name text,
  add column if not exists guardian_mobile text,
  add column if not exists emergency_contact_name text,
  add column if not exists emergency_contact_mobile text;

create or replace function public.sync_student_contacts_from_auth() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  update public.profiles
  set guardian_name=nullif(trim(coalesce(new.raw_user_meta_data->>'guardian_name','')),''),
      guardian_mobile=nullif(trim(coalesce(new.raw_user_meta_data->>'guardian_mobile','')),''),
      emergency_contact_name=nullif(trim(coalesce(new.raw_user_meta_data->>'emergency_contact_name','')),''),
      emergency_contact_mobile=nullif(trim(coalesce(new.raw_user_meta_data->>'emergency_contact_mobile','')),'')
  where id=new.id and new.raw_user_meta_data->>'requested_role'='student';
  return new;
end $$;
drop trigger if exists sync_student_contacts_from_auth on auth.users;
create trigger sync_student_contacts_from_auth after insert on auth.users
for each row execute function public.sync_student_contacts_from_auth();

create table if not exists public.campus_support_requests (
  id uuid primary key default gen_random_uuid(),
  campus_id uuid not null references public.campuses(id) on delete cascade,
  created_by uuid not null references public.profiles(id) on delete cascade,
  category text not null default 'General' check(category in ('General','Account access','Attendance','Enrollment','Class or subject','Safety / urgent')),
  title text not null,
  description text not null,
  status text not null default 'open' check(status in ('open','in_progress','resolved','closed')),
  resolution_note text,
  assigned_to uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists campus_support_requests_campus_status_idx
  on public.campus_support_requests(campus_id,status,created_at desc);
alter table public.campus_support_requests enable row level security;
drop policy if exists "Campus members create own support requests" on public.campus_support_requests;
create policy "Campus members create own support requests" on public.campus_support_requests
  for insert to authenticated with check(created_by=auth.uid() and public.account_is_active() and public.is_campus_member(campus_id));
drop policy if exists "Requesters and campus admins read support requests" on public.campus_support_requests;
create policy "Requesters and campus admins read support requests" on public.campus_support_requests
  for select to authenticated using(created_by=auth.uid() or public.is_campus_admin_for(campus_id));
drop policy if exists "Campus admins manage support requests" on public.campus_support_requests;
create policy "Campus admins manage support requests" on public.campus_support_requests
  for update to authenticated using(public.is_campus_admin_for(campus_id)) with check(public.is_campus_admin_for(campus_id));
grant select,insert,update on public.campus_support_requests to authenticated;

create table if not exists public.campus_activity_log (
  id bigint generated always as identity primary key,
  campus_id uuid not null references public.campuses(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id text,
  summary text not null,
  created_at timestamptz not null default now()
);
create index if not exists campus_activity_log_campus_created_idx
  on public.campus_activity_log(campus_id,created_at desc);
alter table public.campus_activity_log enable row level security;
drop policy if exists "Campus admins read activity log" on public.campus_activity_log;
create policy "Campus admins read activity log" on public.campus_activity_log
  for select to authenticated using(public.is_campus_admin_for(campus_id));
grant select on public.campus_activity_log to authenticated;

create or replace function public.rollover_campus_students(target_user_ids uuid[],target_branch uuid,target_session uuid)
returns integer language plpgsql security definer set search_path=public as $$
declare target_campus uuid; changed_count integer;
begin
  select b.campus_id into target_campus from public.branches b
  join public.academic_sessions s on s.campus_id=b.campus_id
  where b.id=target_branch and s.id=target_session and b.is_active and s.is_active;
  if target_campus is null or not public.is_campus_admin_for(target_campus) then
    raise exception 'Choose an active branch and session from your own campus';
  end if;
  if coalesce(array_length(target_user_ids,1),0)=0 then raise exception 'Choose at least one student'; end if;
  if exists(select 1 from public.campus_enrollments e where e.user_id=any(target_user_ids) and e.campus_id=target_campus and e.status<>'active') then
    raise exception 'Only approved, active students can be moved to a new session';
  end if;
  if (select count(*) from public.campus_enrollments e where e.user_id=any(target_user_ids) and e.campus_id=target_campus and e.status='active')<>array_length(target_user_ids,1) then
    raise exception 'One or more selected students do not belong to this campus';
  end if;
  update public.class_memberships cm set status='left',reviewed_by=auth.uid(),reviewed_at=now()
  from public.classes c
  where c.id=cm.class_id and cm.student_id=any(target_user_ids) and cm.status='active'
    and (c.academic_session_id<>target_session or c.branch_id<>target_branch);
  update public.campus_enrollments e set branch_id=target_branch,session_id=target_session
  where e.user_id=any(target_user_ids) and e.campus_id=target_campus and e.status='active';
  get diagnostics changed_count=row_count;
  return changed_count;
end $$;
revoke all on function public.rollover_campus_students(uuid[],uuid,uuid) from public;
grant execute on function public.rollover_campus_students(uuid[],uuid,uuid) to authenticated;

create or replace function public.log_campus_admin_activity() returns trigger
language plpgsql security definer set search_path=public as $$
declare
  row_data jsonb;
  campus_value uuid;
  entity_value text;
  action_value text;
  summary_value text;
begin
  if auth.uid() is null then
    if tg_op='DELETE' then return old; else return new; end if;
  end if;
  row_data := case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
  entity_value := coalesce(row_data->>'id',row_data->>'user_id',row_data->>'session_id');
  action_value := lower(tg_op);
  summary_value := initcap(replace(tg_table_name,'_',' '))||' '||action_value;

  if tg_table_name='profiles' then
    select e.campus_id into campus_value from public.campus_enrollments e where e.user_id=(row_data->>'id')::uuid limit 1;
    if campus_value is null then
      select ca.campus_id into campus_value from public.campus_admins ca where ca.user_id=(row_data->>'id')::uuid order by ca.created_at limit 1;
    end if;
  elsif nullif(row_data->>'campus_id','') is not null then
    campus_value := (row_data->>'campus_id')::uuid;
  elsif tg_table_name='classes' then
    select b.campus_id into campus_value from public.branches b where b.id=(row_data->>'branch_id')::uuid;
  elsif tg_table_name='attendance_sessions' then
    select b.campus_id into campus_value from public.classes c join public.branches b on b.id=c.branch_id where c.id=(row_data->>'class_id')::uuid;
  elsif tg_table_name in ('class_memberships','assignments','materials','syllabus_units','class_routines','class_teachers') then
    select b.campus_id into campus_value from public.classes c join public.branches b on b.id=c.branch_id where c.id=(row_data->>'class_id')::uuid;
  elsif tg_table_name='subjects' then
    select b.campus_id into campus_value from public.branches b where b.id=(row_data->>'branch_id')::uuid;
  elsif tg_table_name='branch_teachers' then
    select b.campus_id into campus_value from public.branches b where b.id=(row_data->>'branch_id')::uuid;
  end if;

  if campus_value is null then
    if tg_op='DELETE' then return old; else return new; end if;
  end if;
  insert into public.campus_activity_log(campus_id,actor_id,action,entity_type,entity_id,summary)
    values(campus_value,auth.uid(),action_value,tg_table_name,entity_value,summary_value);
  if tg_op='DELETE' then return old; else return new; end if;
end $$;

drop trigger if exists campus_activity_profiles on public.profiles;
create trigger campus_activity_profiles after insert or update or delete on public.profiles
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_enrollments on public.campus_enrollments;
create trigger campus_activity_enrollments after insert or update or delete on public.campus_enrollments
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_branches on public.branches;
create trigger campus_activity_branches after insert or update or delete on public.branches
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_sessions on public.academic_sessions;
create trigger campus_activity_sessions after insert or update or delete on public.academic_sessions
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_classes on public.classes;
create trigger campus_activity_classes after insert or update or delete on public.classes
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_teacher_assignments on public.branch_teachers;
create trigger campus_activity_teacher_assignments after insert or update or delete on public.branch_teachers
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_attendance_sessions on public.attendance_sessions;
create trigger campus_activity_attendance_sessions after insert or update or delete on public.attendance_sessions
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_notices on public.notices;
create trigger campus_activity_notices after insert or update or delete on public.notices
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_events on public.events;
create trigger campus_activity_events after insert or update or delete on public.events
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_support_requests on public.campus_support_requests;
create trigger campus_activity_support_requests after insert or update or delete on public.campus_support_requests
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_class_memberships on public.class_memberships;
create trigger campus_activity_class_memberships after insert or update or delete on public.class_memberships
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_assignments on public.assignments;
create trigger campus_activity_assignments after insert or update or delete on public.assignments
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_materials on public.materials;
create trigger campus_activity_materials after insert or update or delete on public.materials
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_syllabus on public.syllabus_units;
create trigger campus_activity_syllabus after insert or update or delete on public.syllabus_units
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_routines on public.class_routines;
create trigger campus_activity_routines after insert or update or delete on public.class_routines
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_class_teachers on public.class_teachers;
create trigger campus_activity_class_teachers after insert or update or delete on public.class_teachers
  for each row execute function public.log_campus_admin_activity();
drop trigger if exists campus_activity_subjects on public.subjects;
create trigger campus_activity_subjects after insert or update or delete on public.subjects
  for each row execute function public.log_campus_admin_activity();
