-- Edit, archive and delete categories.
--
-- The default categories are shared rows (owner_id null) that nobody can change. The first time a
-- user edits, archives or deletes one, categories_make_own() gives them their own copy of every
-- default and moves everything of theirs (transactions, bills, budgets, debts, investments, planned
-- items, the baseline exclusions) onto the copies. From then on profiles.owns_categories is set and
-- the app lists only the user's own rows, so every category behaves the same way.
--
--   * Archive hides a category from every picker but keeps it on old transactions and reports.
--   * Delete removes it. Its transactions etc. move to another category of the same type, or
--     become uncategorized. A budget that only tracked it is archived, since an empty budget would
--     otherwise count all spending.

alter table public.profiles
  add column if not exists owns_categories boolean not null default false;

-- Which default category a user's copy was made from.
alter table public.categories
  add column if not exists copied_from uuid;

-- category_move_refs: points everything of the caller's that uses p_from at p_to (null =
-- uncategorized). Returns how many transactions moved. Budgets left with no category are archived.
create or replace function public.category_move_refs(p_from uuid, p_to uuid)
returns integer
language plpgsql
as $$
declare
  v_uid uuid := auth.uid();
  v_count integer;
begin
  update public.transactions set category_id = p_to where owner_id = v_uid and category_id = p_from;
  get diagnostics v_count = row_count;

  update public.bills set category_id = p_to where owner_id = v_uid and category_id = p_from;
  update public.obligations set category_id = p_to where owner_id = v_uid and category_id = p_from;
  update public.investments set category_id = p_to where owner_id = v_uid and category_id = p_from;
  update public.planned_items set category_id = p_to where owner_id = v_uid and category_id = p_from;

  update public.budgets b
  set category_ids = x.ids,
      category_id = x.ids[1],
      status = case when cardinality(x.ids) = 0 then 'archived'::budget_status else b.status end
  from (
    select id,
      case
        when p_to is null or p_to = any(category_ids) then array_remove(category_ids, p_from)
        else array_replace(category_ids, p_from, p_to)
      end as ids
    from public.budgets
    where owner_id = v_uid and (p_from = any(category_ids) or category_id = p_from)
  ) x
  where b.id = x.id;

  update public.profiles
  set baseline_excluded_category_ids = case
    when p_to is null or p_to = any(baseline_excluded_category_ids)
      then array_remove(baseline_excluded_category_ids, p_from)
    else array_replace(baseline_excluded_category_ids, p_from, p_to)
  end
  where id = v_uid and p_from = any(baseline_excluded_category_ids);

  return v_count;
end;
$$;

-- categories_make_own: copies every default category for the caller (once). Copies are inserted
-- in id order so a device that ran this offline and the server create them with the same ids.
create or replace function public.categories_make_own()
returns boolean
language plpgsql
as $$
declare
  v_uid uuid := auth.uid();
  r record;
  v_new uuid;
begin
  if v_uid is null then
    raise exception 'Not signed in.' using errcode = '28000';
  end if;

  if coalesce((select owns_categories from public.profiles where id = v_uid), false) then
    return false;
  end if;

  for r in select * from public.categories where owner_id is null order by id loop
    insert into public.categories (owner_id, name, type, icon, color, is_default, status, copied_from)
    values (v_uid, r.name, r.type, r.icon, r.color, true, r.status, r.id)
    returning id into v_new;
    perform public.category_move_refs(r.id, v_new);
  end loop;

  update public.profiles set owns_categories = true where id = v_uid;
  return true;
end;
$$;

grant execute on function public.categories_make_own() to authenticated;

-- category_resolve_own: the caller's own row for p_id. A default category is first turned into
-- the caller's copy.
create or replace function public.category_resolve_own(p_id uuid)
returns public.categories
language plpgsql
as $$
declare
  v_uid uuid := auth.uid();
  v_category public.categories;
begin
  select * into v_category from public.categories where id = p_id;
  if not found or (v_category.owner_id is not null and v_category.owner_id <> v_uid) then
    raise exception 'Category not found.' using errcode = 'P0002';
  end if;

  if v_category.owner_id is null then
    perform public.categories_make_own();
    select * into v_category from public.categories where owner_id = v_uid and copied_from = p_id;
    if not found then
      raise exception 'Category not found.' using errcode = 'P0002';
    end if;
  end if;

  return v_category;
end;
$$;

create or replace function public.category_check_name(p_owner uuid, p_type category_type, p_name text, p_except uuid)
returns void
language plpgsql
as $$
begin
  if exists (
    select 1 from public.categories
    where owner_id = p_owner and type = p_type and status = 'active'
      and lower(name) = lower(p_name) and id <> p_except
  ) then
    raise exception 'Category with this name already exists.' using errcode = 'P0001';
  end if;
end;
$$;

-- categories_update: rename or recolor a category. Null keeps the current value.
create or replace function public.categories_update(
  p_id uuid,
  p_name text default null,
  p_icon text default null,
  p_color text default null
)
returns public.categories
language plpgsql
as $$
declare
  v_category public.categories := public.category_resolve_own(p_id);
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if v_name is not null then
    perform public.category_check_name(v_category.owner_id, v_category.type, v_name, v_category.id);
  end if;

  update public.categories
  set name = coalesce(v_name, name),
      icon = coalesce(p_icon, icon),
      color = coalesce(p_color, color)
  where id = v_category.id
  returning * into v_category;

  return v_category;
end;
$$;

grant execute on function public.categories_update(uuid, text, text, text) to authenticated;

create or replace function public.categories_archive(p_id uuid)
returns public.categories
language plpgsql
as $$
declare
  v_category public.categories := public.category_resolve_own(p_id);
begin
  update public.categories set status = 'archived' where id = v_category.id returning * into v_category;
  return v_category;
end;
$$;

grant execute on function public.categories_archive(uuid) to authenticated;

create or replace function public.categories_unarchive(p_id uuid)
returns public.categories
language plpgsql
as $$
declare
  v_category public.categories := public.category_resolve_own(p_id);
begin
  perform public.category_check_name(v_category.owner_id, v_category.type, v_category.name, v_category.id);
  update public.categories set status = 'active' where id = v_category.id returning * into v_category;
  return v_category;
end;
$$;

grant execute on function public.categories_unarchive(uuid) to authenticated;

-- categories_delete: deletes a category for good. p_replacement_id (same type) takes over its
-- transactions, bills, budgets etc.; without one they become uncategorized.
create or replace function public.categories_delete(
  p_id uuid,
  p_replacement_id uuid default null
)
returns jsonb
language plpgsql
as $$
declare
  v_category public.categories := public.category_resolve_own(p_id);
  v_replacement public.categories;
  v_moved integer;
begin
  if p_replacement_id is not null then
    v_replacement := public.category_resolve_own(p_replacement_id);
    if v_replacement.id = v_category.id then
      raise exception 'Pick a different category to move transactions to.' using errcode = 'P0001';
    end if;
    if v_replacement.type <> v_category.type then
      raise exception 'Transactions can only move to a category of the same type.' using errcode = 'P0001';
    end if;
  end if;

  v_moved := public.category_move_refs(v_category.id, v_replacement.id);
  delete from public.categories where id = v_category.id and owner_id = auth.uid();

  return jsonb_build_object('deleted', v_category.id, 'movedTransactions', v_moved, 'replacementId', v_replacement.id);
end;
$$;

grant execute on function public.categories_delete(uuid, uuid) to authenticated;
