-- 0059 moved a budget's own dates forward when its period ended, which erased last month: the
-- October budget became the November one. Now each period is its own row. When a period ends,
-- that row keeps its dates and spending, and a copy is created for the next period and linked
-- from it (next_budget_id). Only the latest row of a chain moves on.

alter table public.budgets
  add column if not exists next_budget_id uuid references public.budgets(id) on delete set null;

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
  v_new public.budgets;
  v_created integer := 0;
begin
  for b in
    select * from public.budgets
    where status in ('active', 'exceeded')
      and next_budget_id is null
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

    -- One row per period up to the one holding today, so skipped months still have a record.
    -- Daily budgets left alone for a long time only get the last 60 periods.
    if b.period = 'daily' then
      v_k := greatest(1, floor(extract(epoch from (now() - b.start_date)) / 86400)::integer - 59);
    end if;

    loop
      v_start := (v_anchor + v_step * v_k) at time zone 'Asia/Manila';
      v_end := (v_anchor + v_step * (v_k + 1)) at time zone 'Asia/Manila';
      v_spent := public.budget_calculate_spent(b.owner_id, b.category_ids, v_start, v_end);

      insert into public.budgets (
        owner_id, category_id, category_ids, name, amount, spent, period, start_date, end_date,
        alert_threshold, status
      ) values (
        b.owner_id, b.category_id, b.category_ids, b.name, b.amount, v_spent, b.period, v_start, v_end,
        b.alert_threshold, (case when v_spent >= b.amount then 'exceeded' else 'active' end)::budget_status
      )
      returning * into v_new;

      update public.budgets set next_budget_id = v_new.id where id = b.id;
      v_created := v_created + 1;
      b := v_new;

      exit when v_end >= now() or v_k > 400;
      v_k := v_k + 1;
    end loop;
  end loop;

  return v_created;
end;
$$;

grant execute on function public.budgets_advance_periods() to authenticated;

-- budgets_summary: counts only the budgets running today, so past months' rows don't inflate it.
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

  -- One per budget: the latest row of each chain.
  select count(*) into v_total from public.budgets
  where owner_id = auth.uid() and next_budget_id is null;

  for r in
    select * from public.budgets
    where owner_id = auth.uid() and status in ('active', 'exceeded')
      and start_date <= now() and end_date >= now()
  loop
    v_spent := public.budget_calculate_spent(r.owner_id, r.category_ids, r.start_date, r.end_date);
    if v_spent >= r.amount then
      v_exceeded := v_exceeded + 1;
    else
      v_active := v_active + 1;
    end if;
    v_current_count := v_current_count + 1;
    v_total_budgeted := v_total_budgeted + r.amount;
    v_total_spent := v_total_spent + v_spent;
  end loop;

  return jsonb_build_object(
    'totalBudgets', v_total, 'activeBudgets', v_active, 'exceededBudgets', v_exceeded,
    'currentBudgetsCount', v_current_count,
    'totalBudgeted', v_total_budgeted, 'totalSpent', v_total_spent,
    'totalRemaining', v_total_budgeted - v_total_spent
  );
end;
$$;

-- budgets_rollover (carry the unspent amount into the next period): the new period now starts
-- where the old one ends (it skipped a day) and is linked, so the automatic advance doesn't make
-- a second copy of it.
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

  v_next_start := v_budget.end_date;
  v_next_end := ((v_next_start at time zone 'Asia/Manila') + case v_budget.period
    when 'daily' then interval '1 day'
    when 'weekly' then interval '7 days'
    when 'monthly' then interval '1 month'
    else interval '1 year'
  end) at time zone 'Asia/Manila';

  insert into public.budgets (
    owner_id, category_id, category_ids, name, amount, spent, period, start_date, end_date,
    alert_threshold, status
  ) values (
    v_budget.owner_id, v_budget.category_id, v_budget.category_ids, v_budget.name || ' (Rolled Over)',
    v_budget.amount + v_remaining, 0, v_budget.period, v_next_start, v_next_end,
    v_budget.alert_threshold, 'active'
  )
  returning * into v_new_budget;

  update public.budgets set next_budget_id = v_new_budget.id where id = v_budget.id;

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
