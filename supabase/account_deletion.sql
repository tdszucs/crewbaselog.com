-- Delete my account (Help page): the pilot asks, Crew Base sharing stops at once, the logbook stays on the server
-- for 30 days (logging in before then can keep the account), then a nightly job deletes the account and,
-- through the foreign keys, everything that belongs to it (logbook, roster, friends, activity, file reports).

create table if not exists public.account_deletions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text,
  requested_at timestamptz not null default now(),
  delete_after timestamptz not null default now() + interval '30 days'
);
alter table public.account_deletions enable row level security;
revoke all on public.account_deletions from anon, authenticated;
grant select on public.account_deletions to authenticated;
drop policy if exists "own deletion" on public.account_deletions;
create policy "own deletion" on public.account_deletions for select to authenticated using (user_id = (select auth.uid()));

-- ask: returns the date the account goes; asking again keeps the first date
create or replace function public.account_delete_request() returns timestamptz
language plpgsql security definer set search_path = '' as $$
declare t timestamptz;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into public.account_deletions (user_id, email) values (auth.uid(), auth.jwt() ->> 'email')
    on conflict (user_id) do nothing;
  select delete_after into t from public.account_deletions where user_id = auth.uid();
  delete from public.crew_rosters where user_id = auth.uid();
  delete from public.crew_friends where user_id = auth.uid();
  return t;
end $$;

-- keep my account after all (logged in again within the 30 days)
create or replace function public.account_delete_cancel() returns void
language sql security definer set search_path = '' as $$
  delete from public.account_deletions where user_id = auth.uid();
$$;

revoke all on function public.account_delete_request() from public, anon;
revoke all on function public.account_delete_cancel() from public, anon;
grant execute on function public.account_delete_request() to authenticated;
grant execute on function public.account_delete_cancel() to authenticated;

-- nightly: accounts past their date go. Files sent through Help are removed from storage first
-- (private.report_call cleanup); the account itself goes the next night, once they are gone.
create or replace function private.account_purge() returns integer
language plpgsql security definer set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in select d.user_id from public.account_deletions d where d.delete_after < now() loop
    if exists (select 1 from public.file_reports f where f.user_id = r.user_id and not f.file_deleted) then
      perform private.report_call(jsonb_build_object('action', 'cleanup', 'report_id', f.id))
        from public.file_reports f where f.user_id = r.user_id and not f.file_deleted;
      continue;
    end if;
    delete from auth.users where id = r.user_id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function private.account_purge() from public, anon, authenticated;

select cron.unschedule('cbl-account-purge') where exists (select 1 from cron.job where jobname = 'cbl-account-purge');
select cron.schedule('cbl-account-purge', '41 3 * * *', 'select private.account_purge()');
