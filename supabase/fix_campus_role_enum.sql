-- Run this by itself in Supabase SQL Editor, then rerun schema.sql.
alter type public.campus_role add value if not exists 'platform_admin';
