-- Milestones the user has reached (a goal at 50%, a debt cleared, a first investment), so the app
-- celebrates each one once, even after a dip below the line and a recovery, and can draw a journey
-- ("Started Aug 3, halfway Oct 2"). The app works them out (fico utils/milestones.ts); this table
-- only remembers them.
create table if not exists public.milestones (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('goal', 'debt', 'lending', 'invest')),
  -- The goal, obligation or investment id, or 'portfolio' for totals across investments.
  subject_id text not null,
  level text not null,
  title text,
  reached_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, kind, subject_id, level)
);

create index if not exists milestones_owner_subject_idx on public.milestones (owner_id, kind, subject_id);

drop trigger if exists set_milestones_updated_at on public.milestones;
create trigger set_milestones_updated_at
  before update on public.milestones
  for each row execute function public.set_updated_at();

-- Offline sync: inserts made on a device keep the id the device chose (see 0047).
drop trigger if exists a_sync_use_client_id on public.milestones;
create trigger a_sync_use_client_id
  before insert on public.milestones
  for each row execute function public.sync_use_client_id();

alter table public.milestones enable row level security;

drop policy if exists milestones_all_own on public.milestones;
create policy milestones_all_own on public.milestones
  for all
  using (owner_id = auth.uid() and public.profile_is_active())
  with check (owner_id = auth.uid() and public.profile_is_active());

-- Fico MCP: let its read-only login read this table too (see 0064).
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
  grant select on public.milestones to fico_readonly;
  if uid is not null then
    drop policy if exists fico_mcp_read on public.milestones;
    execute format('create policy fico_mcp_read on public.milestones for select to fico_readonly using (owner_id = %L)', uid);
  end if;
end;
$$;
