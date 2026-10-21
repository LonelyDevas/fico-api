import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

// Helpers server.ts already has, passed in so this file adds tools without
// opening its own database connection.
export interface Deps {
  query: <R extends Record<string, any> = any>(sql: string, params?: unknown[]) => Promise<R[]>;
  today: () => string;
  round: (n: number) => number;
  safe: <A>(fn: (args: A) => Promise<unknown>) => (args: A) => Promise<any>;
}

// Same conventions as server.ts: $1 is the owner id, $2 the time zone.
const DONE = `t.owner_id = $1 AND t.status = 'completed'`;
const LOCAL_DATE = `(t.date AT TIME ZONE $2)::date`;
const TODAY = `(now() AT TIME ZONE $2)::date`;

// Spending that recurs at the same amount every month. Anything paid through
// a bill on the Bills page counts too.
const FIXED_CATEGORIES = ["Rent", "Bills & Utilities", "Insurance", "Subscription"];

export interface Baseline {
  months_requested: number;
  months: { month: string; total: number; fixed: number; variable: number; left_out: number }[];
  months_used: string[];
  average_monthly: { total: number; fixed: number; variable: number };
  left_out_average_monthly: number;
  excluded_categories: string[];
  flagged_transactions: number;
  notes: string[];
}

// Average monthly spending over the last N full months, leaving out
// transactions flagged exclude_from_baseline, categories the user excluded,
// transfers, and credit card payments (the card's purchases already count).
export async function baselineSpending({ query, today, round }: Deps, months: number): Promise<Baseline> {
  const rows = await query<{ month: string; total: number; fixed: number; left_out: number; flagged: number }>(
    `WITH ex AS (
       SELECT COALESCE((SELECT baseline_excluded_category_ids FROM public.profiles WHERE id = $1), '{}') AS ids
     ), spend AS (
       SELECT to_char(date_trunc('month', ${LOCAL_DATE}), 'YYYY-MM') AS month, t.amount,
              (t.exclude_from_baseline OR t.category_id = ANY(ex.ids)) AS left_out,
              t.exclude_from_baseline AS flagged,
              (t.bill_id IS NOT NULL OR c.name = ANY($4::text[])) AS fixed
       FROM public.transactions t
       CROSS JOIN ex
       LEFT JOIN public.categories c ON c.id = t.category_id
       LEFT JOIN public.bills b ON b.id = t.bill_id
       WHERE ${DONE} AND t.type = 'expense' AND b.pays_wallet_id IS NULL
         AND ${LOCAL_DATE} >= date_trunc('month', ${TODAY}) - ($3::int * INTERVAL '1 month')
         AND ${LOCAL_DATE} < date_trunc('month', ${TODAY})
     )
     SELECT month,
            COALESCE(SUM(amount) FILTER (WHERE NOT left_out), 0) AS total,
            COALESCE(SUM(amount) FILTER (WHERE NOT left_out AND fixed), 0) AS fixed,
            COALESCE(SUM(amount) FILTER (WHERE left_out), 0) AS left_out,
            COUNT(*) FILTER (WHERE flagged) AS flagged
     FROM spend GROUP BY month ORDER BY month`,
    [months, FIXED_CATEGORIES]
  );
  const excluded = await query<{ name: string }>(
    `SELECT c.name FROM public.categories c
     WHERE c.id = ANY(COALESCE((SELECT baseline_excluded_category_ids FROM public.profiles WHERE id = $1), '{}'))
     ORDER BY c.name`
  );

  // Every full month in the window, so a month with no spending shows as 0.
  const monthList: string[] = [];
  for (let d = new Date(`${today().slice(0, 7)}-01T00:00:00Z`), i = 0; i < months; i++) {
    d.setUTCMonth(d.getUTCMonth() - 1);
    monthList.unshift(d.toISOString().slice(0, 7));
  }
  const byMonth = new Map(rows.map((r) => [r.month, r]));
  const out = monthList.map((month) => {
    const r = byMonth.get(month);
    const total = round(r?.total ?? 0);
    const fixed = round(r?.fixed ?? 0);
    return { month, total, fixed, variable: round(total - fixed), left_out: round(r?.left_out ?? 0) };
  });

  // A month where everything was left out (for example only imported history)
  // says nothing about a normal month, so it doesn't drag the average down.
  const used = out.filter((m) => m.total > 0);
  const avg = (k: "total" | "fixed" | "variable" | "left_out", list = used) =>
    list.length ? round(list.reduce((s, m) => s + m[k], 0) / list.length) : 0;
  const flagged = rows.reduce((s, r) => s + r.flagged, 0);

  const notes = [
    `Fixed = paid through a bill, or in ${FIXED_CATEGORIES.join(", ")}. Everything else is variable.`,
    "Transfers between your own wallets and credit card payments are never counted.",
  ];
  if (used.length < out.length) {
    notes.push(`Months with nothing left after exclusions are skipped in the average: ${out.filter((m) => m.total === 0).map((m) => m.month).join(", ")}.`);
  }
  if (!flagged && !excluded.length) {
    notes.push("Nothing is left out yet. In Fico, flag one-off transactions (edit a transaction) or whole categories (edit a category) as 'Leave out of baseline'.");
  }

  return {
    months_requested: months,
    months: out,
    months_used: used.map((m) => m.month),
    average_monthly: { total: avg("total"), fixed: avg("fixed"), variable: avg("variable") },
    left_out_average_monthly: avg("left_out", out),
    excluded_categories: excluded.map((c) => c.name),
    flagged_transactions: flagged,
    notes,
  };
}

