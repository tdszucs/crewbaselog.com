-- Pilot jobs: vacancies the site owner posts in Admin → Jobs; every visitor of the Jobs page reads the open ones.
-- Needs supabase/admin_activity.sql first (it defines cbl_is_admin()).

create table if not exists public.jobs (
  id bigserial primary key,
  airline text not null,
  position text not null,            -- Captain, First Officer, Second Officer, Instructor ...
  aircraft text,                     -- type or family, e.g. A320, B787, ATR72
  base text,                         -- e.g. LHR, Dubai, several bases
  min_total integer,                 -- minimum total time, hours
  min_type integer,                  -- minimum hours on the aircraft type
  min_pic integer,                   -- minimum PIC hours
  licence text,                      -- ATPL, CPL ...
  details text,                      -- what the airline offers and asks, a few lines
  apply_url text not null,           -- a link (https://) or an email address to apply
  closes date,                       -- after this day the vacancy no longer shows
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.jobs enable row level security;
revoke all on public.jobs from anon, authenticated;
grant select on public.jobs to anon, authenticated;
grant insert, update, delete on public.jobs to authenticated;
grant usage, select on sequence public.jobs_id_seq to authenticated;

drop policy if exists "open jobs" on public.jobs;
create policy "open jobs" on public.jobs for select to anon, authenticated
  using ((active and (closes is null or closes >= current_date)) or public.cbl_is_admin());
drop policy if exists "owner manages jobs" on public.jobs;
create policy "owner manages jobs" on public.jobs for all to authenticated
  using (public.cbl_is_admin()) with check (public.cbl_is_admin());
