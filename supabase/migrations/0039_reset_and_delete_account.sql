-- Self-service data reset and account deletion. Both act only on the signed-in user (auth.uid()).

-- Wipes the user's money data (wallets, transactions, bills, budgets, debts, investments, own
-- categories) but keeps the account, profile, settings and notification devices.
create or replace function public.reset_my_data()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not signed in';
  end if;

  -- Break the links between these tables so they can be deleted in any order.
  update public.bills set transaction_id = null, parent_bill_id = null, obligation_id = null where owner_id = uid;
  update public.transactions set bill_id = null where owner_id = uid;
  update public.obligations set disbursement_transaction_id = null where owner_id = uid;
  update public.investments set funding_transaction_id = null where owner_id = uid;

  delete from public.finance_agent_cache where owner_id = uid;
  delete from public.transactions where owner_id = uid;
  delete from public.bills where owner_id = uid;
  delete from public.budgets where owner_id = uid;
  delete from public.obligations where owner_id = uid;
  delete from public.investments where owner_id = uid;
  delete from public.wallets where owner_id = uid;
  delete from public.categories where owner_id = uid;
end;
$$;

-- Deletes the money data, the profile and the sign-in account itself.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Not signed in';
  end if;

  perform public.reset_my_data();
  delete from public.push_subscriptions where owner_id = uid;
  delete from public.user_details where owner_id = uid;
  delete from public.profiles where id = uid;
  delete from auth.users where id = uid;
end;
$$;

revoke all on function public.reset_my_data() from public, anon;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.reset_my_data() to authenticated;
grant execute on function public.delete_my_account() to authenticated;