// Confirmed planned income from the planned_items table, if it exists yet.
async function confirmedPlannedIncome({ query, round }: Deps, until?: string) {
  try {
    const rows = await query<{ name: string; date: string; amount: number }>(
      `SELECT p.name, p.date::date::text AS date, p.amount_low AS amount
       FROM public.planned_items p
       WHERE p.owner_id = $1 AND p.type::text = 'income' AND p.status::text = 'confirmed'
         AND p.date::date >= (now() AT TIME ZONE $2)::date
         AND ($3::date IS NULL OR p.date::date <= $3::date)
       ORDER BY p.date`,
      [until ?? null]
    );
    return { available: true, items: rows, total: round(rows.reduce((s, r) => s + r.amount, 0)) };
  } catch {
    return { available: false, items: [], total: 0 };
  }
}

export function registerBaselineTools(server: McpServer, deps: Deps) {
  const { query, today, round, safe } = deps;

  server.tool(
    "baseline_spending",
    "Your normal monthly spending: the average over the last N full months, leaving out transactions and categories flagged 'Leave out of baseline' in Fico (imported history, travel, ATM cash, one-offs), transfers and credit card payments. Split into fixed and variable, with each month shown.",
    { months: z.number().int().min(1).max(12).default(3).describe("Full months to average over") },
    safe(async ({ months }: { months: number }) => baselineSpending(deps, months))
  );

  server.tool(
    "runway",
    "How long your money lasts after moving into a rented place. Takes the monthly rent, months of deposit and advance, and one-time setup costs, and returns the move-in total, the cash left after moving in, and the months of runway at your baseline spending plus rent.",
    {
      monthly_rent: z.number().positive().describe("Rent per month in PHP"),
      deposit_months: z.number().int().min(0).max(12).default(2),
      advance_months: z.number().int().min(0).max(12).default(1),
      setup_cost: z.number().min(0).default(0).describe("One-time costs: furniture, moving, first groceries"),
      cash: z.number().min(0).optional().describe("Money you'll have at move-in. Default: cash on hand plus savings now, minus credit card debt"),
      monthly_spend: z.number().min(0).optional().describe("Living costs per month without rent. Default: baseline_spending over 3 months"),
      include_planned_income: z.boolean().default(false).describe("Add confirmed planned income (from planned items) to the cash"),
    },
    safe(async (args: {
      monthly_rent: number;
      deposit_months: number;
      advance_months: number;
      setup_cost: number;
      cash?: number;
      monthly_spend?: number;
      include_planned_income: boolean;
    }) => {
      const { monthly_rent: rent, deposit_months, advance_months, setup_cost } = args;
      const [bal] = await query(
        `SELECT COALESCE(SUM(balance) FILTER (WHERE type::text NOT IN ('savings', 'credit_card')), 0) AS cash,
                COALESCE(SUM(balance) FILTER (WHERE type::text = 'savings'), 0) AS savings,
                COALESCE(SUM(balance) FILTER (WHERE type::text = 'credit_card'), 0) AS card_owed
         FROM public.wallets WHERE owner_id = $1 AND status = 'active'`
      );
      const startCash = args.cash ?? round(bal.cash + bal.savings - bal.card_owed);
      const planned = args.include_planned_income ? await confirmedPlannedIncome(deps) : undefined;
      const available = round(startCash + (planned?.total ?? 0));

      const baseline = args.monthly_spend === undefined ? await baselineSpending(deps, 3) : undefined;
      const spend = args.monthly_spend ?? baseline!.average_monthly.total;

      const deposit = round(rent * deposit_months);
      const advance = round(rent * advance_months);
      const moveIn = round(deposit + advance + setup_cost);
      const after = round(available - moveIn);

      // The advance pays the first months' rent, so those months only cost the
      // living expenses. After that each month costs spend + rent.
      let left = after;
      let months = 0;
      if (left > 0 && spend + rent > 0) {
        for (let i = 0; i < 600 && left > 0; i++) {
          const cost = spend + (i < advance_months ? 0 : rent);
          if (cost <= 0) { months = Infinity; break; }
          if (left >= cost) { left -= cost; months += 1; }
          else { months += left / cost; left = 0; }
        }
      }
      const runway = Number.isFinite(months) ? round(months) : null;
      const end = runway === null ? null : (() => {
        const d = new Date(`${today()}T00:00:00Z`);
        d.setUTCDate(d.getUTCDate() + Math.floor(runway * (365.25 / 12)));
        return d.toISOString().slice(0, 10);
      })();

      return {
        today: today(),
        move_in: { deposit, advance, setup_cost: round(setup_cost), total: moveIn },
        cash: {
          starting: startCash,
          source: args.cash === undefined ? "cash on hand + savings - credit card debt, from your wallets now" : "given",
          wallets_now: args.cash === undefined
            ? { cash_on_hand: round(bal.cash), savings: round(bal.savings), credit_card_owed: round(bal.card_owed) }
            : undefined,
          confirmed_planned_income: planned,
          available_at_move_in: available,
          after_move_in: after,
        },
        monthly: {
          living_costs: round(spend),
          living_costs_source: args.monthly_spend === undefined ? "baseline_spending, 3 full months" : "given",
          rent: round(rent),
          total: round(spend + rent),
        },
        runway_months: after <= 0 ? 0 : runway,
        money_runs_out_around: after <= 0 ? today() : end,
        baseline: baseline && { months_used: baseline.months_used, average_monthly: baseline.average_monthly },
        notes: [
          after <= 0
            ? "The move-in total is more than the money available, so there is no runway."
            : `The first ${advance_months} month(s) of rent are covered by the advance; after that each month costs living costs + rent.`,
          "Runway assumes no income after moving in. The deposit is not counted as spendable even though it usually comes back when you move out.",
        ],
      };
    })
  );
}
