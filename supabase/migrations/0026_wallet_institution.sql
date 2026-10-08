-- Which bank / e-wallet a wallet belongs to. Stores the catalog id from
-- fico/lib/ph-institutions.ts (e.g. 'bdo', 'gcash'); null = no institution
-- (cash, or a custom one). Kept as free text so the catalog can grow without
-- a migration.
alter table public.wallets add column if not exists institution text;
