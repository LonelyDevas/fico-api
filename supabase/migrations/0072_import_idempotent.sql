-- Importing the same statement twice must not create the rows twice.
--
-- Each imported row carries an import_key the app computes from the row's own content (date,
-- amount, type, description and its occurrence number within the file, so two genuinely identical
-- purchases on one statement still get distinct keys). A partial unique index on
-- (wallet_id, import_key) makes a repeat insert a no-op instead of a duplicate.
--
-- Recovery: the column and index are additive. If this needs undoing, a forward migration can drop
-- the index and column; no data is lost either way. Rows imported before this migration have a
-- null key and are never matched.

alter table public.transactions add column if not exists import_key text;

create unique index if not exists transactions_wallet_import_key_uidx
  on public.transactions (wallet_id, import_key)
  where import_key is not null;

-- transactions_bulk_import: same as 0061 (imports never move balances), plus the import_key and
-- "on conflict do nothing". Returns how many rows were inserted and how many were already there.
create or replace function public.transactions_bulk_import(
  p_wallet_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
as $$
declare
  v_wallet public.wallets;
  v_inserted integer;
  v_total integer;
begin
  select * into v_wallet from public.wallets
  where id = p_wallet_id and owner_id = auth.uid() and status = 'active';
  if not found then
    raise exception 'Wallet not found or inactive.' using errcode = 'P0002';
  end if;

  select count(*) into v_total from jsonb_array_elements(p_rows);

  with rows as (
    select *
    from jsonb_to_recordset(p_rows) as r(
      date timestamptz,
      amount numeric,
      type transaction_type,
      description text,
      tags text[],
      category_id uuid,
      import_key text
    )
  ),
  inserted as (
    insert into public.transactions (
      owner_id, wallet_id, amount, type, description, date, tags, category_id, attachments, status, affects_balance, import_key
    )
    select auth.uid(), p_wallet_id, amount, type, description, date,
           coalesce(tags, '{}'), category_id, '{}', 'completed', false, import_key
    from rows
    on conflict (wallet_id, import_key) where import_key is not null do nothing
    returning 1
  )
  select count(*) into v_inserted from inserted;

  return jsonb_build_object('imported', v_inserted, 'duplicates', v_total - v_inserted);
end;
$$;

grant execute on function public.transactions_bulk_import(uuid, jsonb) to authenticated;
