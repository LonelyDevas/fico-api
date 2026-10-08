-- Credit cards. For a credit_card wallet, `balance` is the amount USED (owed),
-- so every balance change is inverted: spending raises it, paying it down
-- (a transfer into the card, a refund, or a bill that pays the card) lowers it,
-- and spending is limited by credit_limit instead of by the balance.

alter table public.wallets
  add column if not exists statement_day smallint check (statement_day between 1 and 28),
  add column if not exists due_day smallint check (due_day between 1 and 28);

-- A bill that pays off a card (the monthly statement). Marking it paid lowers
-- that card's used amount.
alter table public.bills
  add column if not exists pays_wallet_id uuid references public.wallets(id);

-- Applies a change expressed as "money in is positive" to a wallet, flipping
-- the sign for credit cards.
create or replace function public.wallet_apply(p_wallet_id uuid, p_delta numeric)
returns public.wallets
language plpgsql
as $$
declare
  v_wallet public.wallets;
begin
  update public.wallets
  set balance = balance + case when type::text = 'credit_card' then -p_delta else p_delta end
  where id = p_wallet_id and owner_id = auth.uid()
  returning * into v_wallet;
  return v_wallet;
end;
$$;

-- Can this wallet pay out p_amount? Cards: stay within the credit limit (no
-- limit set = unlimited). Everything else: have enough balance.
create or replace function public.wallet_can_afford(p_wallet public.wallets, p_amount numeric)
returns boolean
language sql
immutable
as $$
  select case
    when p_wallet.type::text = 'credit_card' then p_wallet.credit_limit is null or p_wallet.balance + p_amount <= p_wallet.credit_limit
    else p_wallet.balance >= p_amount
  end;
$$;

-- transactions_create: same as 0014, with card-aware balance math.
create or replace function public.transactions_create(
  p_wallet_id uuid,
  p_amount numeric,
  p_type transaction_type,
  p_category_id uuid default null,
  p_description text default null,
  p_date timestamptz default now(),
  p_attachments text[] default '{}',
  p_tags text[] default '{}',
  p_to_wallet_id uuid default null,
  p_bill_id uuid default null,
  p_service_fee numeric default 0,
  p_create_bill_for_fee boolean default false
)
returns public.transactions
language plpgsql
as $$
declare
  v_wallet public.wallets;
  v_to_wallet public.wallets;
  v_immediate_fee numeric := 0;
  v_total_deduction numeric;
  v_fee_deducted boolean := false;
  v_txn public.transactions;
  v_fee_due_date timestamptz;
  v_fee_txn public.transactions;
begin
  select * into v_wallet from public.wallets
  where id = p_wallet_id and owner_id = auth.uid() and status = 'active';
  if not found then
    raise exception 'Wallet not found or inactive.' using errcode = 'P0002';
  end if;

  if p_type = 'transfer' then
    if p_to_wallet_id is null then
      raise exception 'Destination wallet required for transfers.' using errcode = 'P0001';
    end if;
    if p_wallet_id = p_to_wallet_id then
      raise exception 'Cannot transfer to the same wallet.' using errcode = 'P0001';
    end if;
    select * into v_to_wallet from public.wallets
    where id = p_to_wallet_id and owner_id = auth.uid() and status = 'active';
    if not found then
      raise exception 'Destination wallet not found or inactive.' using errcode = 'P0002';
    end if;
  end if;

  v_immediate_fee := case when not p_create_bill_for_fee and p_service_fee > 0 then p_service_fee else 0 end;
  v_total_deduction := case when p_type = 'transfer' then p_amount + v_immediate_fee else p_amount end;

  if p_type in ('expense', 'transfer') and not public.wallet_can_afford(v_wallet, v_total_deduction) then
    if v_wallet.type::text = 'credit_card' then
      raise exception 'This would go over the card''s credit limit.' using errcode = 'P0001';
    end if;
    raise exception 'Insufficient wallet balance for transaction%',
      case when v_immediate_fee > 0 then ' and service fee.' else '.' end
      using errcode = 'P0001';
  end if;

  v_fee_deducted := (p_type = 'transfer' and p_service_fee > 0 and not p_create_bill_for_fee);

  insert into public.transactions (
    owner_id, wallet_id, category_id, amount, type, description, date,
    attachments, tags, to_wallet_id, bill_id, service_fee, service_fee_deducted, status
  ) values (
    auth.uid(), p_wallet_id, p_category_id, p_amount, p_type, p_description, p_date,
    p_attachments, p_tags, p_to_wallet_id, p_bill_id, p_service_fee, v_fee_deducted, 'completed'
  )
  returning * into v_txn;

  if p_type = 'income' then
    perform public.wallet_apply(p_wallet_id, p_amount);
  elsif p_type = 'expense' then
    perform public.wallet_apply(p_wallet_id, -p_amount);
  elsif p_type = 'transfer' then
    perform public.wallet_apply(p_wallet_id, -(p_amount + case when v_fee_deducted then p_service_fee else 0 end));
    perform public.wallet_apply(p_to_wallet_id, p_amount);
  end if;

  if p_bill_id is not null then
    update public.bills
    set payment_status = 'paid', paid_amount = p_amount, last_paid_date = v_txn.date
    where id = p_bill_id and owner_id = auth.uid();
  end if;

  if p_create_bill_for_fee and p_service_fee > 0 then
    v_fee_due_date := v_txn.date + interval '1 day';

    insert into public.transactions (
      owner_id, wallet_id, amount, type, description, date, attachments, tags, status
    ) values (
      auth.uid(), p_wallet_id, p_service_fee, 'expense',
      format('Service fee for transfer of %s', p_amount), v_fee_due_date, '{}', '{}', 'pending'
    )
    returning * into v_fee_txn;

    insert into public.bills (
      owner_id, name, amount, due_date, is_recurring, wallet_id, reminder,
      payment_status, notes, status, transaction_id
    ) values (
      auth.uid(), 'Transfer Service Fee', p_service_fee, v_fee_due_date, false, p_wallet_id, false,
      'unpaid', format('Service fee for transfer transaction ID: %s', v_txn.id), 'active', v_fee_txn.id
    );
  end if;

  return v_txn;
