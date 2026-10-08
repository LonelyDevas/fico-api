-- A budget went to 'exceeded' once spending reached its limit and never came back, even after the
-- spending dropped (an edited or deleted transaction). The default list also only loaded 'active'
-- budgets, so an exceeded one dropped out of it.
--
-- Now the status follows the spending every time it is recalculated: over the limit = exceeded,
-- under it = active. Archived budgets are never touched. The default list shows active and
-- exceeded budgets together.

-- budgets_list
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
  set spent = v_spent,
      status = case
        when status = 'archived' then status
        when v_is_over then 'exceeded' else 'active' end
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

-- budgets_summary: counts come from live spending, so they are right even before a list reload.
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

-- One-time repair: budgets marked exceeded whose spending is back under the limit.
update public.budgets b
set spent = public.budget_calculate_spent(b.owner_id, b.category_ids, b.start_date, b.end_date),
    status = 'active'
where b.status = 'exceeded'
  and public.budget_calculate_spent(b.owner_id, b.category_ids, b.start_date, b.end_date) < b.amount;
