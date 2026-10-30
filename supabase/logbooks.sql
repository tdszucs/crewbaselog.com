-- Each pilot's logbook, stored in their account so it survives a cleared browser and follows them to every device.
-- One row per account: the whole logbook as JSON. Only the pilot's own log-in can read or write it.
-- rev goes up by one with every save; a device writes only if it has the latest rev, so two devices can't overwrite each other unseen.
create table if not exists public.logbooks (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  data       jsonb not null,
  rev        bigint not null default 1,
  flights    integer,
  updated_at timestamptz not null default now(),
  constraint logbook_size check (pg_column_size(data) < 25000000)
);

alter table public.logbooks enable row level security;
revoke all on public.logbooks from anon;
grant select, insert, update, delete on public.logbooks to authenticated;

drop policy if exists "own logbook" on public.logbooks;
create policy "own logbook" on public.logbooks
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create or replace function public.logbooks_touch() returns trigger
  language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists logbooks_touch on public.logbooks;
create trigger logbooks_touch before insert or update on public.logbooks
  for each row execute function public.logbooks_touch();
