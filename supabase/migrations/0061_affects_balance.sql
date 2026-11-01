-- Transactions that don't change the wallet balance.
--
-- transactions.affects_balance (default true) says whether a transaction moves its wallet's
-- stored balance. Turning it off lets you add or fix history (for example imported Q1 rows)
-- without touching what the wallet says it holds today. These rows still count everywhere else:
-- spending, categories, monthly summaries, budgets and baseline all read transactions, not
-- balances. Only the stored balance (and so net worth snapshots taken from it) leaves them out.
--
-- The rule every RPC below follows: a wallet's balance holds the effect of each completed,
-- balance-affecting transaction exactly once. An edit works out the effect before and after the
-- change and applies only the difference, all in one database transaction, so running the same
-- edit twice (a sync retry, say) changes nothing the second time.
--   * create: applies the effect only when affects_balance is true.
--   * edit with the flag off before and after: no wallet changes, whatever else changed.
--   * edit with the flag on before and after: the old effect is swapped for the new one
--     (amount, type, wallet or status changes; a date change alone moves nothing).
--   * switching the flag: the full amount is taken out (on -> off) or put in (off -> on), once.
--   * delete: reverses the effect only when affects_balance is true.

alter table public.transactions
  add column if not exists affects_balance boolean not null default true;

-- The wallet changes a transaction makes, as "money in is positive" (wallet_apply flips the sign
-- for credit cards). Empty when the transaction isn't completed or doesn't affect the balance.
create or replace function public.transaction_balance_effects(p_txn public.transactions)
returns table (wallet_id uuid, delta numeric)
language sql
immutable
as $$
  select e.wallet_id, e.delta
  from (values
    (p_txn.wallet_id,
      case p_txn.type::text
        when 'income' then p_txn.amount
        when 'expense' then -p_txn.amount
        when 'transfer' then case
          when p_txn.to_wallet_id is null then 0
          else -(p_txn.amount + case when p_txn.service_fee_deducted then p_txn.service_fee else 0 end)
        end
        else 0
      end),
    (p_txn.to_wallet_id, case when p_txn.type::text = 'transfer' then p_txn.amount else 0 end)
  ) as e(wallet_id, delta)
  where p_txn.status::text = 'completed'
    and p_txn.affects_balance
    and e.wallet_id is not null
    and e.delta <> 0;
$$;

-- Moves wallets from one state of a transaction to another, applying only the net difference per
-- wallet. Pass null as p_old for a new transaction, or null as p_new for a deleted one.
create or replace function public.transaction_rebalance(p_old public.transactions, p_new public.transactions)
returns void
language plpgsql
as $$
declare
  r record;
begin
  for r in
    select e.wallet_id, sum(e.delta) as delta
    from (
      select o.wallet_id, -o.delta as delta from public.transaction_balance_effects(p_old) o where p_old.id is not null
      union all
      select n.wallet_id, n.delta from public.transaction_balance_effects(p_new) n where p_new.id is not null
    ) e
    group by e.wallet_id
    having sum(e.delta) <> 0
    order by e.wallet_id
  loop
    perform public.wallet_apply(r.wallet_id, r.delta);
  end loop;
end;
$$;

-- transactions_create: same as 0030, plus p_affects_balance. With it off the row is saved as
-- history: no balance check and no wallet change. The old signature is dropped first so
-- named-argument calls don't hit two matching overloads.
drop function if exists public.transactions_create(
  uuid, numeric, transaction_type, uuid, text, timestamptz, text[], text[], uuid, uuid, numeric, boolean
);

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
  p_create_bill_for_fee boolean default false,
  p_affects_balance boolean default true
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
  v_affects boolean := coalesce(p_affects_balance, true);
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

  if v_affects and p_type in ('expense', 'transfer') and not public.wallet_can_afford(v_wallet, v_total_deduction) then
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
    attachments, tags, to_wallet_id, bill_id, service_fee, service_fee_deducted, status, affects_balance
  ) values (
    auth.uid(), p_wallet_id, p_category_id, p_amount, p_type, p_description, p_date,
    p_attachments, p_tags, p_to_wallet_id, p_bill_id, p_service_fee, v_fee_deducted, 'completed', v_affects
  )
  returning * into v_txn;

  perform public.transaction_rebalance(null, v_txn);

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
  uuid, numeric, transaction_type, uuid, text, timestamptz, text[], text[], uuid, uuid, numeric, boolean, boolean
) to authenticated;

