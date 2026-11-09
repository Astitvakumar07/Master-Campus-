-- Make class-level teacher assignment the source of teacher class access.
-- Campus admins manage rows in public.class_teachers from the Classes screen.

create or replace function public.teaches_class(target uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.teaches_class_direct(target)
$$;

create or replace function public.teaches_class_subject(target_class uuid,target_subject uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select public.teaches_class_direct(target_class)
$$;
