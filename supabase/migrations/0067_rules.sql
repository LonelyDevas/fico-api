-- Categorization rules: "description contains 'jollibee' -> category Food". The app runs them, in
-- position order, wherever a transaction is filled in for the user (quick add, receipt scan, CSV
-- import, pasted bank messages, the swipe inbox). The first enabled rule that matches sets each
-- field; a later rule only fills fields an earlier one left empty. The database only stores them.
create table if not exists public.rules (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  position integer not null default 0,
  match_field text not null default 'description' check (match_field in ('description', 'notes')),
  match_op text not null default 'contains' check (match_op in ('contains', 'equals', 'starts_with', 'ends_with')),
  match_value text not null check (length(trim(match_value)) > 0),
  -- Only for this kind of transaction; null matches expenses and income alike.
  match_type text check (match_type in ('expense', 'income')),
  set_category_id uuid references public.categories(id) on delete set null,
  set_tags text[] not null default '{}',
  set_wallet_id uuid references public.wallets(id) on delete set null,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists rules_owner_position_idx on public.rules (owner_id, position);

drop trigger if exists set_rules_updated_at on public.rules;
create trigger set_rules_updated_at
  before update on public.rules
  for each row execute function public.set_updated_at();

-- Offline sync: inserts made on a device keep the id the device chose (see 0047).
drop trigger if exists a_sync_use_client_id on public.rules;
create trigger a_sync_use_client_id
  before insert on public.rules
  for each row execute function public.sync_use_client_id();

alter table public.rules enable row level security;

drop policy if exists rules_all_own on public.rules;
create policy rules_all_own on public.rules
  for all
  using (owner_id = auth.uid() and public.profile_is_active())
  with check (owner_id = auth.uid() and public.profile_is_active());

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
  grant select on public.rules to fico_readonly;
  if uid is not null then
    drop policy if exists fico_mcp_read on public.rules;
    execute format('create policy fico_mcp_read on public.rules for select to fico_readonly using (owner_id = %L)', uid);
  end if;
end;
$$;
