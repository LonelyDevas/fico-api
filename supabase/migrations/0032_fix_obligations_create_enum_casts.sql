-- obligations_create: 0017/0031 built enum columns from bare CASE expressions of string
-- literals, which Postgres types as text, so creating an obligation with a wallet or
-- installments failed with "column \"type\" is of type ... but expression is of type text".
-- Same function with explicit enum casts.
create or replace function public.obligations_create(
  p_direction obligation_direction,
  p_name text,
  p_counterparty text,
  p_principal_amount numeric,
  p_start_date timestamptz,
  p_counterparty_contact text default null,
  p_currency text default 'PHP',
  p_interest_rate numeric default null,
  p_interest_type interest_type default null,
  p_due_date timestamptz default null,
  p_wallet_id uuid default null,
  p_category_id uuid default null,
  p_notes text default null,
  p_tags text[] default '{}',
  p_is_installment boolean default false,
  p_installment_amount numeric default null,
  p_total_installments integer default null,
  p_installment_frequency installment_frequency default null
)
returns public.obligations
language plpgsql
as $$
declare
  v_total_with_interest numeric;
  v_obligation public.obligations;
  v_wallet public.wallets;
  v_disbursement_tx public.transactions;
  v_due_dates timestamptz[];
  v_due_date timestamptz;
  v_bill public.bills;
  v_txn public.transactions;
begin
  if p_is_installment and (p_installment_amount is null or p_total_installments is null or p_installment_frequency is null) then
    raise exception 'installmentAmount, totalInstallments, and installmentFrequency are required for installment obligations.'
      using errcode = 'P0001';
  end if;

  v_total_with_interest := case when p_interest_rate is not null and p_interest_type is not null
    then public.compute_total_with_interest(p_principal_amount, p_interest_rate, p_interest_type, p_start_date, p_due_date)
    else null end;

  if p_wallet_id is not null then
    select * into v_wallet from public.wallets where id = p_wallet_id and owner_id = auth.uid() and status = 'active';
    if not found then
      raise exception 'Wallet not found.' using errcode = 'P0002';
    end if;
    -- Lending sends money out of the wallet.
    if p_direction <> 'debt' and not public.wallet_can_afford(v_wallet, p_principal_amount) then
      raise exception 'Insufficient wallet balance to lend this amount.' using errcode = 'P0001';
    end if;
  end if;

  insert into public.obligations (
    owner_id, direction, name, counterparty, counterparty_contact, principal_amount,
    remaining_balance, currency, interest_rate, interest_type, total_with_interest,
    start_date, due_date, wallet_id, category_id, notes, tags, status,
    is_installment, installment_amount, total_installments, paid_installments, installment_frequency
  ) values (
    auth.uid(), p_direction, p_name, p_counterparty, p_counterparty_contact, p_principal_amount,
    coalesce(v_total_with_interest, p_principal_amount), coalesce(p_currency, 'PHP'),
    p_interest_rate, p_interest_type, v_total_with_interest,
    p_start_date, p_due_date, p_wallet_id, p_category_id, p_notes, coalesce(p_tags, '{}'), 'active',
    coalesce(p_is_installment, false), p_installment_amount, p_total_installments, 0, p_installment_frequency
  )
  returning * into v_obligation;

  if p_wallet_id is not null then
    perform public.wallet_apply(p_wallet_id, case when p_direction = 'debt' then p_principal_amount else -p_principal_amount end);

    insert into public.transactions (
      owner_id, wallet_id, category_id, amount, type, description, date, attachments, tags, status
    ) values (
      auth.uid(), p_wallet_id, p_category_id, p_principal_amount,
      (case when p_direction = 'debt' then 'income' else 'expense' end)::transaction_type,
      format('%s %s: %s', case when p_direction = 'debt' then 'Borrowed from' else 'Lent to' end, p_counterparty, p_name),
      p_start_date, '{}', coalesce(p_tags, '{}'), 'completed'
    )
    returning * into v_disbursement_tx;

    update public.obligations set disbursement_transaction_id = v_disbursement_tx.id where id = v_obligation.id;
  end if;

  if p_is_installment and p_installment_frequency is not null and p_installment_amount is not null and p_total_installments is not null then
    v_due_dates := public.build_installment_dates(p_start_date, p_installment_frequency, p_total_installments);

    foreach v_due_date in array v_due_dates loop
      insert into public.bills (
        owner_id, name, amount, category_id, due_date, is_recurring, type,
        wallet_id, reminder, reminder_days, payment_status, status, obligation_id
      ) values (
        auth.uid(), p_name || ' — Installment', p_installment_amount, p_category_id, v_due_date, false,
        (case when p_direction = 'debt' then 'bill' else 'income' end)::bill_type,
        p_wallet_id, true, 3, 'unpaid', 'active', v_obligation.id
      )
      returning * into v_bill;

      if p_wallet_id is not null then
        insert into public.transactions (
          owner_id, wallet_id, category_id, amount, type, description, date,
          attachments, tags, bill_id, status
        ) values (
          auth.uid(), p_wallet_id, p_category_id, p_installment_amount,
          (case when p_direction = 'debt' then 'expense' else 'income' end)::transaction_type,
          p_name || ' — Installment', v_due_date, '{}', coalesce(p_tags, '{}'), v_bill.id, 'pending'
        )
        returning * into v_txn;

        update public.bills set transaction_id = v_txn.id where id = v_bill.id;
      end if;
    end loop;
  end if;

  select * into v_obligation from public.obligations where id = v_obligation.id;
  return v_obligation;
end;
$$;

grant execute on function public.obligations_create(
  obligation_direction, text, text, numeric, timestamptz, text, text, numeric, interest_type,
  timestamptz, uuid, uuid, text, text[], boolean, numeric, integer, installment_frequency
) to authenticated;
