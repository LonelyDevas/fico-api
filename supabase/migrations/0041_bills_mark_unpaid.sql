-- Bills: mark unpaid refunds the payment once (row lock against double clicks).
-- Restored from the offline app's local schema (fico lib/local/schema.generated.ts).

create or replace function public.bills_mark_unpaid(p_id uuid)
returns void
language plpgsql
as $$
declare
  v_bill public.bills;
  v_paid numeric;
  v_old_txn_id uuid;
  v_new_txn public.transactions;
begin
  -- Lock the row so a double-click can't refund twice.
  select * into v_bill from public.bills where id = p_id and owner_id = auth.uid() for update;
  if not found then
    raise exception 'Bill not found or you do not have permission.' using errcode = 'P0002';
  end if;

  v_paid := coalesce(v_bill.paid_amount, 0);

  if v_bill.payment_status in ('paid', 'partial') and v_paid > 0 then
    if v_bill.wallet_id is not null then
      perform public.wallet_apply(
        v_bill.wallet_id,
        case when v_bill.type::text = 'income' then -v_paid else v_paid end
      );
    end if;
    if v_bill.pays_wallet_id is not null then
      perform public.wallet_apply(v_bill.pays_wallet_id, -v_paid);
    end if;

    v_old_txn_id := v_bill.transaction_id;
    if v_old_txn_id is not null then
      update public.bills set transaction_id = null where id = p_id;
      delete from public.transactions where id = v_old_txn_id and owner_id = auth.uid();
    end if;

    if v_bill.wallet_id is not null then
      insert into public.transactions (
        owner_id, wallet_id, category_id, amount, type, description, date,
        attachments, tags, bill_id, status
      ) values (
        auth.uid(), v_bill.wallet_id, v_bill.category_id, v_bill.amount,
        case when v_bill.type::text = 'income' then 'income'::transaction_type else 'expense'::transaction_type end,
        format('Bill: %s', v_bill.name), v_bill.due_date, '{}', '{}', v_bill.id, 'pending'
      )
      returning * into v_new_txn;

      update public.bills set transaction_id = v_new_txn.id where id = p_id;
    end if;
  end if;

  update public.bills
  set payment_status = 'unpaid', paid_amount = 0, last_paid_date = null
  where id = p_id;
end;
$$;

grant execute on function public.bills_mark_unpaid(uuid) to authenticated;
