-- Credit cards: the spending limit the bank granted (e.g. 50,000). For a
-- credit_card wallet, `balance` is the amount used/owed so far, so the card
-- reads as balance / credit_limit. Null for every other wallet type.
alter table public.wallets add column if not exists credit_limit numeric(14, 2);
