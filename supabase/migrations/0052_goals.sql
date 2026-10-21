-- Savings goals: a target amount by a deadline, funded by the wallets linked to it.
-- Progress is never stored: saved so far is the live balance of the linked wallets (all savings
-- wallets when none are linked), so it can't drift. The app writes this table directly; the Fico
-- MCP server only reads it (its read-only role gets select per account, see fico-api/mcp).
create table if not exists public.goals (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  name text not null,
  target_amount numeric(14, 2) not null check (target_amount > 0),
  deadline date,
  linked_wallet_ids uuid[] not null default '{}',
  status record_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists goals_owner_status_idx on public.goals (owner_id, status);

drop trigger if exists set_goals_updated_at on public.goals;
create trigger set_goals_updated_at
  before update on public.goals
  for each row execute function public.set_updated_at();

-- Offline sync: inserts replayed from a device keep the id the device chose (see 0047).
drop trigger if exists a_sync_use_client_id on public.goals;
create trigger a_sync_use_client_id
  before insert on public.goals
  for each row execute function public.sync_use_client_id();

alter table public.goals enable row level security;

drop policy if exists goals_all_own on public.goals;
create policy goals_all_own on public.goals
  for all
  using (owner_id = auth.uid() and public.profile_is_active())
  with check (owner_id = auth.uid() and public.profile_is_active());
