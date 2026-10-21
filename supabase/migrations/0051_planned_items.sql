-- Planned items: one-off money you expect but that isn't on the Bills page yet (a 13th month pay,
-- birthday money, a trip). Each has a low and a high estimate so plans can be read as a range.
-- Fico's app writes these; the Claude connector (fico-api/mcp) only reads them.
create table if not exists public.planned_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  type text not null check (type in ('income', 'expense')),
  amount_low numeric(14, 2) not null check (amount_low >= 0),
  amount_high numeric(14, 2) not null,
  date date not null,
  status text not null default 'expected' check (status in ('expected', 'confirmed')),
  category_id uuid references public.categories(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint planned_items_amount_range check (amount_high >= amount_low)
);

create index if not exists planned_items_owner_date_idx on public.planned_items (owner_id, date);

drop trigger if exists set_planned_items_updated_at on public.planned_items;
create trigger set_planned_items_updated_at
  before update on public.planned_items
  for each row execute function public.set_updated_at();

-- Offline sync: inserts made on a device keep the id the device chose (see 0047).
drop trigger if exists a_sync_use_client_id on public.planned_items;
create trigger a_sync_use_client_id
  before insert on public.planned_items
  for each row execute function public.sync_use_client_id();

alter table public.planned_items enable row level security;

drop policy if exists planned_items_all_own on public.planned_items;
create policy planned_items_all_own on public.planned_items
  for all
  using (owner_id = auth.uid() and public.profile_is_active())
  with check (owner_id = auth.uid() and public.profile_is_active());
