-- Where new users drop off: for each signup week, how many came back on day 1, day 3 and day 7 or
-- later (within their first two weeks), plus how many finished onboarding and logged a transaction.
-- Built only from app_activity (0048, one row per user, day and platform) and counts, so no amounts,
-- names or other personal data leave the database. Admin only, like the other admin_* functions.
create or replace function public.admin_retention(p_weeks integer default 8)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_weeks integer := greatest(1, least(coalesce(p_weeks, 8), 52));
  v_result jsonb;
begin
  if not public.is_app_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  with signups as (
    select u.id,
           u.created_at::date as signup_day,
           date_trunc('week', u.created_at)::date as cohort,
           coalesce((u.raw_user_meta_data ->> 'onboarding_completed')::boolean, false) as onboarded
    from auth.users u
    where u.created_at >= date_trunc('week', now()) - make_interval(weeks => v_weeks - 1)
  ),
  per_user as (
    select s.id, s.cohort, s.signup_day, s.onboarded,
           current_date - s.signup_day as age,
           exists (select 1 from public.app_activity a where a.user_id = s.id and a.day - s.signup_day between 1 and 14) as back1,
           exists (select 1 from public.app_activity a where a.user_id = s.id and a.day - s.signup_day between 3 and 14) as back3,
           exists (select 1 from public.app_activity a where a.user_id = s.id and a.day - s.signup_day between 7 and 14) as back7,
           exists (select 1 from public.transactions t where t.owner_id = s.id) as logged
    from signups s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'cohort', c.cohort,
           'signups', c.signups,
           'onboarded', c.onboarded,
           'logged', c.logged,
           -- Each day only counts users old enough to have reached it.
           'eligible1', c.eligible1, 'day1', c.day1,
           'eligible3', c.eligible3, 'day3', c.day3,
           'eligible7', c.eligible7, 'day7', c.day7
         ) order by c.cohort desc), '[]'::jsonb)
  into v_result
  from (
    select cohort,
           count(*) as signups,
           count(*) filter (where onboarded) as onboarded,
           count(*) filter (where logged) as logged,
           count(*) filter (where age >= 1) as eligible1,
           count(*) filter (where age >= 1 and back1) as day1,
           count(*) filter (where age >= 3) as eligible3,
           count(*) filter (where age >= 3 and back3) as day3,
           count(*) filter (where age >= 7) as eligible7,
           count(*) filter (where age >= 7 and back7) as day7
    from per_user
    group by cohort
  ) c;

  return v_result;
end;
$$;

revoke all on function public.admin_retention(integer) from public, anon;
grant execute on function public.admin_retention(integer) to authenticated;
