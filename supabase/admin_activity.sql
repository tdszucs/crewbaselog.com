-- CrewBase Log: who registered and what they did, for the site owner only.
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste > Run. Safe to run again.
--
-- The app records one row per action (logged in, imported a file, downloaded a PDF ...) with counts and formats.
-- Never flights, file names or file contents: the logbook stays on the pilot's device.
-- Only the admin account can read these rows or the list of registered users; everyone else can only add their own.

-- the admin: the verified login email of the site owner
create or replace function public.cbl_is_admin()
returns boolean
language sql
stable
set search_path = ''
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 't.d.szucs@gmail.com';
$$;

create table if not exists public.activity (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  email      text,
  event      text not null check (length(event) <= 40),
  detail     jsonb not null default '{}'::jsonb check (length(detail::text) <= 2000),
  created_at timestamptz not null default now()
);
create index if not exists activity_created_at on public.activity (created_at desc);
create index if not exists activity_user on public.activity (user_id, created_at desc);

grant insert, select on public.activity to authenticated;
alter table public.activity enable row level security;

drop policy if exists "add own activity" on public.activity;
create policy "add own activity" on public.activity
  for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "admin reads activity" on public.activity;
create policy "admin reads activity" on public.activity
  for select to authenticated
  using (public.cbl_is_admin());

-- registered accounts, with their activity and Crew Base use (admin only; returns nothing for anyone else)
create or replace function public.cbl_admin_users()
returns table (
  id uuid, email text, created_at timestamptz, confirmed_at timestamptz, last_sign_in_at timestamptz, provider text,
  actions bigint, last_action_at timestamptz, roster_days int, friends bigint
)
language sql
stable
security definer
set search_path = public, auth
as $$
  select u.id, u.email::text, u.created_at, u.email_confirmed_at, u.last_sign_in_at,
         coalesce(u.raw_app_meta_data ->> 'provider', 'email'),
         (select count(*) from public.activity a where a.user_id = u.id),
         (select max(a.created_at) from public.activity a where a.user_id = u.id),
         (select coalesce((select count(*) from jsonb_object_keys(r.days)), 0)::int from public.crew_rosters r where r.user_id = u.id),
         (select count(*) from public.crew_friends f where f.user_id = u.id)
  from auth.users u
  where public.cbl_is_admin()
  order by u.created_at desc;
$$;
revoke all on function public.cbl_admin_users() from public;
grant execute on function public.cbl_admin_users() to authenticated;

notify pgrst, 'reload schema';
