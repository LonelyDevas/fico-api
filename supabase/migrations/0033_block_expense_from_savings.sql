-- A savings wallet can't pay for things directly: the money has to be transferred to another
-- wallet first. The app already hides savings wallets from every "pay from" picker; this makes the
-- database refuse it too, so no other path (an old client, a script) can bypass the rule.
--
-- Only 'expense' rows are checked. Transfers out of savings, income into savings, and the interest
-- the savings wallet earns are all untouched. A transfer's service fee is recorded as an expense on
-- the source wallet; that is part of the transfer, not a payment, so it is let through.
-- Existing rows are left alone. Only new rows, or rows whose type or wallet changes, are checked.

create or replace function public.block_expense_from_savings()
returns trigger
language plpgsql
as $$
declare
  v_wallet_type wallet_type;
begin
  if new.type <> 'expense' then
    return new;
  end if;

  if new.description like 'Service fee for transfer%' then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.type = new.type and old.wallet_id = new.wallet_id then
    return new;
  end if;

  select type into v_wallet_type from public.wallets where id = new.wallet_id;

  if v_wallet_type = 'savings' then
    raise exception 'Savings wallets can''t pay directly. Transfer the money to another wallet first.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists transactions_block_expense_from_savings on public.transactions;
create trigger transactions_block_expense_from_savings
  before insert or update of type, wallet_id on public.transactions
  for each row execute function public.block_expense_from_savings();
