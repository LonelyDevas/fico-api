-- Recurring budgets never moved on to a new period: once a monthly budget's end date passed it kept
-- last month's dates and spending, and dropped out of "current" totals. budgets_advance_periods moves
-- every live budget whose period has ended forward to the period that holds today (same length,
-- counted in Manila time so months keep their real lengths) and recounts its spending. The budget
-- reads call it first, and a nightly job runs it for everyone.

create or replace function public.budgets_advance_periods()
returns integer
language plpgsql
as $$
declare
  b public.budgets;
  v_step interval;
  v_anchor timestamp;
  v_k integer;
  v_start timestamptz;
  v_end timestamptz;
  v_spent numeric;
  v_moved integer := 0;
begin
  for b in
    select * from public.budgets
    where status in ('active', 'exceeded')
      and end_date < now()
      -- Signed in: only your own. The nightly job (no user) covers everyone.
      and (auth.uid() is null or owner_id = auth.uid())
    for update
  loop
    v_step := case b.period
      when 'daily' then interval '1 day'
      when 'weekly' then interval '7 days'
      when 'monthly' then interval '1 month'
      else interval '1 year' end;
    -- Step from the original start (not the end) so a budget starting on the 31st doesn't drift.
    v_anchor := b.start_date at time zone 'Asia/Manila';
    v_k := 1;
    loop
      v_start := (v_anchor + v_step * v_k) at time zone 'Asia/Manila';
      v_end := (v_anchor + v_step * (v_k + 1)) at time zone 'Asia/Manila';
      exit when v_end >= now() or v_k > 10000;
      v_k := v_k + 1;
    end loop;

    v_spent := public.budget_calculate_spent(b.owner_id, b.category_ids, v_start, v_end);
    update public.budgets
    set start_date = v_start, end_date = v_end, spent = v_spent,
        status = (case when v_spent >= amount then 'exceeded' else 'active' end)::budget_status
    where id = b.id;
    v_moved := v_moved + 1;
  end loop;

  return v_moved;
end;
$$;

grant execute on function public.budgets_advance_periods() to authenticated;

create or replace function public.budgets_list(
  p_page integer default 0,
  p_limit integer default 20,
  p_category_id uuid default null,
  p_period budget_period default null,
  p_status budget_status default 'active'
)
returns jsonb
language plpgsql
as $$
declare
  v_total integer;
  v_items jsonb;
begin
  perform public.budgets_advance_periods();

  -- 'active' stands for "live budgets": active and exceeded alike.
  select count(*) into v_total
  from public.budgets
  where owner_id = auth.uid()
    and (p_category_id is null or p_category_id = any(category_ids))
    and (p_period is null or period = p_period)
    and (status = p_status or (p_status = 'active' and status = 'exceeded'));

  with page as (
    select * from public.budgets
    where owner_id = auth.uid()
      and (p_category_id is null or p_category_id = any(category_ids))
      and (p_period is null or period = p_period)
      and (status = p_status or (p_status = 'active' and status = 'exceeded'))
    order by start_date desc
    offset p_page * p_limit limit p_limit
  ),
  refreshed as (
    update public.budgets b
    set spent = public.budget_calculate_spent(b.owner_id, b.category_ids, b.start_date, b.end_date),
        status = case
          when b.status = 'archived' then b.status
          when public.budget_calculate_spent(b.owner_id, b.category_ids, b.start_date, b.end_date) >= b.amount
            then 'exceeded' else 'active' end
    from page
    where b.id = page.id
    returning b.*
  )
  select coalesce(
    jsonb_agg(to_jsonb(r) || jsonb_build_object('categories', public.budget_categories_json(r.category_ids))),
    '[]'::jsonb
  ) into v_items from refreshed r;

  return jsonb_build_object(
    'items', v_items,
    'totalPages', ceil(v_total::numeric / greatest(p_limit, 1)),
    'currentPage', p_page,
    'totalItems', v_total
  );
end;
$$;

create or replace function public.budgets_get_current(p_period budget_period default null)
returns jsonb
language plpgsql
as $$
declare
  v_items jsonb;
begin
  perform public.budgets_advance_periods();

  with current_budgets as (
    select * from public.budgets
    where owner_id = auth.uid()
      and status in ('active', 'exceeded')
      and start_date <= now() and end_date >= now()
      and (p_period is null or period = p_period)
  ),
  refreshed as (
    update public.budgets b
    set spent = public.budget_calculate_spent(b.owner_id, b.category_ids, b.start_date, b.end_date),
        status = case
          when public.budget_calculate_spent(b.owner_id, b.category_ids, b.start_date, b.end_date) >= b.amount
            then 'exceeded' else 'active' end
    from current_budgets
    where b.id = current_budgets.id
    returning b.*
  )
  select coalesce(
    jsonb_agg(to_jsonb(r) || jsonb_build_object('categories', public.budget_categories_json(r.category_ids))),
    '[]'::jsonb
  ) into v_items from refreshed r;

  return jsonb_build_object('items', v_items, 'totalBudgets', jsonb_array_length(v_items));
end;
$$;

create or replace function public.budgets_summary()
returns jsonb
language plpgsql
as $$
declare
  v_total integer;
  v_active integer := 0;
  v_exceeded integer := 0;
  v_total_budgeted numeric := 0;
  v_total_spent numeric := 0;
  v_current_count integer := 0;
  v_spent numeric;
  r record;
