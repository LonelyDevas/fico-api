-- A budget can now cover several categories. Its `spent` is the total of completed expenses in ANY of
-- them. An empty list still means "every expense", the same as the old category-less budget.
--
-- `category_id` stays (set to the first category) so older app versions that are still open keep
-- working; everything new reads `category_ids`.

alter table public.budgets add column category_ids uuid[] not null default '{}';
update public.budgets set category_ids = array[category_id] where category_id is not null;

create index budgets_category_ids_idx on public.budgets using gin (category_ids);

-- Spent across a list of categories (empty or null = all expenses).
create or replace function public.budget_calculate_spent(
  p_owner uuid,
  p_category_ids uuid[],
  p_start timestamptz,
  p_end timestamptz
)
returns numeric
language sql
stable
as $$
  select coalesce(sum(amount), 0)
  from public.transactions
  where owner_id = p_owner
    and type = 'expense'
    and status = 'completed'
    and date >= p_start and date <= p_end
    and (coalesce(cardinality(p_category_ids), 0) = 0 or category_id = any(p_category_ids));
$$;

-- Category details embedded in each budget row, for display.
create or replace function public.budget_categories_json(p_category_ids uuid[])
returns jsonb
language sql
stable
as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'color', c.color, 'icon', c.icon)), '[]'::jsonb)
  from public.categories c
  where c.id = any(coalesce(p_category_ids, '{}'));
$$;

grant execute on function public.budget_categories_json(uuid[]) to authenticated;

-- budgets_create: accepts the new list, and still the old single id.
drop function if exists public.budgets_create(text, numeric, budget_period, timestamptz, uuid, timestamptz, numeric);

create or replace function public.budgets_create(
  p_name text,
  p_amount numeric,
  p_period budget_period,
  p_start_date timestamptz,
  p_category_id uuid default null,
  p_end_date timestamptz default null,
  p_alert_threshold numeric default 80,
  p_category_ids uuid[] default null
)
returns public.budgets
language plpgsql
as $$
declare
  v_end timestamptz;
  v_ids uuid[];
  v_budget public.budgets;
begin
  v_ids := coalesce(p_category_ids, case when p_category_id is null then '{}'::uuid[] else array[p_category_id] end);

  v_end := coalesce(p_end_date, case p_period
    when 'daily' then p_start_date + interval '1 day'
    when 'weekly' then p_start_date + interval '7 days'
    when 'monthly' then p_start_date + interval '1 month'
    when 'yearly' then p_start_date + interval '1 year'
  end);

  insert into public.budgets (
    owner_id, category_id, category_ids, name, amount, spent, period, start_date, end_date,
    alert_threshold, status
  ) values (
    auth.uid(), v_ids[1], v_ids, p_name, p_amount, 0, p_period, p_start_date, v_end,
    coalesce(p_alert_threshold, 80), 'active'
  )
  returning * into v_budget;

  return v_budget;
end;
$$;

grant execute on function public.budgets_create(text, numeric, budget_period, timestamptz, uuid, timestamptz, numeric, uuid[]) to authenticated;

