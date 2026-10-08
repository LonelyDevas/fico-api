-- Crypto holdings: which coin an investment is (its CoinGecko id), the ticker to show, and how many
-- coins are held. The app multiplies quantity by the live price to show what it is worth now.
alter table public.investments
  add column coin_id text,
  add column coin_symbol text,
  add column quantity numeric(28, 10);
