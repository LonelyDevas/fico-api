-- How much each of the caller's budgets spent inside one month, for budgets longer than a month
-- (yearly): the Budgets page shows the year's total and, under it, the month you are looking at.
-- The month is cut to the budget's own dates, so a budget that started mid-month counts from then.
create or replace function public.budgets_month_spent(p_start timestamptz, p_end timestamptz)
returns jsonb
language sql
stable
as $$
  select coalesce(jsonb_object_agg(b.id, public.budget_calculate_spent(
    b.owner_id, b.category_ids, greatest(b.start_date, p_start), least(b.end_date, p_end)
  )), '{}'::jsonb)
  from public.budgets b
  where b.owner_id = auth.uid()
    and b.period = 'yearly'
    and b.status in ('active', 'exceeded')
    and b.start_date < p_end and b.end_date > p_start;
$$;

grant execute on function public.budgets_month_spent(timestamptz, timestamptz) to authenticated;
