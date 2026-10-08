-- Savings wallets with customizable interest (regular savings, high-yield
-- digital bank savings, Pag-IBIG MP2, time deposits, ...). Every rule is a
-- per-wallet column, so presets in the UI are only starting values.
alter type wallet_type add value if not exists 'savings';

alter table public.wallets
  add column if not exists interest_rate numeric(6, 3),            -- annual %, e.g. 6.5
  add column if not exists interest_payout text,                   -- monthly | quarterly | annually | maturity
  add column if not exists interest_tax_rate numeric(5, 2),        -- % withheld from interest (20 for bank deposits, 0 for MP2)
  add column if not exists maturity_date date,                     -- for fixed-term products (MP2, time deposits)
  add column if not exists interest_last_posted_at timestamptz,
  -- Lifetime net interest credited. Money put in = balance - total_interest_earned.
  add column if not exists total_interest_earned numeric(14, 2) not null default 0;

alter table public.wallets
  add constraint wallets_interest_payout_check
  check (interest_payout is null or interest_payout in ('monthly', 'quarterly', 'annually', 'maturity'));

-- Posts due interest for every savings wallet as an income transaction and
-- credits the wallet. Net of tax. Interest is added to the balance, so later
-- periods compound. Safe to run as often as you like: a wallet is only
-- touched once its next payout date has arrived.
create or replace function public.post_savings_interest()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  w record;
  v_months integer;
  v_last timestamptz;
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

    if w.interest_payout = 'maturity' then
      -- Single payout once the term ends; simple interest over the whole term.
      continue when w.maturity_date is null or w.maturity_date > current_date or w.interest_last_posted_at is not null;
      v_years := greatest((w.maturity_date - w.created_at::date)::numeric / 365, 0);
    else
      v_months := case w.interest_payout when 'monthly' then 1 when 'quarterly' then 3 else 12 end;
      v_next := v_last + make_interval(months => v_months);
      continue when v_next > now();
      v_years := v_months::numeric / 12;
    end if;

    v_gross := round(w.balance * (w.interest_rate / 100) * v_years, 2);
    v_net := round(v_gross * (1 - coalesce(w.interest_tax_rate, 0) / 100), 2);
    continue when v_net <= 0;

    insert into public.transactions (owner_id, wallet_id, amount, type, description, date, tags, status)
    values (w.owner_id, w.id, v_net, 'income', 'Interest earned', now(), array['interest'], 'completed');

    update public.wallets
    set balance = balance + v_net,
        total_interest_earned = total_interest_earned + v_net,
        interest_last_posted_at = case when w.interest_payout = 'maturity' then now() else v_next end
    where id = w.id;

    v_posted := v_posted + 1;
  end loop;

  return v_posted;
end;
$$;

-- Run it daily at 01:00 Manila time (17:00 UTC) when pg_cron is enabled. If
-- the extension is not available on this project, enable it in the Supabase
-- dashboard (Database > Extensions) and run the cron.schedule line by hand.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('post-savings-interest', '0 17 * * *', 'select public.post_savings_interest()');
exception when others then
  raise notice 'pg_cron not enabled; schedule post_savings_interest() manually: %', sqlerrm;
end;
$$;