end;
$$;

grant execute on function public.transactions_create(
  uuid, numeric, transaction_type, uuid, text, timestamptz, text[], text[], uuid, uuid, numeric, boolean
) to authenticated;

-- transactions_delete: same as 0014, reversing through wallet_apply.
create or replace function public.transactions_delete(p_id uuid)
returns void
language plpgsql
as $$
declare
  v_txn public.transactions;
begin
  select * into v_txn from public.transactions
  where id = p_id and owner_id = auth.uid();

  if not found then
    raise exception 'Transaction not found or you do not have permission.' using errcode = 'P0002';
  end if;

  if v_txn.status <> 'completed' then
    raise exception 'Can only delete completed transactions.' using errcode = 'P0001';
  end if;

  if v_txn.type = 'income' then
    perform public.wallet_apply(v_txn.wallet_id, -v_txn.amount);
  elsif v_txn.type = 'expense' then
    perform public.wallet_apply(v_txn.wallet_id, v_txn.amount);
  elsif v_txn.type = 'transfer' and v_txn.to_wallet_id is not null then
    perform public.wallet_apply(
      v_txn.wallet_id,
      v_txn.amount + case when v_txn.service_fee_deducted then v_txn.service_fee else 0 end
    );
    perform public.wallet_apply(v_txn.to_wallet_id, -v_txn.amount);
  end if;

  delete from public.transactions where id = p_id;
end;
$$;

grant execute on function public.transactions_delete(uuid) to authenticated;

