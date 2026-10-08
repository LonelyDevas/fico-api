-- "Overdue" is a stored status: bills_get_overdue() flips unpaid bills past their due date to it, but
-- nothing ever flipped them back. Moving a bill's due date to the future left it marked Overdue.
--
-- 1. Trigger: when a bill's due date moves to today or later, an overdue bill goes back to unpaid
--    (or partial, if some of it was already paid).
-- 2. One-time repair: bills already stuck as overdue with a due date that is not in the past.

create or replace function public.bills_reset_overdue_on_new_date()
returns trigger
language plpgsql
as $$
begin
  if new.payment_status = 'overdue'
     and new.due_date is distinct from old.due_date
     and new.due_date >= date_trunc('day', now()) then
    new.payment_status := case when coalesce(new.paid_amount, 0) > 0 then 'partial'::bill_payment_status else 'unpaid'::bill_payment_status end;
  end if;
  return new;
end;
$$;

create trigger bills_reset_overdue_on_new_date
  before update of due_date on public.bills
  for each row execute function public.bills_reset_overdue_on_new_date();

update public.bills
set payment_status = case when coalesce(paid_amount, 0) > 0 then 'partial'::bill_payment_status else 'unpaid'::bill_payment_status end
where payment_status = 'overdue'
  and status = 'active'
  and due_date >= date_trunc('day', now());
