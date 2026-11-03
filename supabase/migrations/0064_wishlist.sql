-- Wishlist: things the user wants to buy, with a price, how much they want it and an optional
-- "want it by" date. Marking an item bought keeps it (status 'bought', bought_on) so it stays in
-- the history. The app writes this table directly; the Fico MCP server only reads it.
create table if not exists public.wishlist_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  price numeric(14, 2) not null check (price > 0),
  priority text not null default 'want' check (priority in ('need', 'want', 'someday')),
  target_date date,
  url text,
  notes text,
  status text not null default 'wanted' check (status in ('wanted', 'bought')),
  bought_on date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists wishlist_items_owner_status_idx on public.wishlist_items (owner_id, status);

drop trigger if exists set_wishlist_items_updated_at on public.wishlist_items;
create trigger set_wishlist_items_updated_at
  before update on public.wishlist_items
  for each row execute function public.set_updated_at();

-- Offline sync: inserts made on a device keep the id the device chose (see 0047).
drop trigger if exists a_sync_use_client_id on public.wishlist_items;
create trigger a_sync_use_client_id
  before insert on public.wishlist_items
  for each row execute function public.sync_use_client_id();

alter table public.wishlist_items enable row level security;

drop policy if exists wishlist_items_all_own on public.wishlist_items;
create policy wishlist_items_all_own on public.wishlist_items
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
  grant select on public.wishlist_items to fico_readonly;
  if uid is not null then
    drop policy if exists fico_mcp_read on public.wishlist_items;
    execute format('create policy fico_mcp_read on public.wishlist_items for select to fico_readonly using (owner_id = %L)', uid);
  end if;
end;
$$;