-- transactions_update: same fields as 0054, plus amount, type, wallet, destination wallet and the
-- flag. Wallets move by the difference between the old and new effect (see the rules at the top).
drop function if exists public.transactions_update(uuid, uuid, text, timestamptz, text[], text[], transaction_status, boolean);

create or replace function public.transactions_update(
  p_id uuid,
  p_category_id uuid default null,
  p_description text default null,
  p_date timestamptz default null,
  p_attachments text[] default null,
  p_tags text[] default null,
  p_status transaction_status default null,
  p_exclude_from_baseline boolean default null,
  p_amount numeric default null,
  p_type transaction_type default null,
  p_wallet_id uuid default null,
  p_to_wallet_id uuid default null,
  p_affects_balance boolean default null
)
returns public.transactions
language plpgsql
as $$
declare
  v_old public.transactions;
  v_new public.transactions;
begin
  select * into v_old from public.transactions
  where id = p_id and owner_id = auth.uid() for update;
  if not found then
    raise exception 'Transaction not found or you do not have permission.' using errcode = 'P0002';
  end if;

  v_new := v_old;
  v_new.category_id := coalesce(p_category_id, v_old.category_id);
  v_new.description := coalesce(p_description, v_old.description);
  v_new.date := coalesce(p_date, v_old.date);
  v_new.attachments := coalesce(p_attachments, v_old.attachments);
  v_new.tags := coalesce(p_tags, v_old.tags);
  v_new.status := coalesce(p_status, v_old.status);
  v_new.exclude_from_baseline := coalesce(p_exclude_from_baseline, v_old.exclude_from_baseline);
  v_new.amount := coalesce(p_amount, v_old.amount);
  v_new.type := coalesce(p_type, v_old.type);
  v_new.wallet_id := coalesce(p_wallet_id, v_old.wallet_id);
  v_new.affects_balance := coalesce(p_affects_balance, v_old.affects_balance);

  if v_new.amount <= 0 then
    raise exception 'Amount must be more than zero.' using errcode = 'P0001';
  end if;

  if v_new.type = 'transfer' then
    v_new.to_wallet_id := coalesce(p_to_wallet_id, v_old.to_wallet_id);
    if v_new.to_wallet_id is null then
      raise exception 'Destination wallet required for transfers.' using errcode = 'P0001';
    end if;
    if v_new.to_wallet_id = v_new.wallet_id then
      raise exception 'Cannot transfer to the same wallet.' using errcode = 'P0001';
    end if;
  else
    -- Only transfers have a destination or a deducted transfer fee.
    v_new.to_wallet_id := null;
    v_new.service_fee_deducted := false;
  end if;

  if v_new.wallet_id is distinct from v_old.wallet_id and not exists (
    select 1 from public.wallets where id = v_new.wallet_id and owner_id = auth.uid() and status = 'active'
  ) then
    raise exception 'Wallet not found or inactive.' using errcode = 'P0002';
  end if;
  if v_new.to_wallet_id is distinct from v_old.to_wallet_id and v_new.to_wallet_id is not null and not exists (
    select 1 from public.wallets where id = v_new.to_wallet_id and owner_id = auth.uid() and status = 'active'
  ) then
    raise exception 'Destination wallet not found or inactive.' using errcode = 'P0002';
  end if;

  update public.transactions
  set
    category_id = v_new.category_id,
    description = v_new.description,
    date = v_new.date,
    attachments = v_new.attachments,
    tags = v_new.tags,
    status = v_new.status,
    exclude_from_baseline = v_new.exclude_from_baseline,
    amount = v_new.amount,
    type = v_new.type,
    wallet_id = v_new.wallet_id,
    to_wallet_id = v_new.to_wallet_id,
    service_fee_deducted = v_new.service_fee_deducted,
    affects_balance = v_new.affects_balance
  where id = p_id
  returning * into v_new;

  perform public.transaction_rebalance(v_old, v_new);

  return v_new;
