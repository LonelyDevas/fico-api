-- Bills: archive locks the row while it settles the paid amount.
-- Restored from the offline app's local schema (fico lib/local/schema.generated.ts).

create or replace function public.bills_archive(p_id uuid)
returns void
language plpgsql
as $$
declare
  v_bill public.bills;
  v_paid numeric;
begin
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
  end if;

  if v_bill.transaction_id is not null then
    update public.bills set transaction_id = null where id = p_id;
    delete from public.transactions
    where id = v_bill.transaction_id and owner_id = auth.uid();
  end if;

  update public.bills
  set status = 'archived', payment_status = 'unpaid', paid_amount = 0, last_paid_date = null
  where id = p_id;
end;
$$;

grant execute on function public.bills_archive(uuid) to authenticated;
