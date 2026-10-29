-- CrewBase Log: the owner's scheduled check of files sent for help (after file_reports.sql).
-- Run once in Supabase (SQL Editor), and deploy supabase/functions/report-files (verify JWT off: it checks its own key).
--
-- The function copies waiting files to report_blobs and extracts what's needed to read them into report_text; both
-- tables are readable only by the database owner. The database calls it with a private key (report_settings), through
-- private.report_call(), which only the owner can run. Cleanup deletes the file and every copy.

create extension if not exists pg_net;

create table if not exists public.report_blobs (
  report_id  bigint primary key references public.file_reports (id) on delete cascade,
  b64        text not null,
  fetched_at timestamptz not null default now()
);
create table if not exists public.report_text (
  report_id bigint not null references public.file_reports (id) on delete cascade,
  page      int not null,          -- 0 for a CSV / Excel extract
  items     jsonb not null,
  primary key (report_id, page)
);
create table if not exists public.report_settings (key text primary key, value text not null);
insert into public.report_settings (key, value) values ('fn_key', encode(extensions.gen_random_bytes(24), 'hex')) on conflict (key) do nothing;

alter table public.report_blobs enable row level security;
alter table public.report_text enable row level security;
alter table public.report_settings enable row level security;
revoke all on public.report_blobs, public.report_text, public.report_settings from anon, authenticated;
grant select, update on public.file_reports to service_role;
grant select, insert, update, delete on public.report_blobs, public.report_text to service_role;
grant select on public.report_settings to service_role;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create or replace function private.report_call(body jsonb)
returns bigint
language sql
set search_path = ''
as $$
  select net.http_post(
    url := 'https://pwpkecvqljxpprricfho.supabase.co/functions/v1/report-files',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-report-key', (select value from public.report_settings where key = 'fn_key')),
    body := body,
    timeout_milliseconds := 150000);
$$;
revoke all on function private.report_call(jsonb) from public, anon, authenticated;

-- a pilot's own report turns to "works now" when they import that file successfully (only their own, only new/working)
create or replace function public.cbl_report_works(fname text)
returns int
language sql
security definer
set search_path = ''
as $$
  with u as (
    update public.file_reports set status = 'done', updated_at = now(),
      admin_note = coalesce(admin_note, 'Imported successfully by the pilot.')
    where user_id = auth.uid() and file_name = fname and status in ('new', 'working')
    returning 1)
  select count(*)::int from u;
$$;
revoke all on function public.cbl_report_works(text) from public, anon;
grant execute on function public.cbl_report_works(text) to authenticated;

-- every day: files 30 days old, or handled and not yet deleted, are deleted with every copy; reports that work now leave the list 5 days after their file was deleted
create extension if not exists pg_cron;
create or replace function private.report_expire()
returns int
language sql
set search_path = ''
as $$
  delete from public.file_reports where status = 'done' and file_deleted and updated_at < now() - interval '5 days';
  with due as (
    select id from public.file_reports
    where not file_deleted and (created_at < now() - interval '30 days' or status in ('done', 'cannot')))
  select count(private.report_call(jsonb_build_object('action', 'cleanup', 'report_id', id)))::int from due;
$$;
revoke all on function private.report_expire() from public, anon, authenticated;
select cron.schedule('cbl-report-expire', '17 3 * * *', 'select private.report_expire()');
