-- CrewBase Log: share Crew Base rosters between friends.
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste > Run. Safe to run again.
--
-- Each pilot saves their Crew Base roster (days only, never the logbook) and a list of friends' emails.
-- A pilot's roster can be read by:
--   - the pilot, and
--   - anyone whose (verified login) email is on that pilot's friends list.
-- So when two pilots add each other, both rosters appear side by side.

create table if not exists public.crew_rosters (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  email      text not null,
  name       text,
  base       text,
  days       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.crew_friends (
  user_id      uuid not null references auth.users (id) on delete cascade,
  friend_email text not null check (friend_email = lower(friend_email)),
  primary key (user_id, friend_email)
);

alter table public.crew_rosters enable row level security;
alter table public.crew_friends enable row level security;

-- Has the owner of a roster added the signed-in user's email as a friend?
-- (security definer: friends lists are private, so the check runs with the table owner's rights)
create or replace function public.crew_shared_with_me(owner uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.crew_friends
    where user_id = owner and friend_email = lower(auth.jwt() ->> 'email')
  );
$$;
revoke all on function public.crew_shared_with_me(uuid) from public;
grant execute on function public.crew_shared_with_me(uuid) to authenticated;

drop policy if exists "own roster" on public.crew_rosters;
create policy "own roster" on public.crew_rosters
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id and lower(email) = lower(auth.jwt() ->> 'email'));

drop policy if exists "rosters shared with me" on public.crew_rosters;
create policy "rosters shared with me" on public.crew_rosters
  for select to authenticated
  using (public.crew_shared_with_me(user_id));

drop policy if exists "own friends" on public.crew_friends;
create policy "own friends" on public.crew_friends
  for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
