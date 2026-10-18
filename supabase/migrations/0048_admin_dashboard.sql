-- Admin dashboard: user list + app traffic, visible only to the app owner.
-- Every admin_* function re-checks the caller server-side (is_app_admin), so hiding the card in the
-- UI is cosmetic; a non-admin calling these directly gets an exception.

-- One row per user, day and platform; written by app_log_activity() when the app opens.
create table if not exists public.app_activity (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null default current_date,
  platform text not null default 'web',
  sessions integer not null default 1,
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  primary key (user_id, day, platform)
);

create index if not exists app_activity_day_idx on public.app_activity (day);

-- No policies: nobody reads or writes this table directly, only through the functions below.
alter table public.app_activity enable row level security;

create or replace function public.is_app_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from auth.users u
    where u.id = auth.uid()
      and lower(u.email) = 'joshuadg511@gmail.com'
      and u.email_confirmed_at is not null
  );
$$;

-- Called once per app open by any signed-in user.
create or replace function public.app_log_activity(p_platform text default 'web')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return;
  end if;

  insert into public.app_activity (user_id, platform)
  values (auth.uid(), left(coalesce(nullif(p_platform, ''), 'web'), 20))
  on conflict (user_id, day, platform)
  do update set sessions = app_activity.sessions + 1, last_seen = now();
end;
$$;

create or replace function public.admin_list_users()
returns table (
  id uuid,
  email text,
  username text,
  first_name text,
  last_name text,
  status text,
  provider text,
  created_at timestamptz,
  last_sign_in_at timestamptz,
  last_seen timestamptz,
  transaction_count bigint
)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  if not public.is_app_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  return query
  select
    u.id,
    u.email::text,
    p.username,
    d.firstname,
    d.lastname,
    p.status,
    coalesce(u.raw_app_meta_data ->> 'provider', 'email'),
    u.created_at,
    u.last_sign_in_at,
    (select max(a.last_seen) from public.app_activity a where a.user_id = u.id),
    (select count(*) from public.transactions t where t.owner_id = u.id)
  from auth.users u
  left join public.profiles p on p.id = u.id
  left join public.user_details d on d.owner_id = u.id
  order by coalesce(u.last_sign_in_at, u.created_at) desc;
end;
$$;

create or replace function public.admin_traffic(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 30), 365));
  v_result jsonb;
begin
  if not public.is_app_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'totalUsers', (select count(*) from auth.users),
    'newUsers7d', (select count(*) from auth.users where created_at >= now() - interval '7 days'),
    'activeToday', (select count(distinct user_id) from public.app_activity where day = current_date),
    'active7d', (select count(distinct user_id) from public.app_activity where day > current_date - 7),
    'active30d', (select count(distinct user_id) from public.app_activity where day > current_date - 30),
    'sessionsToday', (select coalesce(sum(sessions), 0) from public.app_activity where day = current_date),
    'sessionsInRange', (select coalesce(sum(sessions), 0) from public.app_activity where day > current_date - v_days),
    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'day', g.day,
        'activeUsers', coalesce(a.active_users, 0),
        'sessions', coalesce(a.sessions, 0),
        'signups', coalesce(s.signups, 0)
      ) order by g.day), '[]'::jsonb)
      from generate_series(current_date - (v_days - 1), current_date, interval '1 day') as g(day)
      left join (
        select day, count(distinct user_id) as active_users, sum(sessions) as sessions
        from public.app_activity
        group by day
      ) a on a.day = g.day::date
      left join (
        select created_at::date as day, count(*) as signups
        from auth.users
        group by 1
      ) s on s.day = g.day::date
    ),
    'platforms', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'platform', x.platform, 'users', x.users, 'sessions', x.sessions
      ) order by x.sessions desc), '[]'::jsonb)
      from (
        select platform, count(distinct user_id) as users, sum(sessions) as sessions
        from public.app_activity
        where day > current_date - v_days
        group by platform
      ) x
    )
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.is_app_admin() from public, anon;
revoke all on function public.admin_list_users() from public, anon;
revoke all on function public.admin_traffic(integer) from public, anon;
revoke all on function public.app_log_activity(text) from public, anon;

grant execute on function public.is_app_admin() to authenticated;
grant execute on function public.admin_list_users() to authenticated;
grant execute on function public.admin_traffic(integer) to authenticated;
grant execute on function public.app_log_activity(text) to authenticated;
