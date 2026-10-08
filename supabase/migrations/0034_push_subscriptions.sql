-- Devices that have turned on bill reminders. One row per browser or phone; the bill-reminders Edge
-- Function reads these with the service role to send web-push notifications.
create table public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now()
);

create index push_subscriptions_owner_idx on public.push_subscriptions (owner_id);

alter table public.push_subscriptions enable row level security;

create policy "push_subscriptions_select_own" on public.push_subscriptions
  for select using (owner_id = auth.uid());
create policy "push_subscriptions_insert_own" on public.push_subscriptions
  for insert with check (owner_id = auth.uid());
create policy "push_subscriptions_update_own" on public.push_subscriptions
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "push_subscriptions_delete_own" on public.push_subscriptions
  for delete using (owner_id = auth.uid());