-- budgets_list: same as before, but matches a category filter against the list, recomputes spent
-- across all of a budget's categories, and returns each budget's category details.
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
  select count(*) into v_total
  from public.budgets
  where owner_id = auth.uid()
    and (p_category_id is null or p_category_id = any(category_ids))
    and (p_period is null or period = p_period)
    and status = p_status;

  with page as (
    select * from public.budgets
    where owner_id = auth.uid()
      and (p_category_id is null or p_category_id = any(category_ids))
      and (p_period is null or period = p_period)
      and status = p_status
    order by start_date desc
    offset p_page * p_limit limit p_limit
  ),
  refreshed as (
    update public.budgets b
    set spent = public.budget_calculate_spent(b.owner_id, b.category_ids, b.start_date, b.end_date),
        status = case
          when public.budget_calculate_spent(b.owner_id, b.category_ids, b.start_date, b.end_date) >= b.amount
          then 'exceeded' else b.status end
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

-- budgets_get_current
create or replace function public.budgets_get_current(p_period budget_period default null)
returns jsonb
language plpgsql
as $$
declare
  v_items jsonb;
begin
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
          then 'exceeded' else b.status end
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

-- budgets_check_status
create or replace function public.budgets_check_status(p_id uuid)
returns jsonb
language plpgsql
as $$
declare
  v_budget public.budgets;
  v_spent numeric;
  v_remaining numeric;
  v_percentage numeric;
  v_is_over boolean;
  v_is_near boolean;
begin
  select * into v_budget from public.budgets where id = p_id and owner_id = auth.uid();
  if not found then
    raise exception 'Budget not found or you do not have permission.' using errcode = 'P0002';
  end if;

  v_spent := public.budget_calculate_spent(v_budget.owner_id, v_budget.category_ids, v_budget.start_date, v_budget.end_date);
  v_remaining := v_budget.amount - v_spent;
  v_percentage := case when v_budget.amount > 0 then (v_spent / v_budget.amount) * 100 else 0 end;
  v_is_over := v_spent >= v_budget.amount;
  v_is_near := v_percentage >= coalesce(v_budget.alert_threshold, 80);

  update public.budgets
  set spent = v_spent, status = case when v_is_over then 'exceeded' else status end
  where id = p_id
  returning * into v_budget;

  return jsonb_build_object(
    'budget', to_jsonb(v_budget),
    'spent', v_spent,
    'remaining', v_remaining,
    'percentageUsed', round(v_percentage, 2),
    'isOverBudget', v_is_over,
    'isNearThreshold', v_is_near
  );
end;
$$;

-- budgets_rollover: the new budget keeps the same categories.
create or replace function public.budgets_rollover(p_budget_id uuid)
returns jsonb
language plpgsql
as $$
declare
  v_budget public.budgets;
  v_remaining numeric;
  v_next_start timestamptz;
  v_next_end timestamptz;
  v_new_budget public.budgets;
begin
  select * into v_budget from public.budgets where id = p_budget_id and owner_id = auth.uid();
  if not found then
    raise exception 'Budget not found or you do not have permission.' using errcode = 'P0002';
  end if;

  v_remaining := v_budget.amount - coalesce(v_budget.spent, 0);
  if v_remaining <= 0 then
    raise exception 'No remaining budget to rollover.' using errcode = 'P0001';
  end if;

  v_next_start := v_budget.end_date + interval '1 day';
  v_next_end := case v_budget.period
    when 'daily' then v_next_start + interval '1 day'
    when 'weekly' then v_next_start + interval '7 days'
    when 'monthly' then v_next_start + interval '1 month'
    when 'yearly' then v_next_start + interval '1 year'
  end;

  insert into public.budgets (
    owner_id, category_id, category_ids, name, amount, spent, period, start_date, end_date,
    alert_threshold, status
  ) values (
    v_budget.owner_id, v_budget.category_id, v_budget.category_ids, v_budget.name || ' (Rolled Over)',
    v_budget.amount + v_remaining, 0, v_budget.period, v_next_start, v_next_end,
    v_budget.alert_threshold, 'active'
  )
  returning * into v_new_budget;

  return jsonb_build_object(
    'previousBudgetId', v_budget.id,
    'newBudgetId', v_new_budget.id,
    'rolledOverAmount', v_remaining,
    'newBudgetAmount', v_new_budget.amount,
    'previousPeriod', jsonb_build_object(
      'startDate', v_budget.start_date, 'endDate', v_budget.end_date,
      'spent', v_budget.spent, 'remaining', v_remaining
    ),
    'newPeriod', jsonb_build_object(
      'startDate', v_next_start, 'endDate', v_next_end, 'budgetAmount', v_new_budget.amount
    )
  );
end;
$$;

-- budgets_performance: a multi-category budget shows its categories joined by commas.
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

-- budgets_suggestions: a category already inside any budget is no longer suggested.
create or replace function public.budgets_suggestions()
returns jsonb
language plpgsql
as $$
declare
  v_suggestions jsonb;
begin
  with budgeted as (
    select distinct unnest(category_ids) as category_id from public.budgets
    where owner_id = auth.uid()
  ),
  spending as (
    select t.category_id, c.name, c.icon, c.color,
           sum(t.amount) as total, count(*) as cnt
    from public.transactions t
    join public.categories c on c.id = t.category_id
    where t.owner_id = auth.uid()
      and t.type = 'expense' and t.status = 'completed'
      and t.date >= now() - interval '30 days' and t.date <= now()
      and t.category_id is not null
      and t.category_id not in (select category_id from budgeted)
    group by t.category_id, c.name, c.icon, c.color
    order by total desc
    limit 5
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'categoryId', category_id, 'categoryName', name, 'categoryIcon', icon, 'categoryColor', color,
    'averageMonthlySpend', round(total / 30, 2),
    'totalSpentIn30Days', total, 'transactionCount', cnt,
    'suggestedBudget', ceil(total / 30 * 1.2)
  )), '[]'::jsonb)
  into v_suggestions
  from spending;

  return jsonb_build_object(
    'suggestions', v_suggestions,
    'message', case when jsonb_array_length(v_suggestions) > 0
      then format('We found %s categories you spend on frequently. Create budgets to track them better!', jsonb_array_length(v_suggestions))
      else 'No unbudgeted spending found in the last 30 days.' end,
    'period', jsonb_build_object('startDate', now() - interval '30 days', 'endDate', now(), 'days', 30)
  );
end;
$$;

-- budgets_summary
create or replace function public.budgets_summary()
returns jsonb
language plpgsql
as $$
declare
  v_total integer;
  v_active integer;
  v_exceeded integer;
  v_total_budgeted numeric := 0;
  v_total_spent numeric := 0;
  v_current_count integer;
  r record;
begin
  select count(*) into v_total from public.budgets where owner_id = auth.uid();
  select count(*) into v_active from public.budgets where owner_id = auth.uid() and status = 'active';
  select count(*) into v_exceeded from public.budgets where owner_id = auth.uid() and status = 'exceeded';

  v_current_count := 0;
  for r in
    select * from public.budgets
    where owner_id = auth.uid() and status in ('active', 'exceeded')
      and start_date <= now() and end_date >= now()
  loop
    v_current_count := v_current_count + 1;
    v_total_budgeted := v_total_budgeted + r.amount;
    v_total_spent := v_total_spent + public.budget_calculate_spent(r.owner_id, r.category_ids, r.start_date, r.end_date);
  end loop;

  return jsonb_build_object(
    'totalBudgets', v_total, 'activeBudgets', v_active, 'exceededBudgets', v_exceeded,
    'currentBudgetsCount', v_current_count,
    'totalBudgeted', v_total_budgeted, 'totalSpent', v_total_spent,
    'totalRemaining', v_total_budgeted - v_total_spent
  );
end;
$$;
