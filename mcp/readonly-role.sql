-- Fico MCP: read-only login. Change the two values on the next lines, then Run.
do $$
declare
  fico_username text := 'YOUR_FICO_USERNAME';
  new_password  text := 'MAKE_UP_A_LONG_PASSWORD';
  uid uuid;
  t text;
begin
  select id into uid from public.profiles where username = fico_username;
  if uid is null then raise exception 'No Fico user named %', fico_username; end if;

  execute format('create role fico_readonly login password %L', new_password);
  alter role fico_readonly set default_transaction_read_only = on;
  grant usage on schema public to fico_readonly;
  grant select on public.wallets, public.categories, public.transactions, public.bills,
    public.budgets, public.obligations, public.investments, public.profiles to fico_readonly;
  begin
    grant usage on schema auth to fico_readonly;
    grant execute on function auth.uid() to fico_readonly;
  exception when insufficient_privilege then
    grant anon to fico_readonly;
  end;

  foreach t in array array['wallets','transactions','bills','budgets','obligations','investments'] loop
    execute format('create policy fico_mcp_read on public.%I for select to fico_readonly using (owner_id = %L)', t, uid);
  end loop;
  execute format('create policy fico_mcp_read on public.categories for select to fico_readonly using (owner_id = %L or owner_id is null)', uid);
end $$;

-- This prints your user id. Copy it: it's FICO_OWNER_ID on Render.
select id as fico_owner_id from public.profiles where username = 'YOUR_FICO_USERNAME';
