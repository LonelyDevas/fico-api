-- Transactions: delete restores the wallet balance under a row lock.
-- Restored from the offline app's local schema (fico lib/local/schema.generated.ts).

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
