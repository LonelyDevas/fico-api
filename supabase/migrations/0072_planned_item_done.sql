-- Planned items can be marked done: the expense is already paid (a plane ticket bought early) or the
-- money already came in. The wallet balance shows it, so the app stops counting it in safe to spend,
-- the forecast and the planned totals instead of taking it out a second time.
alter table public.planned_items drop constraint if exists planned_items_status_check;
alter table public.planned_items
  add constraint planned_items_status_check check (status in ('expected', 'confirmed', 'done'));

notify pgrst, 'reload schema';
