-- Fico MCP: let an existing fico_readonly login read planned items (migration 0051).
-- Only needed if you created the role before planned items existed. Put in your Fico username, then Run.
do $$
declare
  fico_username text := 'YOUR_FICO_USERNAME';
  uid uuid;
begin
  select id into uid from public.profiles where username = fico_username;
  if uid is null then raise exception 'No Fico user named %', fico_username; end if;

  grant select on public.planned_items to fico_readonly;
  drop policy if exists fico_mcp_read on public.planned_items;
  execute format('create policy fico_mcp_read on public.planned_items for select to fico_readonly using (owner_id = %L)', uid);
end $$;
