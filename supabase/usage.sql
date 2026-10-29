-- CrewBase Log: anonymous usage counts (Admin > Usage). Run once in Supabase (SQL Editor) after admin_activity.sql.
-- No account, no ID, no email: nothing links two rows to one pilot. Anyone can add a row for the current month;
-- only the admin can read the summary.
create table if not exists public.usage_events (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('active', 'start', 'import', 'pdf', 'backup', 'restore', 'crewbase')),
  month      date not null default date_trunc('month', now())::date,
  family     text check (length(family) <= 40),      -- main aircraft family (A320 family, 787...)
  licence    text check (length(licence) <= 12),     -- ATPL / CPL / PPL / MPL
  hours      text check (length(hours) <= 16),       -- a range, never the figure
  tz         text check (length(tz) <= 40),          -- the device's time zone, as a rough location
  account    boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists usage_events_month on public.usage_events (month, kind);
alter table public.usage_events enable row level security;
grant insert on public.usage_events to anon, authenticated;
revoke select, update, delete on public.usage_events from anon, authenticated;

create policy "anyone adds anonymous counts" on public.usage_events
  for insert to anon, authenticated
  with check (month = date_trunc('month', now())::date);

-- the admin's summary: monthly figures and this month's breakdowns (nothing for anyone else)
create or replace function public.cbl_usage_summary()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when not public.cbl_is_admin() then null else jsonb_build_object(
    'months', (select coalesce(jsonb_agg(m order by m->>'month'), '[]'::jsonb) from (
      select jsonb_build_object('month', month, 'active', count(*) filter (where kind = 'active'),
        'active_account', count(*) filter (where kind = 'active' and account), 'start', count(*) filter (where kind = 'start'),
        'import', count(*) filter (where kind = 'import'), 'pdf', count(*) filter (where kind = 'pdf'),
        'backup', count(*) filter (where kind = 'backup'), 'restore', count(*) filter (where kind = 'restore'), 'crewbase', count(*) filter (where kind = 'crewbase')) m
      from public.usage_events where month >= (date_trunc('month', now()) - interval '11 months')::date group by month) x),
    'family', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select coalesce(family, '?') k, count(*) n from public.usage_events where kind = 'active' and month = date_trunc('month', now())::date group by 1) a),
    'licence', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select coalesce(licence, '?') k, count(*) n from public.usage_events where kind = 'active' and month = date_trunc('month', now())::date group by 1) a),
    'hours', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select coalesce(hours, '?') k, count(*) n from public.usage_events where kind = 'active' and month = date_trunc('month', now())::date group by 1) a),
    'tz', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select coalesce(tz, '?') k, count(*) n from public.usage_events where kind = 'active' and month = date_trunc('month', now())::date group by 1) a)
  ) end;
$$;
revoke all on function public.cbl_usage_summary() from public, anon;
grant execute on function public.cbl_usage_summary() to authenticated;
