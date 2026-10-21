-- Net worth history: one row per user per day with wallet balances and investment values, so net
-- worth can be charted over time. Written only by take_net_worth_snapshots() (pg_cron, daily);
-- users and the MCP server only read it.
--
-- Totals follow the MCP accounts_overview tool: cash on hand is every active wallet except savings
-- and credit cards, a credit card's balance is money owed, and
-- net worth = cash + savings + investments + lent out - credit card owed - debts.
-- Crypto values come from investments.current_value, which the crypto-prices function keeps at
-- quantity x live price (0049); a holding whose price is missing or over 2 hours old is flagged stale.
create table if not exists public.net_worth_snapshots (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  snapshot_date date not null,                       -- Manila date the snapshot is for
  cash_on_hand numeric(14, 2) not null default 0,
  savings numeric(14, 2) not null default 0,
  credit_card_owed numeric(14, 2) not null default 0,
  investments numeric(14, 2) not null default 0,
  debts_owed numeric(14, 2) not null default 0,
  lent_out numeric(14, 2) not null default 0,
  net_worth numeric(14, 2) not null default 0,
  wallets jsonb not null default '[]',               -- [{id, name, type, balance}]
  investment_values jsonb not null default '[]',     -- [{id, name, type, coin_symbol, value, stale}]
  investments_stale boolean not null default false,  -- any crypto value in this row was not fresh
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, snapshot_date)
);

create trigger set_net_worth_snapshots_updated_at
  before update on public.net_worth_snapshots
  for each row execute function public.set_updated_at();

alter table public.net_worth_snapshots enable row level security;

create policy net_worth_snapshots_select_own on public.net_worth_snapshots
  for select using (owner_id = auth.uid() and public.profile_is_active());

-- Records today's (Manila) snapshot for every active user. Running it again the same day
-- replaces that day's row, so it is safe to run as often as you like.
create or replace function public.take_net_worth_snapshots(p_date date default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date date := coalesce(p_date, (now() at time zone 'Asia/Manila')::date);
  v_count integer;
begin
  insert into public.net_worth_snapshots (
    owner_id, snapshot_date, cash_on_hand, savings, credit_card_owed, investments,
    debts_owed, lent_out, net_worth, wallets, investment_values, investments_stale
  )
  select p.id, v_date, w.cash, w.savings, w.card_owed, i.total, o.debts, o.lent_out,
         w.cash + w.savings + i.total + o.lent_out - w.card_owed - o.debts,
         w.list, i.list, i.stale
  from public.profiles p
  cross join lateral (
    select coalesce(sum(balance) filter (where type::text not in ('savings', 'credit_card')), 0) as cash,
           coalesce(sum(balance) filter (where type::text = 'savings'), 0) as savings,
           coalesce(sum(balance) filter (where type::text = 'credit_card'), 0) as card_owed,
           coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'type', type, 'balance', balance)
                              order by type, balance desc), '[]') as list,
           count(*) as n
    from public.wallets
    where owner_id = p.id and status = 'active'
  ) w
  cross join lateral (
    select coalesce(sum(current_value), 0) as total,
           coalesce(jsonb_agg(jsonb_build_object(
             'id', id, 'name', name, 'type', type, 'coin_symbol', coin_symbol, 'value', current_value,
             'stale', stale) order by current_value desc), '[]') as list,
           coalesce(bool_or(stale), false) as stale,
           count(*) as n
    from (
      select *, (coin_id is not null and quantity is not null
                 and (price_updated_at is null or price_updated_at < now() - interval '2 hours')) as stale
      from public.investments
      where owner_id = p.id and status = 'active'
    ) inv
  ) i
  cross join lateral (
    select coalesce(sum(remaining_balance) filter (where direction = 'debt'), 0) as debts,
           coalesce(sum(remaining_balance) filter (where direction = 'lending'), 0) as lent_out
    from public.obligations
    where owner_id = p.id and status in ('active', 'partially_paid', 'defaulted')
  ) o
  where p.status = 'active' and (w.n > 0 or i.n > 0)
  on conflict (owner_id, snapshot_date) do update set
    cash_on_hand = excluded.cash_on_hand,
    savings = excluded.savings,
    credit_card_owed = excluded.credit_card_owed,
    investments = excluded.investments,
    debts_owed = excluded.debts_owed,
    lent_out = excluded.lent_out,
    net_worth = excluded.net_worth,
    wallets = excluded.wallets,
    investment_values = excluded.investment_values,
    investments_stale = excluded.investments_stale;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.take_net_worth_snapshots(date) from public, anon, authenticated;

-- Run it daily at 23:55 Manila time (15:55 UTC), so each row is that day's closing balances. If
-- pg_cron is not available, enable it in the Supabase dashboard (Database > Extensions) and run
-- the cron.schedule line by hand.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('take-net-worth-snapshots', '55 15 * * *', 'select public.take_net_worth_snapshots()');
exception when others then
  raise notice 'pg_cron not enabled; schedule take_net_worth_snapshots() manually: %', sqlerrm;
end;
$$;

-- Fico MCP: let its read-only login read this table too, limited to the same user as its other
-- tables (see fico-api/mcp/readonly-role.sql). Skipped when the MCP login was never set up.
do $$
declare
  uid uuid;
begin
  if not exists (select 1 from pg_roles where rolname = 'fico_readonly') then
    return;
  end if;
  select substring(qual from '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')::uuid into uid
  from pg_policies
  where schemaname = 'public' and tablename = 'wallets' and policyname = 'fico_mcp_read';
  grant select on public.net_worth_snapshots to fico_readonly;
  if uid is not null then
    execute format('create policy fico_mcp_read on public.net_worth_snapshots for select to fico_readonly using (owner_id = %L)', uid);
  end if;
end;
$$;

-- First point of the history: today.
select public.take_net_worth_snapshots();
