-- Revalue crypto holdings every 30 minutes. The crypto-prices Edge Function existed (0049) but
-- nothing called it, so last_price and price_updated_at stayed empty and holdings showed as stale.
-- Uses call_cron_function from 0056 (project URL and cron secret in Vault).
do $$
begin
  perform cron.schedule('crypto-prices', '*/30 * * * *', $c$select public.call_cron_function('crypto-prices')$c$);
exception when others then
  raise notice 'pg_cron not available; schedule crypto-prices by hand: %', sqlerrm;
end;
$$;
