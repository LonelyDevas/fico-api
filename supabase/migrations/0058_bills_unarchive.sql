-- Bring an archived bill back. Archiving (bills_archive) reverses any payment, resets the bill to
-- unpaid and deletes its pending transaction, so unarchiving makes it active again and, when it has
-- a wallet, recreates that pending transaction the way bills_create does.
create or replace function public.bills_unarchive(p_id uuid)
returns public.bills
language plpgsql
as $$
declare
  v_bill public.bills;
  v_txn public.transactions;
begin
  select * into v_bill from public.bills where id = p_id and owner_id = auth.uid() for update;
  if not found then
    raise exception 'Bill not found or you do not have permission.' using errcode = 'P0002';
  end if;

  if v_bill.status::text <> 'archived' then
    return v_bill;
  end if;

  update public.bills
  set status = 'active', payment_status = 'unpaid', paid_amount = 0, last_paid_date = null
  where id = p_id
  returning * into v_bill;

  if v_bill.wallet_id is not null and v_bill.transaction_id is null then
    insert into public.transactions (
      owner_id, wallet_id, category_id, amount, type, description, date,
      attachments, tags, bill_id, status
    ) values (
      v_bill.owner_id, v_bill.wallet_id, v_bill.category_id, v_bill.amount,
      case when v_bill.type::text = 'income' then 'income'::transaction_type else 'expense'::transaction_type end,
      format('Bill: %s', v_bill.name), v_bill.due_date, '{}', '{}', v_bill.id, 'pending'
    )
    returning * into v_txn;

    update public.bills set transaction_id = v_txn.id where id = p_id
    returning * into v_bill;
  end if;

  return v_bill;
end;
$$;

grant execute on function public.bills_unarchive(uuid) to authenticated;