begin
  perform public.budgets_advance_periods();

  select count(*) into v_total from public.budgets where owner_id = auth.uid();

  for r in
    select * from public.budgets
    where owner_id = auth.uid() and status in ('active', 'exceeded')
  loop
    v_spent := public.budget_calculate_spent(r.owner_id, r.category_ids, r.start_date, r.end_date);
    if v_spent >= r.amount then
      v_exceeded := v_exceeded + 1;
    else
      v_active := v_active + 1;
    end if;

    if r.start_date <= now() and r.end_date >= now() then
      v_current_count := v_current_count + 1;
      v_total_budgeted := v_total_budgeted + r.amount;
      v_total_spent := v_total_spent + v_spent;
    end if;
  end loop;

  return jsonb_build_object(
    'totalBudgets', v_total, 'activeBudgets', v_active, 'exceededBudgets', v_exceeded,
    'currentBudgetsCount', v_current_count,
    'totalBudgeted', v_total_budgeted, 'totalSpent', v_total_spent,
    'totalRemaining', v_total_budgeted - v_total_spent
  );
end;
$$;

create or replace function public.budgets_performance()
returns jsonb
language plpgsql
as $$
declare
  v_budgets jsonb;
  v_total_budgeted numeric := 0;
  v_total_spent numeric := 0;
  v_first_start timestamptz;
  v_first_end timestamptz;
  v_days_elapsed integer;
  v_days_remaining integer;
  v_overall_burn_rate numeric;
begin
  perform public.budgets_advance_periods();

  with current_budgets as (
    select b.*,
      (select string_agg(c.name, ', ' order by c.name) from public.categories c where c.id = any(b.category_ids)) as category_name
    from public.budgets b
    where b.owner_id = auth.uid()
      and b.status in ('active', 'exceeded')
      and b.start_date <= now() and b.end_date >= now()
  ),
  metrics as (
    select
      cb.id as budget_id, cb.name, coalesce(cb.category_name, 'All expenses') as category_name,
      cb.amount,
      public.budget_calculate_spent(cb.owner_id, cb.category_ids, cb.start_date, cb.end_date) as spent,
      ceil(extract(epoch from (cb.end_date - cb.start_date)) / 86400)::integer as total_days,
      ceil(extract(epoch from (now() - cb.start_date)) / 86400)::integer as days_elapsed,
      cb.start_date, cb.end_date
    from current_budgets cb
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'budgetId', budget_id, 'name', name, 'categoryName', category_name,
      'amount', amount, 'spent', spent, 'remaining', amount - spent,
      'percentageUsed', case when amount > 0 then (spent / amount) * 100 else 0 end,
      'burnRate', round(case when total_days > 0 and days_elapsed > 0
        then (spent / nullif((amount / total_days) * days_elapsed, 0)) * 100 else 0 end, 2),
      'daysElapsed', days_elapsed, 'daysRemaining', total_days - days_elapsed,
      'status', case
        when total_days > 0 and days_elapsed > 0
          and (spent / nullif((amount / total_days) * days_elapsed, 0)) * 100 > 100 then 'OverBudget'
        when total_days > 0 and days_elapsed > 0
          and (spent / nullif((amount / total_days) * days_elapsed, 0)) * 100 < 100 then 'UnderBudget'
        else 'OnTrack' end
    )), '[]'::jsonb),
    coalesce(sum(amount), 0), coalesce(sum(spent), 0),
    min(start_date), max(end_date)
  into v_budgets, v_total_budgeted, v_total_spent, v_first_start, v_first_end
  from metrics;

  if v_first_start is null then
    return jsonb_build_object(
      'message', 'No active budgets for this period', 'budgets', '[]'::jsonb,
      'overallBurnRate', 0, 'totalBudgeted', 0, 'totalSpent', 0, 'daysElapsed', 0, 'daysRemaining', 0
    );
  end if;

  v_days_elapsed := ceil(extract(epoch from (now() - v_first_start)) / 86400);
  v_days_remaining := ceil(extract(epoch from (v_first_end - v_first_start)) / 86400) - v_days_elapsed;
  v_overall_burn_rate := case when v_total_budgeted > 0 then (v_total_spent / v_total_budgeted) * 100 else 0 end;

  return jsonb_build_object(
    'budgets', v_budgets,
    'overallBurnRate', round(v_overall_burn_rate, 2),
    'totalBudgeted', v_total_budgeted,
    'totalSpent', v_total_spent,
    'totalRemaining', v_total_budgeted - v_total_spent,
    'daysElapsed', v_days_elapsed,
    'daysRemaining', v_days_remaining,
    'message', case when v_overall_burn_rate > 100
      then format('⚠️ You are %s%% through your budgets. Slow down!', round(v_overall_burn_rate, 0))
      else format('✓ You are %s%% through your budgets. On track!', round(v_overall_burn_rate, 0)) end
  );
end;
$$;

do $$
begin
  perform cron.schedule('budget-periods', '5 16 * * *', $c$select public.budgets_advance_periods()$c$);
exception when others then
  raise notice 'pg_cron not enabled; schedule budgets_advance_periods manually: %', sqlerrm;
end;
$$;

-- Bring every budget up to date now.
select public.budgets_advance_periods();
