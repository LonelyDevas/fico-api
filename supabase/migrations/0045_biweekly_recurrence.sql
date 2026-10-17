-- Bi-weekly recurrence. On its own: a new enum value cannot be used in the transaction that adds it.
-- Restored from the offline app's local schema (fico lib/local/schema.generated.ts).

alter type recurring_frequency add value if not exists 'biweekly' after 'weekly';
