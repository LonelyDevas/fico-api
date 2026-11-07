-- Goal auto-funding: how much of each payday goes to a goal, like a piggy bank.
-- {"kind": "percent", "value": 10} = 10% of the pay; {"kind": "fixed", "value": 2000} = ₱2,000.
-- The money moves into the goal's first linked wallet when the user taps it on the payday card;
-- nothing moves on its own. Null = not auto-funded.
alter table public.goals add column if not exists funding jsonb;
