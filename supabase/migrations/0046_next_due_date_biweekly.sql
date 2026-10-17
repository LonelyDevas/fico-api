-- calculate_next_due_date understands bi-weekly.
-- Restored from the offline app's local schema (fico lib/local/schema.generated.ts).

create or replace function public.calculate_next_due_date(
  p_current timestamptz,
  p_frequency recurring_frequency
)
returns timestamptz
language sql
immutable
as $$
  select case p_frequency
    when 'daily' then p_current + interval '1 day'
    when 'weekly' then p_current + interval '7 days'
    when 'biweekly' then p_current + interval '14 days'
    when 'monthly' then p_current + interval '1 month'
    when 'yearly' then p_current + interval '1 year'
    else p_current
  end;
$$;
