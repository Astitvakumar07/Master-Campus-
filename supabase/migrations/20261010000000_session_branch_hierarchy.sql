-- Connect academic sessions to the branches offered during that session.
-- Existing active campus branch/session combinations are preserved.

-- Older databases may only have a primary key on id, not the composite keys
-- required to guarantee that a linked branch and session belong to one campus.
create unique index if not exists academic_sessions_campus_id_id_uidx
  on public.academic_sessions(campus_id,id);
create unique index if not exists branches_campus_id_id_uidx
  on public.branches(campus_id,id);

create table if not exists public.session_branches (
  campus_id uuid not null references public.campuses(id) on delete cascade,
  session_id uuid not null,
  branch_id uuid not null,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (session_id, branch_id),
  foreign key (campus_id, session_id) references public.academic_sessions(campus_id, id) on delete cascade,
  foreign key (campus_id, branch_id) references public.branches(campus_id, id) on delete cascade
);

alter table public.session_branches enable row level security;

drop policy if exists "Public can see active session branches" on public.session_branches;
create policy "Public can see active session branches" on public.session_branches
  for select to anon, authenticated using (
    exists (
      select 1 from public.academic_sessions s
      join public.branches b on b.campus_id=s.campus_id
      where s.id=session_branches.session_id
        and b.id=session_branches.branch_id
        and s.is_active and b.is_active
    )
  );

drop policy if exists "Campus admins add session branches" on public.session_branches;
create policy "Campus admins add session branches" on public.session_branches
  for insert to authenticated with check (public.is_campus_admin_for(campus_id));

grant select on public.session_branches to anon, authenticated;
grant insert on public.session_branches to authenticated;

-- Preserve all currently valid campus combinations and existing class/enrollment pairs.
insert into public.session_branches(campus_id,session_id,branch_id,created_by)
select b.campus_id,s.id,b.id,b.created_by
from public.branches b
join public.academic_sessions s on s.campus_id=b.campus_id
where b.is_active and s.is_active
on conflict (session_id,branch_id) do nothing;

insert into public.session_branches(campus_id,session_id,branch_id)
select b.campus_id,c.academic_session_id,b.id
from public.classes c
join public.branches b on b.id=c.branch_id
where c.academic_session_id is not null
on conflict (session_id,branch_id) do nothing;

insert into public.session_branches(campus_id,session_id,branch_id)
select e.campus_id,e.session_id,e.branch_id
from public.campus_enrollments e
where e.session_id is not null and e.branch_id is not null
on conflict (session_id,branch_id) do nothing;

-- Repair older teacher registrations created before campus-register reliably
-- wrote their campus enrollment. Without this row, campus RLS hides the teacher
-- from the admin approval queue.
insert into public.campus_enrollments(campus_id,user_id,status)
select c.id,p.id,'pending'::public.account_state
from public.profiles p
join auth.users u on u.id=p.id
join public.campuses c on upper(c.campus_code)=upper(coalesce(u.raw_user_meta_data->>'campus_code',''))
where p.role='teacher'
  and p.account_status='pending'
  and not exists (
    select 1 from public.campus_enrollments e
    where e.campus_id=c.id and e.user_id=p.id
  )
on conflict (campus_id,user_id) do nothing;

create or replace function public.validate_class_campus_session()
returns trigger language plpgsql set search_path=public as $$
begin
  if not exists (
    select 1
    from public.session_branches sb
    join public.academic_sessions s on s.id=sb.session_id and s.campus_id=sb.campus_id
    join public.branches b on b.id=sb.branch_id and b.campus_id=sb.campus_id
    where sb.session_id=new.academic_session_id
      and sb.branch_id=new.branch_id
      and s.is_active and b.is_active
  ) then
    raise exception 'Choose a branch linked to this active academic session';
  end if;
  return new;
end $$;
drop trigger if exists validate_class_campus_session on public.classes;
create trigger validate_class_campus_session
before insert or update of branch_id,academic_session_id on public.classes
for each row execute function public.validate_class_campus_session();
