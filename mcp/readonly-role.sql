-- Read-only role for fico-mcp. Run once in the Supabase SQL editor.
-- 1. Replace YOUR_USER_ID with your id (Authentication > Users > your row > User UID).
-- 2. Replace CHOOSE_A_STRONG_PASSWORD.
-- The role can only SELECT, and row level security limits it to your rows,
-- so it can never see other Fico users' data or change anything.

create role fico_readonly login password 'CHOOSE_A_STRONG_PASSWORD';
alter role fico_readonly set default_transaction_read_only = on;
grant usage on schema public to fico_readonly;

grant select on public.wallets, public.categories, public.transactions, public.bills,
  public.budgets, public.obligations, public.investments to fico_readonly;

-- Fico's own policies call auth.uid() and read profiles, and Postgres checks
-- every policy on a table, so the role needs these too. For this role
-- auth.uid() is empty, so Fico's own policies match nothing and only the
-- fico_mcp_read policies below apply. If the first line errors with
-- "permission denied", replace these three lines with: grant anon to fico_readonly;
grant usage on schema auth to fico_readonly;
grant execute on function auth.uid() to fico_readonly;
grant select on public.profiles to fico_readonly;

create policy fico_mcp_read on public.wallets     for select to fico_readonly using (owner_id = 'YOUR_USER_ID');
create policy fico_mcp_read on public.transactions for select to fico_readonly using (owner_id = 'YOUR_USER_ID');
create policy fico_mcp_read on public.bills       for select to fico_readonly using (owner_id = 'YOUR_USER_ID');
create policy fico_mcp_read on public.budgets     for select to fico_readonly using (owner_id = 'YOUR_USER_ID');
create policy fico_mcp_read on public.obligations for select to fico_readonly using (owner_id = 'YOUR_USER_ID');
create policy fico_mcp_read on public.investments for select to fico_readonly using (owner_id = 'YOUR_USER_ID');
-- Categories with no owner are Fico's built-in defaults.
create policy fico_mcp_read on public.categories  for select to fico_readonly
  using (owner_id = 'YOUR_USER_ID' or owner_id is null);

-- To remove everything later:
--   drop policy fico_mcp_read on public.wallets; (repeat for each table above)
--   drop owned by fico_readonly; drop role fico_readonly;
