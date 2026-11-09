-- Fix branch/class policies that were accidentally limited to platform admins.
-- Campus admins are authorized only for rows belonging to their own campus.

drop policy if exists "Admins manage branches" on public.branches;
create policy "Admins manage branches" on public.branches
  for all to authenticated
  using (public.is_campus_admin_for(campus_id))
  with check (public.is_campus_admin_for(campus_id));

drop policy if exists "Admins manage branch subjects" on public.subjects;
create policy "Admins manage branch subjects" on public.subjects
  for all to authenticated
  using (public.is_campus_admin_for(public.campus_for_branch(branch_id)))
  with check (public.is_campus_admin_for(public.campus_for_branch(branch_id)));

drop policy if exists "Campus sees relevant branch subject assignments" on public.branch_teachers;
create policy "Campus sees relevant branch subject assignments" on public.branch_teachers
  for select to authenticated using (
    public.is_campus_admin_for(public.campus_for_branch(branch_id))
    or teacher_id=auth.uid()
    or exists (
      select 1 from public.class_subjects cs
      where cs.branch_id=branch_teachers.branch_id
        and cs.subject_id=branch_teachers.subject_id
        and public.is_active_student_in(cs.class_id)
    )
  );

drop policy if exists "Admins manage branch teacher assignments" on public.branch_teachers;
create policy "Admins manage branch teacher assignments" on public.branch_teachers
  for all to authenticated
  using (public.is_campus_admin_for(public.campus_for_branch(branch_id)))
  with check (public.is_campus_admin_for(public.campus_for_branch(branch_id)));

drop policy if exists "Campus reads class subjects" on public.class_subjects;
create policy "Campus reads class subjects" on public.class_subjects
  for select to authenticated using (
    public.is_campus_admin_for_class(class_id)
    or public.is_active_student_in(class_id)
    or public.teaches_class_subject(class_id,id)
  );

drop policy if exists "Teachers attach their assigned subjects to classes" on public.class_subjects;
create policy "Teachers attach their assigned subjects to classes" on public.class_subjects
  for insert to authenticated with check (
    public.is_campus_admin_for_class(class_id)
    or exists (
      select 1 from public.classes c
      join public.branch_teachers bt
        on bt.branch_id=c.branch_id and bt.subject_id=class_subjects.subject_id
      where c.id=class_subjects.class_id
        and c.created_by=auth.uid()
        and bt.teacher_id=auth.uid()
        and public.current_role()='teacher'
        and public.account_is_active()
    )
  );

drop policy if exists "Admins manage class subjects" on public.class_subjects;
create policy "Admins manage class subjects" on public.class_subjects
  for all to authenticated
  using (public.is_campus_admin_for_class(class_id))
  with check (public.is_campus_admin_for_class(class_id));

drop policy if exists "Campus reads class routines" on public.class_routines;
create policy "Campus reads class routines" on public.class_routines
  for select to authenticated using (
    public.is_campus_admin_for_class(class_id)
    or public.is_active_student_in(class_id)
    or public.teaches_class_subject(class_id,class_subject_id)
  );

drop policy if exists "Assigned teachers manage their class routines" on public.class_routines;
create policy "Assigned teachers manage their class routines" on public.class_routines
  for all to authenticated
  using (
    public.is_campus_admin_for_class(class_id)
    or (teacher_id=auth.uid() and public.teaches_class_subject(class_id,class_subject_id))
  )
  with check (
    public.is_campus_admin_for_class(class_id)
    or (teacher_id=auth.uid() and created_by=auth.uid() and public.teaches_class_subject(class_id,class_subject_id))
  );

drop policy if exists "Admins or assigned teachers create branch classes" on public.classes;
create policy "Admins or assigned teachers create branch classes" on public.classes
  for insert to authenticated with check (
    public.is_campus_admin_for(public.campus_for_branch(branch_id))
    or (
      created_by=auth.uid()
      and branch_id is not null
      and public.current_role()='teacher'
      and public.account_is_active()
      and exists (
        select 1 from public.branch_teachers bt
        where bt.branch_id=classes.branch_id and bt.teacher_id=auth.uid()
      )
    )
  );

-- Keep class creation scoped while making its inserts independent of stale
-- client-side RLS policies from earlier migrations.
create or replace function public.create_campus_class(p_class_data jsonb,p_subject_ids uuid[])
returns public.classes
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  target_branch uuid := (p_class_data->>'branch_id')::uuid;
  target_session uuid := (p_class_data->>'academic_session_id')::uuid;
  target_campus uuid;
  target_subject uuid;
  created_class public.classes;
begin
  if actor_id is null then raise exception 'Sign in as a campus admin to create a class'; end if;
  select b.campus_id into target_campus
  from public.branches b
  where b.id=target_branch and b.is_active;
  if target_campus is null then raise exception 'Selected branch is not active or has no campus'; end if;
  if not (
    public.is_platform_admin()
    or exists (
      select 1 from public.campus_admins ca
      join public.profiles p on p.id=ca.user_id
      where ca.campus_id=target_campus and ca.user_id=actor_id
        and p.role='admin' and p.account_status='active'
    )
  ) then raise exception 'Your admin account is not assigned to the selected branch campus'; end if;
  if not exists (
    select 1 from public.session_branches sb
    join public.academic_sessions s on s.id=sb.session_id and s.campus_id=sb.campus_id
    where sb.campus_id=target_campus and sb.branch_id=target_branch
      and sb.session_id=target_session and s.is_active
  ) then raise exception 'Select an active academic session linked to this branch'; end if;
  if coalesce(array_length(p_subject_ids,1),0)=0 then raise exception 'Select at least one subject for this class'; end if;
  foreach target_subject in array p_subject_ids loop
    if not exists(select 1 from public.subjects s where s.id=target_subject and s.branch_id=target_branch) then
      raise exception 'A selected subject does not belong to the selected branch';
    end if;
  end loop;

  insert into public.classes(code,name,department,course_level,term,description,branch_id,academic_session_id,created_by)
  values(
    upper(trim(p_class_data->>'code')),
    trim(p_class_data->>'name'),
    coalesce(nullif(trim(p_class_data->>'department'),''),''),
    nullif(trim(p_class_data->>'course_level'),''),
    nullif(trim(p_class_data->>'term'),''),
    nullif(trim(p_class_data->>'description'),''),
    target_branch,target_session,actor_id
  ) returning * into created_class;

  foreach target_subject in array p_subject_ids loop
    insert into public.class_subjects(class_id,branch_id,subject_id)
    values(created_class.id,target_branch,target_subject)
    on conflict(class_id,subject_id) do nothing;
  end loop;

  insert into public.class_teachers(class_id,teacher_id,added_by)
  select created_class.id,bt.teacher_id,actor_id
  from public.branch_teachers bt
  where bt.branch_id=target_branch and bt.subject_id=any(p_subject_ids)
  on conflict(class_id,teacher_id) do nothing;

  return created_class;
end
$$;
revoke all on function public.create_campus_class(jsonb,uuid[]) from public;
grant execute on function public.create_campus_class(jsonb,uuid[]) to authenticated;
