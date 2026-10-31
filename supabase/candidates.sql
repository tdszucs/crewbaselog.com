-- Open to job offers (Jobs page): a pilot who switches it on chooses what to share with CrewBase Log, to be matched with
-- vacancies: profile, email, an hours summary, the complete logbook, a CV. Nothing is shared while it is off; switching it
-- off deletes the row and the CV at once. Only the pilot and the site owner (cbl_is_admin) can read any of it.
-- Needs supabase/admin_activity.sql (cbl_is_admin) and supabase/logbooks.sql first.

create table if not exists public.candidates (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text,
  share_profile boolean not null default false,
  share_email boolean not null default false,
  share_summary boolean not null default false,
  share_logbook boolean not null default false,
  share_cv boolean not null default false,
  positions text,          -- what they are looking for: Captain, First Officer ...
  aircraft text,           -- types they want to fly
  regions text,            -- where: bases, countries, "anywhere"
  available text,          -- from when
  note text,               -- a few words from the pilot
  profile jsonb,           -- name, licence, base, airline, types flown (only when shared)
  summary jsonb,           -- the hours summary (only when shared), refreshed as the logbook grows
  cv_path text, cv_name text,
  updated_at timestamptz not null default now()
);
alter table public.candidates enable row level security;
revoke all on public.candidates from anon, authenticated;
grant select, insert, update, delete on public.candidates to authenticated;
drop policy if exists "own candidate" on public.candidates;
create policy "own candidate" on public.candidates for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists "owner reads candidates" on public.candidates;
create policy "owner reads candidates" on public.candidates for select to authenticated using (public.cbl_is_admin());

-- the complete logbook: the site owner may read it only while the pilot shares it
drop policy if exists "shared logbook for jobs" on public.logbooks;
create policy "shared logbook for jobs" on public.logbooks for select to authenticated
  using (public.cbl_is_admin() and exists (select 1 from public.candidates c where c.user_id = logbooks.user_id and c.share_logbook));

-- CVs: a private bucket, PDF or Word up to 5 MB, in the pilot's own folder; the site owner reads it only while it is shared
insert into storage.buckets (id, name, public, file_size_limit)
values ('cvs', 'cvs', false, 5242880)
on conflict (id) do update set public = false, file_size_limit = 5242880;
drop policy if exists "cv: own" on storage.objects;
create policy "cv: own" on storage.objects for all to authenticated
  using (bucket_id = 'cvs' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'cvs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "cv: owner reads shared" on storage.objects;
create policy "cv: owner reads shared" on storage.objects for select to authenticated
  using (bucket_id = 'cvs' and public.cbl_is_admin() and exists (select 1 from public.candidates c where c.user_id::text = (storage.foldername(name))[1] and c.share_cv));
