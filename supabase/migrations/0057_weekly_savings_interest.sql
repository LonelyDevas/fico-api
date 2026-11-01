-- Weekly interest payout for savings wallets (e.g. digital banks that accrue daily). Interest is
-- worked out for each Manila calendar day on that day's closing balance, then credited as one entry
-- per week.

alter table public.wallets drop constraint if exists wallets_interest_payout_check;
alter table public.wallets
  add constraint wallets_interest_payout_check
  check (interest_payout is null or interest_payout in ('weekly', 'monthly', 'quarterly', 'annually', 'maturity'));

-- A wallet's balance at a moment in the past: today's balance with every later transaction undone.
-- Only completed transactions move balances. Manual balance edits (wallets_set_balance) leave no
-- transaction, so they count as if they had always been there.
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
    and t.date > p_at;
$$;

revoke all on function public.wallet_balance_at(public.wallets, timestamptz) from public, anon, authenticated;

-- Same as 0028, plus 'weekly': seven days, each earning rate/365 on its closing balance.
create or replace function public.post_savings_interest()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  w public.wallets;
  v_months integer;
  v_last timestamptz;
  v_day date;
  v_next timestamptz;
  v_years numeric;
  v_gross numeric;
  v_net numeric;
  v_posted integer := 0;
begin
  for w in
    select * from public.wallets
    where type::text = 'savings' and status = 'active'
      and coalesce(interest_rate, 0) > 0 and balance > 0
      and interest_payout is not null
  loop
    v_last := coalesce(w.interest_last_posted_at, w.created_at);

    if w.interest_payout = 'weekly' then
      -- Seven Manila calendar days starting with the one v_last falls on. A day closes at the next
      -- Manila midnight, so a deposit made any time that day earns for it. Posted once the week closes.
      v_day := (v_last at time zone 'Asia/Manila')::date;
      v_next := (v_day + 7)::timestamp at time zone 'Asia/Manila';
      continue when v_next > now();
      select round(sum(greatest(public.wallet_balance_at(w, (v_day + k)::timestamp at time zone 'Asia/Manila'), 0))
                   * (w.interest_rate / 100) / 365, 2)
        into v_gross
      from generate_series(1, 7) as k;
    elsif w.interest_payout = 'maturity' then
      -- Single payout once the term ends; simple interest over the whole term.
      continue when w.maturity_date is null or w.maturity_date > current_date or w.interest_last_posted_at is not null;
      v_years := greatest((w.maturity_date - w.created_at::date)::numeric / 365, 0);
      v_gross := round(w.balance * (w.interest_rate / 100) * v_years, 2);
    else
      v_months := case w.interest_payout when 'monthly' then 1 when 'quarterly' then 3 else 12 end;
      v_next := v_last + make_interval(months => v_months);
      continue when v_next > now();
      v_years := v_months::numeric / 12;
      v_gross := round(w.balance * (w.interest_rate / 100) * v_years, 2);
    end if;

    v_net := round(coalesce(v_gross, 0) * (1 - coalesce(w.interest_tax_rate, 0) / 100), 2);

    if v_net > 0 then
      insert into public.transactions (owner_id, wallet_id, amount, type, description, date, tags, status)
      values (w.owner_id, w.id, v_net, 'income', 'Interest earned', now(), array['interest'], 'completed');
    end if;

    -- A week that earned nothing (say, an empty wallet) still moves the clock on.
    update public.wallets
    set balance = balance + greatest(v_net, 0),
        total_interest_earned = total_interest_earned + greatest(v_net, 0),
        interest_last_posted_at = case when w.interest_payout = 'maturity' then now() else v_next end
    where id = w.id;

    if v_net > 0 then
      v_posted := v_posted + 1;
    end if;
  end loop;

  return v_posted;
end;
$$;
