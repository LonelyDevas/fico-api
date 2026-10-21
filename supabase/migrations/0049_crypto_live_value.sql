-- Crypto holdings: the last CoinGecko price (in the holding's currency) and when it was fetched.
-- The crypto-prices function sets current_value = quantity × last_price on a schedule, and only
-- when a price lookup succeeds, so current_value is always the last known market value and
-- principal_amount stays the cost basis. A null price_updated_at means the holding was never priced.
alter table public.investments
  add column last_price numeric(28, 10),
  add column price_updated_at timestamptz;
