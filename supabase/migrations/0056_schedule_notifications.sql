-- Schedules the push notifications. The bill-reminders and spending-digest Edge Functions only send
-- when something calls them with the cron secret, and nothing did, so no notifications went out.
--
-- pg_cron calls them through pg_net. The project URL and CRON_SECRET are read from Supabase Vault
-- at run time so neither is stored in this file. Add them once (SQL Editor) before or after this:
--   select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
--   select vault.create_secret('<CRON_SECRET>', 'cron_secret');
--
-- Times are Manila (UTC+8), written in UTC because pg_cron runs in UTC:
--   bill-reminders   09:00 daily           -> 01:00 UTC
--   spending-digest  08:00, 14:00, 20:00   -> 00:00, 06:00, 12:00 UTC
-- If pg_cron or pg_net is not available, enable them in the dashboard (Database > Extensions) and
-- run this file again.

create or replace function public.call_cron_function(fn text)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  base text := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url');
  secret text := (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret');
begin
  if base is null or secret is null then
    raise warning 'call_cron_function(%): add project_url and cron_secret to Vault', fn;
    return;
  end if;
  perform net.http_post(
    url := rtrim(base, '/') || '/functions/v1/' || fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', secret),
    body := '{}'::jsonb
  );
end;
$$;

revoke all on function public.call_cron_function(text) from public, anon, authenticated;

do $$
begin
  create extension if not exists pg_cron;
  create extension if not exists pg_net;
  perform cron.schedule('bill-reminders', '0 1 * * *', $c$select public.call_cron_function('bill-reminders')$c$);
  perform cron.schedule('spending-digest', '0 0,6,12 * * *', $c$select public.call_cron_function('spending-digest')$c$);
exception when others then
  raise notice 'pg_cron/pg_net not enabled; schedule the notification jobs manually: %', sqlerrm;
end;
$$;
