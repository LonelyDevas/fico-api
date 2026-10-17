-- Offline sync: sync_replay() applies a change queued on a device exactly once (sync_applied_ops)
-- and lets inserts keep the ids the device chose (sync_use_client_id).
-- Restored from the offline app's local schema (fico lib/local/schema.generated.ts).

create table if not exists public.sync_applied_ops (
  op_id uuid primary key,
  owner_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  applied_at timestamptz not null default now()
);

alter table public.sync_applied_ops enable row level security;

drop policy if exists sync_applied_ops_select_own on public.sync_applied_ops;

create policy sync_applied_ops_select_own on public.sync_applied_ops
  for select using (owner_id = auth.uid());

drop policy if exists sync_applied_ops_insert_own on public.sync_applied_ops;

create policy sync_applied_ops_insert_own on public.sync_applied_ops
  for insert with check (owner_id = auth.uid());

create or replace function public.sync_use_client_id()
returns trigger
language plpgsql
as $$
declare
  v_ids jsonb := nullif(current_setting('app.client_ids', true), '')::jsonb;
  v_pos integer := coalesce(nullif(current_setting('app.client_ids_pos', true), '')::integer, 0);
begin
  if v_ids is not null and v_pos < jsonb_array_length(v_ids) then
    new.id := (v_ids ->> v_pos)::uuid;
    perform set_config('app.client_ids_pos', (v_pos + 1)::text, true);
  end if;
  return new;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array[
    'wallets', 'categories', 'transactions', 'bills', 'budgets',
    'obligations', 'investments', 'investment_value_snapshots'
  ] loop
    execute format('drop trigger if exists a_sync_use_client_id on public.%I', t);
    execute format(
      'create trigger a_sync_use_client_id before insert on public.%I for each row execute function public.sync_use_client_id()',
      t
    );
  end loop;
end;
$$;

create or replace function public.sync_replay(
  p_op_id uuid,
  p_name text,
  p_args jsonb default '{}'::jsonb,
  p_ids jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
as $$
declare
  v_proc pg_proc;
  v_parts text[] := '{}';
  v_key text;
  v_val jsonb;
  v_idx integer;
  v_type text;
  v_expr text;
begin
  if p_name !~ '^(wallets|categories|transactions|bills|budgets|obligations|investments|cards)_[a-z_]+$' then
    raise exception 'Operation % can not be replayed.', p_name using errcode = '22023';
  end if;

  insert into public.sync_applied_ops (op_id) values (p_op_id) on conflict do nothing;
  if not found then
    return jsonb_build_object('duplicate', true);
  end if;

  -- The overload whose parameter names cover every supplied argument.
  select p.* into v_proc
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.proname = p_name
    and not exists (
      select 1 from jsonb_object_keys(coalesce(p_args, '{}'::jsonb)) k
      where k <> all (coalesce(p.proargnames, '{}'::text[]))
    )
  order by p.pronargs desc
  limit 1;

  if not found then
    raise exception 'No function % matches the queued arguments.', p_name using errcode = '42883';
  end if;

  perform set_config('app.client_ids', coalesce(p_ids, '[]'::jsonb)::text, true);
  perform set_config('app.client_ids_pos', '0', true);

  for v_key, v_val in select * from jsonb_each(coalesce(p_args, '{}'::jsonb)) loop
    v_idx := array_position(v_proc.proargnames, v_key);
    v_type := format_type((string_to_array(v_proc.proargtypes::text, ' '))[v_idx]::oid, null);
    if jsonb_typeof(v_val) = 'null' then
      v_expr := format('null::%s', v_type);
    elsif v_type = 'jsonb' then
      v_expr := format('($1 -> %L)', v_key);
    elsif v_type like '%[]' then
      v_expr := format('array(select jsonb_array_elements_text($1 -> %L))::%s', v_key, v_type);
    else
      v_expr := format('($1 ->> %L)::%s', v_key, v_type);
    end if;
    v_parts := v_parts || format('%I => %s', v_key, v_expr);
  end loop;

  execute format('select public.%I(%s)', p_name, array_to_string(v_parts, ', ')) using coalesce(p_args, '{}'::jsonb);

  return jsonb_build_object('applied', true);
end;
$$;

grant execute on function public.sync_replay(uuid, text, jsonb, jsonb) to authenticated;
