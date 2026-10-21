-- Baseline spending: let a user leave one-off money movement (imported history,
-- travel, ATM cash, a big purchase) out of their "normal month" so forecasts
-- aren't skewed by it.
--
-- Two levels:
--   * transactions.exclude_from_baseline marks a single transaction.
--   * profiles.baseline_excluded_category_ids marks whole categories. It lives
--     on the profile, not on categories, because the default categories are
--     shared rows (owner_id null) that every user sees but nobody can edit.

alter table public.transactions
  add column if not exists exclude_from_baseline boolean not null default false;

alter table public.profiles
  add column if not exists baseline_excluded_category_ids uuid[] not null default '{}';

-- transactions_update gains p_exclude_from_baseline. The old signature is
-- dropped first so named-argument calls don't hit two matching overloads.
drop function if exists public.transactions_update(uuid, uuid, text, timestamptz, text[], text[], transaction_status);

create or replace function public.transactions_update(
  p_id uuid,
  p_category_id uuid default null,
  p_description text default null,
  p_date timestamptz default null,
  p_attachments text[] default null,
  p_tags text[] default null,
  p_status transaction_status default null,
  p_exclude_from_baseline boolean default null
)
returns public.transactions
language plpgsql
as $$
declare
  v_txn public.transactions;
begin
  update public.transactions
  set
    category_id = coalesce(p_category_id, category_id),
    description = coalesce(p_description, description),
    date = coalesce(p_date, date),
    attachments = coalesce(p_attachments, attachments),
    tags = coalesce(p_tags, tags),
    status = coalesce(p_status, status),
    exclude_from_baseline = coalesce(p_exclude_from_baseline, exclude_from_baseline)
  where id = p_id and owner_id = auth.uid()
  returning * into v_txn;

  if not found then
    raise exception 'Transaction not found or you do not have permission.' using errcode = 'P0002';
  end if;

  return v_txn;
end;
$$;

grant execute on function public.transactions_update(uuid, uuid, text, timestamptz, text[], text[], transaction_status, boolean) to authenticated;

-- categories_set_exclude_from_baseline: adds or removes a category (the
-- user's own or a default one) from the profile's excluded list.
create or replace function public.categories_set_exclude_from_baseline(
  p_id uuid,
  p_exclude boolean
)
returns uuid[]
language plpgsql
as $$
declare
  v_ids uuid[];
begin
  if not exists (
    select 1 from public.categories
    where id = p_id and (owner_id = auth.uid() or owner_id is null)
  ) then
    raise exception 'Category not found.' using errcode = 'P0002';
  end if;

  update public.profiles
  set baseline_excluded_category_ids = case
    when p_exclude then array(select distinct unnest(array_append(baseline_excluded_category_ids, p_id)))
    else array_remove(baseline_excluded_category_ids, p_id)
  end
  where id = auth.uid()
  returning baseline_excluded_category_ids into v_ids;

  return v_ids;
end;
$$;

grant execute on function public.categories_set_exclude_from_baseline(uuid, boolean) to authenticated;

-- The Fico MCP server's read-only role (fico-api/mcp/readonly-role.sql) needs
-- to read the user's own profile row for the excluded categories. It is only
-- set up on projects that use the MCP server, and its policies are scoped to
-- one user id, which is read back from its existing wallets policy.
do $$
declare
  v_uid text;
begin
  if not exists (select 1 from pg_roles where rolname = 'fico_readonly') then
    return;
  end if;
  select substring(pg_get_expr(p.polqual, p.polrelid) from '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    into v_uid
  from pg_policy p
  where p.polname = 'fico_mcp_read' and p.polrelid = 'public.wallets'::regclass;
  if v_uid is null or exists (
    select 1 from pg_policy where polname = 'fico_mcp_read' and polrelid = 'public.profiles'::regclass
  ) then
    return;
  end if;
  execute format('create policy fico_mcp_read on public.profiles for select to fico_readonly using (id = %L)', v_uid);
end;
$$;
