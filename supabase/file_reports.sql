-- CrewBase Log: files pilots send so we can make the app read them ("Help us read it").
-- Run once in Supabase: Dashboard > SQL Editor > New query > paste > Run. Safe to run again.
-- Needs supabase/admin_activity.sql first (it defines cbl_is_admin()).
--
-- A pilot who ticks the consent box uploads the file to a private storage bucket, in a folder named after their account,
-- with one row in file_reports. The pilot can see and withdraw their own reports; only the admin can open the files,
-- change the status and delete them. Files are deleted once the format is supported, at the latest after 30 days (private.report_expire, daily).

-- private bucket, files up to 20 MB
insert into storage.buckets (id, name, public, file_size_limit)
values ('file-reports', 'file-reports', false, 20971520)
on conflict (id) do update set public = false, file_size_limit = 20971520;

drop policy if exists "file reports: upload own" on storage.objects;
create policy "file reports: upload own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'file-reports' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "file reports: owner or admin reads" on storage.objects;
create policy "file reports: owner or admin reads" on storage.objects
  for select to authenticated
  using (bucket_id = 'file-reports' and ((storage.foldername(name))[1] = auth.uid()::text or public.cbl_is_admin()));

drop policy if exists "file reports: owner or admin deletes" on storage.objects;
create policy "file reports: owner or admin deletes" on storage.objects
  for delete to authenticated
  using (bucket_id = 'file-reports' and ((storage.foldername(name))[1] = auth.uid()::text or public.cbl_is_admin()));

create table if not exists public.file_reports (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  email       text,
  file_name   text not null,
  path        text not null,
  size        bigint,
  kind        text,                          -- logbook | ecrew | roster | other
  error       text,                          -- what the app said
  note        text check (length(note) <= 2000),   -- the pilot's note: which app or airline
  status      text not null default 'new' check (status in ('new', 'working', 'done', 'cannot')),
  admin_note  text check (length(admin_note) <= 2000),   -- shown to the pilot
  file_deleted boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists file_reports_created on public.file_reports (created_at desc);
alter table public.file_reports add column if not exists emailed_at timestamptz;   -- when the pilot was emailed about the result

grant select, insert, update, delete on public.file_reports to authenticated;
alter table public.file_reports enable row level security;

drop policy if exists "file reports: add own" on public.file_reports;
create policy "file reports: add own" on public.file_reports
  for insert to authenticated
  with check (auth.uid() = user_id and status = 'new' and admin_note is null);

drop policy if exists "file reports: owner or admin reads" on public.file_reports;
create policy "file reports: owner or admin reads" on public.file_reports
  for select to authenticated
  using (auth.uid() = user_id or public.cbl_is_admin());

drop policy if exists "file reports: admin updates" on public.file_reports;
create policy "file reports: admin updates" on public.file_reports
  for update to authenticated
  using (public.cbl_is_admin()) with check (public.cbl_is_admin());

drop policy if exists "file reports: owner or admin deletes" on public.file_reports;
create policy "file reports: owner or admin deletes" on public.file_reports
  for delete to authenticated
  using (auth.uid() = user_id or public.cbl_is_admin());

notify pgrst, 'reload schema';