end;
$$;

grant execute on function public.transactions_update(
  uuid, uuid, text, timestamptz, text[], text[], transaction_status, boolean,
  numeric, transaction_type, uuid, uuid, boolean
) to authenticated;

-- transactions_delete: same as 0043, reversing the wallet change only when the flag is on.
create or replace function public.transactions_delete(p_id uuid)
returns void
language plpgsql
as $$
declare
  v_txn public.transactions;
begin
  select * into v_txn from public.transactions
  where id = p_id and owner_id = auth.uid() for update;

  if not found then
    raise exception 'Transaction not found or you do not have permission.' using errcode = 'P0002';
  end if;

  if v_txn.status <> 'completed' then
    raise exception 'Can only delete completed transactions.' using errcode = 'P0001';
  end if;

  perform public.transaction_rebalance(v_txn, null);

  update public.bills
  set transaction_id = null, payment_status = 'unpaid', paid_amount = 0, last_paid_date = null
  where transaction_id = p_id and owner_id = auth.uid();

  update public.obligations set disbursement_transaction_id = null
  where disbursement_transaction_id = p_id and owner_id = auth.uid();

  update public.investments set funding_transaction_id = null
  where funding_transaction_id = p_id and owner_id = auth.uid();

  delete from public.transactions where id = p_id;
end;
$$;

grant execute on function public.transactions_delete(uuid) to authenticated;

