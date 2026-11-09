-- Campus admins can sign up, create their own isolated campus, and then
-- verify teachers and students in that campus. Public platform-admin signup
-- remains disabled.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path=public as $$
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

-- Campus admins create the academic sessions used during student registration.
drop policy if exists "Campus admins manage their academic sessions" on public.academic_sessions;
create policy "Campus admins manage their academic sessions" on public.academic_sessions
for all to authenticated using(public.is_campus_admin_for(campus_id))
with check(public.is_campus_admin_for(campus_id));
