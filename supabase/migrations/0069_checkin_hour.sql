-- The evening check-in hour each account picks (Manila time, 0-23). It lives on every push device row
-- of the account; the app writes the same hour to all of them. The spending-digest function now runs
-- every hour and sends the check-in only at this hour, plus the usual updates at 08:00 and 14:00.
alter table public.push_subscriptions
  add column if not exists checkin_hour smallint not null default 20
  check (checkin_hour between 0 and 23);

do $$
begin
  perform cron.unschedule('spending-digest');
  perform cron.schedule('spending-digest', '0 * * * *', $c$select public.call_cron_function('spending-digest')$c$);
exception when others then
  raise notice 'pg_cron not available; schedule spending-digest hourly by hand: %', sqlerrm;
end;
$$;