-- transactions_set_affects_balance: sets the flag on every transaction dated in [p_start, p_end]
-- (optionally only one wallet's, as source or destination). By default no balance changes: the
-- rows are marked as history and every wallet keeps what it holds now. That is what imported or
-- backfilled rows need, since their effect is already in (or was never added to) the balance.
-- With p_adjust_balances the full effect of each switched row is taken out or put in, the same
-- as switching them one at a time. Rows already set that way are left alone, so it can be re-run.
create or replace function public.transactions_set_affects_balance(
  p_start timestamptz,
  p_end timestamptz,
  p_affects_balance boolean default false,
  p_wallet_id uuid default null,
  p_adjust_balances boolean default false
)
returns jsonb
language plpgsql
as $$
declare
  v_count integer := 0;
  v_old public.transactions;
  v_new public.transactions;
begin
  if p_start is null or p_end is null or p_end < p_start then
    raise exception 'Pick a start and end date.' using errcode = 'P0001';
  end if;

  for v_old in
    select t.* from public.transactions t
    where t.owner_id = auth.uid()
      and t.date >= p_start and t.date <= p_end
      and t.affects_balance is distinct from p_affects_balance
      and (p_wallet_id is null or t.wallet_id = p_wallet_id or t.to_wallet_id = p_wallet_id)
    order by t.date, t.id
    for update
  loop
    update public.transactions set affects_balance = p_affects_balance
    where id = v_old.id
    returning * into v_new;
    if p_adjust_balances then
      perform public.transaction_rebalance(v_old, v_new);
    end if;
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('updated', v_count, 'balancesAdjusted', p_adjust_balances and v_count > 0);
end;
$$;

grant execute on function public.transactions_set_affects_balance(timestamptz, timestamptz, boolean, uuid, boolean) to authenticated;

-- transactions_bulk_import: same as 0023. Imports never move balances, so their rows now say so,
-- and deleting one later won't take an amount out that was never put in.
create or replace function public.transactions_bulk_import(
  p_wallet_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
as $$
declare
  v_wallet public.wallets;
  v_inserted integer;
begin
  select * into v_wallet from public.wallets
  where id = p_wallet_id and owner_id = auth.uid() and status = 'active';
  if not found then
    raise exception 'Wallet not found or inactive.' using errcode = 'P0002';
  end if;

  with rows as (
    select *
    from jsonb_to_recordset(p_rows) as r(
      date timestamptz,
      amount numeric,
      type transaction_type,
      description text,
      tags text[],
      category_id uuid
    )
  ),
  inserted as (
    insert into public.transactions (
      owner_id, wallet_id, amount, type, description, date, tags, category_id, attachments, status, affects_balance
    )
    select auth.uid(), p_wallet_id, amount, type, description, date,
           coalesce(tags, '{}'), category_id, '{}', 'completed', false
    from rows
    returning 1
  )
  select count(*) into v_inserted from inserted;

  return jsonb_build_object('imported', v_inserted);
end;
$$;

grant execute on function public.transactions_bulk_import(uuid, jsonb) to authenticated;

-- Same as 0057, leaving out transactions that never moved the balance.
create or replace function public.wallet_balance_at(p_wallet public.wallets, p_at timestamptz)
returns numeric
language sql
stable
set search_path = public
as $$
  select p_wallet.balance - coalesce(sum(
    case
      when t.to_wallet_id = p_wallet.id and t.type = 'transfer' then t.amount
      when t.wallet_id = p_wallet.id and t.type = 'income' then t.amount
      when t.wallet_id = p_wallet.id and t.type = 'transfer'
        then -(t.amount + case when t.service_fee_deducted then t.service_fee else 0 end)
      when t.wallet_id = p_wallet.id and t.type = 'expense' then -t.amount
      else 0
    end
  ), 0)
  from public.transactions t
  where (t.wallet_id = p_wallet.id or t.to_wallet_id = p_wallet.id)
    and t.status = 'completed'
    and t.affects_balance
    and t.date > p_at;
$$;

revoke all on function public.wallet_balance_at(public.wallets, timestamptz) from public, anon, authenticated;

-- wallets_reconcile: for each of the user's wallets, the stored balance next to the sum of its
-- balance-affecting transactions. The gap is normally the wallet's starting balance plus any
-- manual balance edits; if it changes when you didn't edit the balance, something drifted.
-- Credit cards are shown the way they are stored, as the amount owed.
create or replace function public.wallets_reconcile()
returns jsonb
language sql
stable
as $$
  with effects as (
    select e.wallet_id, sum(e.delta) as delta, count(distinct t.id) as txns
    from public.transactions t
    cross join lateral public.transaction_balance_effects(t) e
    where t.owner_id = auth.uid()
    group by e.wallet_id
  ),
  untracked as (
    select w.id as wallet_id, count(*) as txns
    from public.wallets w
    join public.transactions t on t.owner_id = auth.uid() and (t.wallet_id = w.id or t.to_wallet_id = w.id)
    where w.owner_id = auth.uid() and not t.affects_balance
    group by w.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'walletId', w.id,
    'name', w.name,
    'type', w.type,
    'currency', w.currency,
    'status', w.status,
    'storedBalance', w.balance,
    'transactionBalance', round(coalesce(case when w.type::text = 'credit_card' then -e.delta else e.delta end, 0), 2),
    'difference', round(w.balance - coalesce(case when w.type::text = 'credit_card' then -e.delta else e.delta end, 0), 2),
    'balanceTransactions', coalesce(e.txns, 0),
    'nonBalanceTransactions', coalesce(u.txns, 0)
  ) order by w.status, w.name), '[]'::jsonb)
  from public.wallets w
  left join effects e on e.wallet_id = w.id
  left join untracked u on u.wallet_id = w.id
  where w.owner_id = auth.uid();
$$;

grant execute on function public.wallets_reconcile() to authenticated;
