-- Budget plans: group budgets into a plan such as 50/30/20 (Needs, Wants, Savings).
--
-- A plan has an optional monthly income it splits. Each group in a plan has a target, either a
-- percent of that income or a fixed amount, and is a spending group (its budgets' spending counts
-- against it) or a savings group (money moved into savings wallets counts towards it). A budget
-- belongs to at most one group (budgets.group_id); budgets without a group are "everyday" budgets.
-- Totals are worked out in the app from the budgets list, so these are plain tables (no RPC) and
-- work offline. The Fico MCP server only reads them.

create table if not exists public.budget_plans (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  -- Monthly income the plan splits. Null: use the income Fico sees for the month.
  income numeric(14, 2) check (income is null or income >= 0),
  color text,
  status text not null default 'active' check (status in ('active', 'archived')),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists budget_plans_owner_status_idx on public.budget_plans (owner_id, status);

create table if not exists public.budget_plan_groups (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  plan_id uuid not null references public.budget_plans(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  kind text not null default 'spend' check (kind in ('spend', 'save')),
  -- Target: a percent of the plan's income, or a fixed amount when percent is null.
  percent numeric(5, 2) check (percent is null or (percent >= 0 and percent <= 100)),
  amount numeric(14, 2) check (amount is null or amount >= 0),
  color text,
  icon text,
  -- Savings groups: the wallets that count. Empty means every savings wallet (same rule as goals).
  wallet_ids uuid[] not null default '{}',
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists budget_plan_groups_plan_idx on public.budget_plan_groups (plan_id, sort_order);

alter table public.budgets
  add column if not exists group_id uuid references public.budget_plan_groups(id) on delete set null;

create index if not exists budgets_group_idx on public.budgets (group_id) where group_id is not null;

do $$
declare
  t text;
begin
  foreach t in array array['budget_plans', 'budget_plan_groups'] loop
    execute format('drop trigger if exists set_%1$s_updated_at on public.%1$I', t);
    execute format('create trigger set_%1$s_updated_at before update on public.%1$I for each row execute function public.set_updated_at()', t);
    -- Offline sync: inserts made on a device keep the id the device chose (see 0047).
    execute format('drop trigger if exists a_sync_use_client_id on public.%I', t);
    execute format('create trigger a_sync_use_client_id before insert on public.%I for each row execute function public.sync_use_client_id()', t);
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %1$s_all_own on public.%1$I', t);
    execute format('create policy %1$s_all_own on public.%1$I for all using (owner_id = auth.uid() and public.profile_is_active()) with check (owner_id = auth.uid() and public.profile_is_active())', t);
  end loop;
end;
$$;

-- When a budget's period ends, budgets_advance_periods (and rollover) copy it into a new row and
-- then link the old row to it through next_budget_id. The copy stays in the same group.
create or replace function public.budgets_carry_group()
returns trigger
language plpgsql
as $$
begin
  if new.next_budget_id is not null and old.next_budget_id is null and new.group_id is not null then
    update public.budgets set group_id = new.group_id
    where id = new.next_budget_id and group_id is null;
  end if;
  return new;
end;
$$;

drop trigger if exists budgets_carry_group on public.budgets;
create trigger budgets_carry_group
  after update of next_budget_id on public.budgets
  for each row execute function public.budgets_carry_group();

-- Fico MCP: let its read-only login read these tables too, limited to the same user as its other
-- tables (see fico-api/mcp/readonly-role.sql). Skipped when the MCP login was never set up.
do $$
declare
  uid uuid;
  t text;
begin
  if not exists (select 1 from pg_roles where rolname = 'fico_readonly') then
    return;
  end if;
  select substring(qual from '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')::uuid into uid
  from pg_policies
  where schemaname = 'public' and tablename = 'wallets' and policyname = 'fico_mcp_read';
  foreach t in array array['budget_plans', 'budget_plan_groups'] loop
    execute format('grant select on public.%I to fico_readonly', t);
    if uid is not null then
      execute format('drop policy if exists fico_mcp_read on public.%I', t);
      execute format('create policy fico_mcp_read on public.%I for select to fico_readonly using (owner_id = %L)', t, uid);
    end if;
  end loop;
end;
$$;