-- bills_mark_paid: same as 0015, with two card rules:
--   * paying a bill FROM a card raises that card's used amount (limit-checked);
--   * a bill that pays a card (pays_wallet_id) lowers that card's used amount.
create or replace function public.bills_mark_paid(
  p_id uuid,
  p_paid_amount numeric default null,
  p_paid_date timestamptz default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
as $$
declare
  v_bill public.bills;
  v_amount_paid numeric;
  v_payment_date timestamptz;
  v_wallet public.wallets;
  v_payment_status bill_payment_status;
  v_obligation public.obligations;
  v_new_remaining numeric;
  v_new_paid_installments integer;
  v_new_obl_status obligation_status;
  v_next_due_date timestamptz;
  v_next_bill public.bills;
  v_next_txn public.transactions;
begin
  if p_idempotency_key is not null and exists (
    select 1 from public.transactions
    where owner_id = auth.uid()
      and idempotency_key = p_idempotency_key
      and created_at >= now() - interval '24 hours'
      and status = 'completed'
  ) then
    return jsonb_build_object(
      'id', p_id,
      'message', 'Duplicate payment request detected. Original payment processed.'
    );
  end if;

  select * into v_bill from public.bills where id = p_id and owner_id = auth.uid();
  if not found then
    raise exception 'Bill not found or you do not have permission.' using errcode = 'P0002';
  end if;

  v_amount_paid := coalesce(p_paid_amount, v_bill.amount);
  v_payment_date := coalesce(p_paid_date, now());

  if v_bill.wallet_id is not null then
    select * into v_wallet from public.wallets where id = v_bill.wallet_id and owner_id = auth.uid();
    if not found then
      raise exception 'Linked wallet not found or inactive.' using errcode = 'P0002';
    end if;

    if not public.wallet_can_afford(v_wallet, v_amount_paid) then
      if v_wallet.type::text = 'credit_card' then
        raise exception 'This payment would go over the card''s credit limit.' using errcode = 'P0001';
      end if;
      raise exception 'Insufficient wallet balance to pay this bill.' using errcode = 'P0001';
    end if;

    perform public.wallet_apply(v_bill.wallet_id, -v_amount_paid);
  end if;

  if v_bill.pays_wallet_id is not null then
    perform public.wallet_apply(v_bill.pays_wallet_id, v_amount_paid);
  end if;

  v_payment_status := case when v_amount_paid >= v_bill.amount then 'paid' else 'partial' end;

  if v_bill.transaction_id is not null then
    update public.transactions
    set status = 'completed', amount = v_amount_paid, date = v_payment_date,
        idempotency_key = coalesce(p_idempotency_key, idempotency_key)
    where id = v_bill.transaction_id;
  end if;

  if v_bill.obligation_id is not null then
    select * into v_obligation from public.obligations where id = v_bill.obligation_id;
    if found and v_obligation.status not in ('settled', 'archived') then
      v_new_remaining := round(greatest(0, v_obligation.remaining_balance - v_amount_paid)::numeric, 2);
      v_new_paid_installments := case when v_obligation.is_installment
        then v_obligation.paid_installments + 1 else v_obligation.paid_installments end;
      v_new_obl_status := case
        when v_new_remaining <= 0 then 'settled'
        when v_new_paid_installments > 0 then 'partially_paid'
        else 'active'
      end;

      update public.obligations
      set remaining_balance = v_new_remaining,
          paid_installments = v_new_paid_installments,
          status = v_new_obl_status
      where id = v_obligation.id;
    end if;
  end if;

  if v_bill.is_recurring and v_bill.recurring_frequency is not null then
    v_next_due_date := public.calculate_next_due_date(v_bill.due_date, v_bill.recurring_frequency);

    insert into public.bills (
      owner_id, name, amount, category_id, due_date, is_recurring, recurring_frequency,
      wallet_id, reminder, reminder_days, notes, payment_status, status, parent_bill_id, type,
      pays_wallet_id
    ) values (
      v_bill.owner_id, v_bill.name, v_bill.amount, v_bill.category_id, v_next_due_date,
      v_bill.is_recurring, v_bill.recurring_frequency, v_bill.wallet_id, v_bill.reminder,
      v_bill.reminder_days, v_bill.notes, 'unpaid', 'active',
      coalesce(v_bill.parent_bill_id, v_bill.id), v_bill.type,
      v_bill.pays_wallet_id
    )
    returning * into v_next_bill;

    if v_bill.wallet_id is not null then
      insert into public.transactions (
        owner_id, wallet_id, category_id, amount, type, description, date,
        attachments, tags, bill_id, status
      ) values (
        v_bill.owner_id, v_bill.wallet_id, v_bill.category_id, v_bill.amount, 'expense',
        format('Bill: %s', v_bill.name), v_next_due_date, '{}', '{}', v_next_bill.id, 'pending'
      )
      returning * into v_next_txn;

      update public.bills set transaction_id = v_next_txn.id where id = v_next_bill.id;
    end if;
  end if;

  update public.bills
  set paid_amount = v_amount_paid, last_paid_date = v_payment_date, payment_status = v_payment_status
  where id = p_id;

  return jsonb_build_object(
    'billId', p_id,
    'amountPaid', v_amount_paid,
    'nextDueDate', v_next_due_date,
    'isRecurring', v_bill.is_recurring
  );
end;
$$;

grant execute on function public.bills_mark_paid(uuid, numeric, timestamptz, text) to authenticated;

-- bills_summary: total wallet balance now treats card balances as money owed.
create or replace function public.bills_summary()
returns jsonb
language plpgsql
stable
as $$
declare
  v_total_bills integer;
  v_paid_bills integer;
  v_unpaid_bills integer;
  v_overdue_bills integer;
  v_partial_bills integer;
  v_recurring_bills integer;
  v_total_amount_due numeric;
  v_upcoming_amount numeric;
  v_overdue_amount numeric;
  v_total_wallet_balance numeric;
begin
  select
    count(*),
    count(*) filter (where payment_status = 'paid'),
    count(*) filter (where payment_status = 'unpaid'),
    count(*) filter (where payment_status = 'overdue'),
    count(*) filter (where payment_status = 'partial'),
    count(*) filter (where is_recurring)
  into v_total_bills, v_paid_bills, v_unpaid_bills, v_overdue_bills, v_partial_bills, v_recurring_bills
  from public.bills
  where owner_id = auth.uid() and status = 'active';

  select
    coalesce(sum(amount), 0),
    coalesce(sum(amount) filter (where due_date > now()), 0),
    coalesce(sum(amount) filter (where due_date < now()), 0)
  into v_total_amount_due, v_upcoming_amount, v_overdue_amount
  from public.bills
  where owner_id = auth.uid() and status = 'active'
    and payment_status in ('unpaid', 'overdue', 'partial');

  select coalesce(sum(case when type::text = 'credit_card' then -balance else balance end), 0)
  into v_total_wallet_balance
  from public.wallets where owner_id = auth.uid() and status = 'active';

  return jsonb_build_object(
    'totalBills', v_total_bills,
    'paidBills', v_paid_bills,
    'unpaidBills', v_unpaid_bills,
    'overdueBills', v_overdue_bills,
    'partialBills', v_partial_bills,
    'recurringBills', v_recurring_bills,
    'totalAmountDue', v_total_amount_due,
    'upcomingAmount', v_upcoming_amount,
    'overdueAmount', v_overdue_amount,
    'totalWalletBalance', v_total_wallet_balance,
    'disposableIncome', v_total_wallet_balance - v_total_amount_due,
    'summary', jsonb_build_object(
      'message', format('You have %s unpaid bills totaling ₱%s',
        v_unpaid_bills + v_overdue_bills, to_char(v_total_amount_due, 'FM999999990.00'))
    )
  );
end;
$$;

grant execute on function public.bills_summary() to authenticated;

-- cards_sync_bills: keeps one open "<card> payment" bill per card that has a
-- due day. The amount follows the card's current used balance; when it is paid
-- the bill is gone for this cycle and the next sync opens the following one.
-- Called by the app when the Money page opens, so it needs no scheduler.
create or replace function public.cards_sync_bills()
returns integer
language plpgsql
as $$
declare
  c record;
  v_due timestamptz;
  v_source uuid;
  v_open public.bills;
  v_touched integer := 0;
begin
  for c in
    select * from public.wallets
    where owner_id = auth.uid() and type::text = 'credit_card' and status = 'active' and due_day is not null
  loop
    v_due := (date_trunc('month', current_date) + ((c.due_day - 1) * interval '1 day'))::timestamptz;
    if v_due::date < current_date then
      v_due := v_due + interval '1 month';
    end if;

    select * into v_open from public.bills
    where owner_id = auth.uid() and pays_wallet_id = c.id
      and payment_status in ('unpaid', 'overdue', 'partial') and status = 'active'
    order by due_date limit 1;

    if found then
      if c.balance <= 0 then
        update public.bills set status = 'archived' where id = v_open.id;
      elsif v_open.amount <> c.balance then
        update public.bills set amount = c.balance where id = v_open.id;
      end if;
      v_touched := v_touched + 1;
    elsif c.balance > 0 then
      -- Default to paying from the richest non-card wallet; the user can change it on the bill.
      select id into v_source from public.wallets
      where owner_id = auth.uid() and status = 'active' and type::text <> 'credit_card'
      order by balance desc limit 1;

      insert into public.bills (
        owner_id, type, name, amount, due_date, is_recurring, wallet_id, pays_wallet_id,
        reminder, reminder_days, payment_status, status, notes
      ) values (
        auth.uid(), 'bill', c.name || ' payment', c.balance, v_due, false, v_source, c.id,
        true, 3, 'unpaid', 'active', 'Credit card payment. The amount follows what you currently owe on the card.'
      );
      v_touched := v_touched + 1;
    end if;
  end loop;

  return v_touched;
end;
$$;

grant execute on function public.cards_sync_bills() to authenticated;
