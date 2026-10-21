import express, { Request, Response, NextFunction } from "express";
import pg from "pg";
import { z } from "zod";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { timingSafeEqual } from "node:crypto";
import { registerPlannedItems } from "./planned-items.js";
import { registerSafeToSpend } from "./tools/safe-to-spend.js";
import { valueHoldings, type Holding } from "./crypto.js";
import { registerGoalsTools } from "./goals.js";
import { baselineSpending, registerBaselineTools } from "./baseline.js";

// ---------- config ----------
const env = (k: string, d = "") => (process.env[k] ?? d).trim();

const PROJECT_REF = env("SUPABASE_PROJECT_REF");
const DB_PASSWORD = env("FICO_DB_PASSWORD");
const AUTH_TOKEN = env("MCP_AUTH_TOKEN");
const OWNER_ID = env("FICO_OWNER_ID");
const TZ = env("FICO_TIMEZONE", "Asia/Manila");

if (!env("DATABASE_URL") && !(PROJECT_REF && DB_PASSWORD)) {
  throw new Error("Set DATABASE_URL, or SUPABASE_PROJECT_REF and FICO_DB_PASSWORD");
}
if (PROJECT_REF && !/^[a-z0-9]{20}$/.test(PROJECT_REF)) throw new Error("SUPABASE_PROJECT_REF looks wrong");
if (!/^[A-Za-z0-9_-]{32,}$/.test(AUTH_TOKEN)) {
  throw new Error("MCP_AUTH_TOKEN is required: 32+ characters of letters, digits, - or _ (openssl rand -hex 32)");
}
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(OWNER_ID)) {
  throw new Error("FICO_OWNER_ID must be your Supabase user id (a UUID)");
}
if (!/^[A-Za-z_]+(\/[A-Za-z0-9_+-]+)*$/.test(TZ)) throw new Error("FICO_TIMEZONE must be an IANA name like Asia/Manila");

// Return numeric as numbers and date as plain YYYY-MM-DD strings.
pg.types.setTypeParser(1700, (v) => parseFloat(v)); // numeric
pg.types.setTypeParser(20, (v) => parseInt(v, 10)); // bigint (count)
pg.types.setTypeParser(1082, (v) => v); // date

// ---------- database (read-only by construction) ----------
const sslFor = (url: string) =>
  /localhost|127\.0\.0\.1/.test(url) ? undefined : { rejectUnauthorized: false };

// With only a project ref and password, find the project's Supabase pooler
// by trying each region's pooler host; the right one is the one that accepts
// the login (the others answer "Tenant or user not found").
const REGIONS = [
  "ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "ap-northeast-2", "ap-south-1",
  "us-east-1", "us-east-2", "us-west-1", "us-west-2", "ca-central-1", "sa-east-1",
  "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-central-2", "eu-north-1",
];
async function findDatabaseUrl(): Promise<string> {
  const given = env("DATABASE_URL");
  if (given) return given;
  const user = encodeURIComponent(`fico_readonly.${PROJECT_REF}`);
  const pass = encodeURIComponent(DB_PASSWORD);
  const candidates = ["aws-0", "aws-1"].flatMap((p) =>
    REGIONS.map((r) => `postgresql://${user}:${pass}@${p}-${r}.pooler.supabase.com:5432/postgres`)
  );
  const errors: string[] = [];
  const found = await Promise.any(
    candidates.map(async (url) => {
      const client = new pg.Client({ connectionString: url, ssl: sslFor(url), connectionTimeoutMillis: 10000 });
      try {
        await client.connect();
        await client.query("SELECT 1");
        return url;
      } catch (e) {
        errors.push(`${new URL(url).hostname}: ${(e as Error).message}`);
        throw e;
      } finally {
        await client.end().catch(() => {});
      }
    })
  ).catch(() => {
    const wrongPassword = errors.find((e) => /password authentication failed/i.test(e));
    throw new Error(wrongPassword ?? `No Supabase pooler accepted the login:\n${errors.join("\n")}`);
  });
  console.log(`Using database at ${new URL(found).hostname}`);
  return found;
}

const DATABASE_URL = await findDatabaseUrl();
const pool = new pg.Pool({ connectionString: DATABASE_URL, max: 3, ssl: sslFor(DATABASE_URL) });

// Every query runs in a READ ONLY transaction with a timeout, so even a
// misconfigured role cannot write. $1 is always the owner id and $2 the
// time zone; tool parameters start at $3.
async function query<R extends pg.QueryResultRow = any>(sql: string, params: unknown[] = []) {
  const client = await pool.connect();
  try {
    await client.query("BEGIN READ ONLY");
    await client.query("SET LOCAL statement_timeout = 8000");
    // Postgres rejects parameters a statement doesn't reference, so send only up to the highest $n used.
    const used = Math.max(0, ...[...sql.matchAll(/\$(\d+)/g)].map((m) => Number(m[1])));
    const res = await client.query<R>(sql, [OWNER_ID, TZ, ...params].slice(0, used));
    await client.query("COMMIT");
    return res.rows;
  } catch (e) {
    await client.query("ROLLBACK").catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

// Fico stores amounts as positive numbers and tells income from expense with
// `type`. Pending rows are future bill payments and cancelled rows never
// happened, so only completed rows count as real money movement.
const DONE = `t.owner_id = $1 AND t.status = 'completed'`;
const LOCAL_DATE = `(t.date AT TIME ZONE $2)::date`;
const TODAY = `(now() AT TIME ZONE $2)::date`;
const MONTH = (col: string) => `to_char(date_trunc('month', ${col}), 'YYYY-MM')`;

// ---------- helpers ----------
const dateStr = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, "Use YYYY-MM-DD");
const round = (n: number) => Math.round(n * 100) / 100;
const json = (data: unknown) => ({
  content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }],
});
const fail = (e: unknown) => ({
  isError: true,
  content: [{ type: "text" as const, text: `Query failed: ${(e as Error).message}` }],
});
const safe =
  <A>(fn: (args: A) => Promise<unknown>) =>
  async (args: A) => {
    try {
      return json(await fn(args));
    } catch (e) {
      return fail(e);
    }
  };

const today = () => new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(new Date());
const nextJanuary = () => `${Number(today().slice(0, 4)) + 1}-01-01`;
const yearEnd = () => `${today().slice(0, 4)}-12-31`;
const dayBefore = (date: string) => new Date(Date.parse(date) - 86400000).toISOString().slice(0, 10);

function addFrequency(date: string, freq: string): string {
  const [y, m, d] = date.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  if (freq === "daily") dt.setUTCDate(dt.getUTCDate() + 1);
  else if (freq === "weekly") dt.setUTCDate(dt.getUTCDate() + 7);
  else if (freq === "biweekly") dt.setUTCDate(dt.getUTCDate() + 14);
  else if (freq === "yearly") dt.setUTCFullYear(dt.getUTCFullYear() + 1);
  else {
    // monthly: keep the day, clamped to the end of shorter months
    const last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
    return new Date(Date.UTC(y, m, Math.min(d, last))).toISOString().slice(0, 10);
  }
  return dt.toISOString().slice(0, 10);
}

const PER_MONTH: Record<string, number> = {
  daily: 365.25 / 12,
  weekly: 52.18 / 12,
  biweekly: 26.09 / 12,
  monthly: 1,
  yearly: 1 / 12,
};

// Monthly income/expense for the last N months, current month included.
async function monthlyRows(months: number) {
  return query<{ month: string; income: number; expenses: number }>(
    `SELECT ${MONTH(LOCAL_DATE)} AS month,
            COALESCE(SUM(t.amount) FILTER (WHERE t.type = 'income'), 0) AS income,
            COALESCE(SUM(t.amount) FILTER (WHERE t.type = 'expense'), 0) AS expenses
     FROM public.transactions t
     WHERE ${DONE} AND t.type <> 'transfer'
       AND ${LOCAL_DATE} >= date_trunc('month', ${TODAY}) - (($3::int - 1) * INTERVAL '1 month')
     GROUP BY 1 ORDER BY 1`,
    [months]
  );
}

// Unpaid bills and expected income, with recurring ones projected forward.
async function scheduled(until: string) {
  const rows = await query(
    `SELECT b.name, b.type::text AS type, b.amount, COALESCE(b.paid_amount, 0) AS paid_amount,
            (b.due_date AT TIME ZONE $2)::date AS due_date, b.is_recurring,
            b.recurring_frequency::text AS frequency, b.payment_status::text AS payment_status,
            c.name AS category, w.name AS wallet,
            pw.name AS pays_credit_card, b.obligation_id IS NOT NULL AS is_debt_installment
     FROM public.bills b
     LEFT JOIN public.categories c ON c.id = b.category_id
     LEFT JOIN public.wallets w ON w.id = b.wallet_id
     LEFT JOIN public.wallets pw ON pw.id = b.pays_wallet_id
     WHERE b.owner_id = $1 AND b.status = 'active'
       AND b.payment_status NOT IN ('paid', 'received')
       AND (b.due_date AT TIME ZONE $2)::date <= $3::date
     ORDER BY b.due_date`,
    [until]
  );
  const now = today();
  const items: any[] = [];
  for (const b of rows) {
    let due: string = b.due_date;
    let amount = round(b.amount - b.paid_amount);
    for (let i = 0; due <= until && i < 400; i++) {
      items.push({
        date: due,
        name: b.name,
        kind: b.type === "income" ? "income" : "bill",
        amount,
        category: b.category,
        wallet: b.wallet,
        overdue: due < now,
        projected: i > 0,
        credit_card_payment: b.pays_credit_card ?? undefined,
        debt_installment: b.is_debt_installment || undefined,
      });
      if (!b.is_recurring || !b.frequency) break;
      due = addFrequency(due, b.frequency);
      amount = round(b.amount);
    }
  }
  items.sort((a, b) => a.date.localeCompare(b.date));
  const sum = (f: (x: any) => boolean) => round(items.filter(f).reduce((s, x) => s + x.amount, 0));
  return {
    items,
    totals: {
      bills: sum((x) => x.kind === "bill"),
      bills_excluding_card_payments: sum((x) => x.kind === "bill" && !x.credit_card_payment),
      credit_card_payments: sum((x) => !!x.credit_card_payment),
      income: sum((x) => x.kind === "income"),
      overdue: sum((x) => x.kind === "bill" && x.overdue),
    },
  };
}

// Active investments with crypto holdings valued at the live price (see crypto.ts).
async function activeInvestments() {
  const rows = await query<Holding & { name: string; principal_amount: number }>(
    `SELECT name, type::text AS type, platform, principal_amount, current_value, dividends_received,
            expected_return_rate, (maturity_date AT TIME ZONE $2)::date AS maturity_date, currency,
            coin_id, coin_symbol, quantity,
            (to_jsonb(i) ->> 'last_price')::numeric AS stored_price,
            to_jsonb(i) ->> 'price_updated_at' AS stored_priced_at
     FROM public.investments i WHERE owner_id = $1 AND status = 'active'`
  );
  const values = await valueHoldings(rows);
  return rows.map(({ coin_id, stored_price, stored_priced_at, ...r }, i) => ({ ...r, ...values[i] }));
}

// ---------- MCP server ----------
function buildServer() {
  const server = new McpServer({ name: "fico-mcp", version: "2.0.0" });

  server.tool(
    "accounts_overview",
    "Every active wallet (bank, cash, e-wallet, savings, credit card) with its balance, plus totals for cash on hand, savings, credit card debt, investments, debts, money lent out and net worth. Start here.",
    {},
    safe(async () => {
      const wallets = await query(
        `SELECT name, type::text AS type, balance, currency, institution, credit_limit,
                interest_rate, maturity_date, total_interest_earned
         FROM public.wallets WHERE owner_id = $1 AND status = 'active'
         ORDER BY type, balance DESC`
      );
      const holdings = await activeInvestments();
      const investments = holdings.reduce((s, h) => s + h.current_value, 0);
      const stale = holdings.filter((h) => h.stale).map((h) => h.name);
      const [extra] = await query(
        `SELECT
           (SELECT COALESCE(SUM(remaining_balance), 0) FROM public.obligations
             WHERE owner_id = $1 AND direction = 'debt' AND status IN ('active', 'partially_paid', 'defaulted')) AS debts,
           (SELECT COALESCE(SUM(remaining_balance), 0) FROM public.obligations
             WHERE owner_id = $1 AND direction = 'lending' AND status IN ('active', 'partially_paid', 'defaulted')) AS lent_out`
      );
      const total = (f: (w: any) => boolean) => round(wallets.filter(f).reduce((s, w) => s + w.balance, 0));
      const cash = total((w) => !["savings", "credit_card"].includes(w.type));
      const savings = total((w) => w.type === "savings");
      const cardOwed = total((w) => w.type === "credit_card");
      return {
        wallets,
        totals: {
          cash_on_hand: cash,
          savings,
          credit_card_owed: cardOwed,
          investments: round(investments),
          debts_owed: round(extra.debts),
          lent_out: round(extra.lent_out),
          net_worth: round(cash + savings + investments + extra.lent_out - cardOwed - extra.debts),
        },
        note:
          "A credit card's balance is the amount owed on it." +
          (stale.length ? ` Live prices were unavailable for ${stale.join(", ")}, so their last known value is used.` : ""),
      };
    })
  );

  server.tool(
    "get_transactions",
    "List completed transactions between two dates, newest first, with category and wallet names. Filter by type, category, wallet or text in the description.",
    {
      start_date: dateStr.describe("Inclusive start, YYYY-MM-DD"),
      end_date: dateStr.describe("Inclusive end, YYYY-MM-DD"),
      type: z.enum(["income", "expense", "transfer"]).optional(),
      category: z.string().max(100).optional().describe("Category name, case-insensitive"),
      wallet: z.string().max(100).optional().describe("Wallet name, case-insensitive"),
      search: z.string().max(100).optional().describe("Text to find in the description"),
      limit: z.number().int().min(1).max(300).default(100),
    },
    safe(async ({ start_date, end_date, type, category, wallet, search, limit }) => {
      const params: unknown[] = [start_date, end_date];
      let where = `${DONE} AND ${LOCAL_DATE} BETWEEN $3::date AND $4::date`;
      const add = (sql: string, v: unknown) => {
        params.push(v);
        where += ` AND ${sql.replace("?", `$${params.length + 2}`)}`;
      };
      if (type) add(`t.type::text = ?`, type);
      if (category) add(`lower(c.name) = lower(?)`, category);
      if (wallet) add(`lower(w.name) = lower(?)`, wallet);
      if (search) add(`t.description ILIKE '%' || ? || '%'`, search.replace(/[%_\\]/g, "\\$&"));
      params.push(limit);
      const rows = await query(
        `SELECT ${LOCAL_DATE} AS date, t.type::text AS type, t.amount, c.name AS category,
                w.name AS wallet, tw.name AS to_wallet, t.description, t.tags
         FROM public.transactions t
         LEFT JOIN public.categories c ON c.id = t.category_id
         LEFT JOIN public.wallets w ON w.id = t.wallet_id
         LEFT JOIN public.wallets tw ON tw.id = t.to_wallet_id
         WHERE ${where}
         ORDER BY t.date DESC
         LIMIT $${params.length + 2}`,
        params
      );
      return { count: rows.length, transactions: rows };
    })
  );

  server.tool(
    "monthly_summary",
    "Income, expenses and net savings per month for the last N months (current month included and marked partial). Transfers between your own wallets are left out. Averages use full months only.",
    { months: z.number().int().min(1).max(36).default(6) },
    safe(async ({ months }) => {
      const rows = await monthlyRows(months);
      const current = today().slice(0, 7);
      const out = rows.map((r) => ({
        month: r.month,
        income: round(r.income),
        expenses: round(r.expenses),
        net: round(r.income - r.expenses),
        savings_rate_percent: r.income ? round(((r.income - r.expenses) / r.income) * 100) : null,
        partial: r.month === current || undefined,
      }));
      const full = out.filter((r) => !r.partial);
      const avg = (k: "income" | "expenses" | "net") =>
        full.length ? round(full.reduce((s, r) => s + r[k], 0) / full.length) : null;
      return {
        months: out,
        averages_full_months: { months: full.length, income: avg("income"), expenses: avg("expenses"), net: avg("net") },
      };
    })
  );

  server.tool(
    "category_breakdown",
    "Total spent (or earned) per category between two dates, largest first, with share of the total and transaction counts.",
    {
      start_date: dateStr,
      end_date: dateStr,
      type: z.enum(["income", "expense"]).default("expense"),
    },
    safe(async ({ start_date, end_date, type }) => {
      const rows = await query(
        `SELECT COALESCE(c.name, 'Uncategorized') AS category, SUM(t.amount) AS total, COUNT(*) AS transactions
         FROM public.transactions t LEFT JOIN public.categories c ON c.id = t.category_id
         WHERE ${DONE} AND t.type::text = $5 AND ${LOCAL_DATE} BETWEEN $3::date AND $4::date
         GROUP BY 1 ORDER BY total DESC`,
        [start_date, end_date, type]
      );
      const grand = rows.reduce((s, r) => s + r.total, 0);
      return {
        type,
        total: round(grand),
        categories: rows.map((r) => ({
          ...r,
          total: round(r.total),
          percent: grand ? round((r.total / grand) * 100) : 0,
        })),
      };
    })
  );

  server.tool(
    "spending_trends",
    "Expense per category per month for the last N full months, with each category's monthly average, its trend, and month-to-date spend this month. Use it to find where spending is growing or could be cut.",
    { months: z.number().int().min(1).max(24).default(6) },
    safe(async ({ months }) => {
      const rows = await query(
        `SELECT COALESCE(c.name, 'Uncategorized') AS category, ${MONTH(LOCAL_DATE)} AS month, SUM(t.amount) AS total
         FROM public.transactions t LEFT JOIN public.categories c ON c.id = t.category_id
         WHERE ${DONE} AND t.type = 'expense'
           AND ${LOCAL_DATE} >= date_trunc('month', ${TODAY}) - ($3::int * INTERVAL '1 month')
         GROUP BY 1, 2`,
        [months]
      );
      const current = today().slice(0, 7);
      const monthList: string[] = [];
      for (let d = new Date(`${current}-01T00:00:00Z`), i = 0; i < months; i++) {
        d.setUTCMonth(d.getUTCMonth() - 1);
        monthList.unshift(d.toISOString().slice(0, 7));
      }
      const byCat = new Map<string, Record<string, number>>();
      for (const r of rows) {
        if (!byCat.has(r.category)) byCat.set(r.category, {});
        byCat.get(r.category)![r.month] = round(r.total);
      }
      const categories = [...byCat.entries()].map(([category, m]) => {
        const series = monthList.map((mo) => m[mo] ?? 0);
        const average = round(series.reduce((s, v) => s + v, 0) / months);
        const half = Math.floor(months / 2);
        const early = half ? series.slice(0, half).reduce((s, v) => s + v, 0) / half : 0;
        const late = half ? series.slice(-half).reduce((s, v) => s + v, 0) / half : 0;
        return {
          category,
          monthly: Object.fromEntries(monthList.map((mo, i) => [mo, series[i]])),
          monthly_average: average,
          trend_percent: early ? round(((late - early) / early) * 100) : null,
          this_month_so_far: m[current] ?? 0,
        };
      });
      categories.sort((a, b) => b.monthly_average - a.monthly_average);
      return { full_months: monthList, current_month: current, categories };
    })
  );

  server.tool(
    "top_expenses",
    "The largest single expenses and the most frequent expense descriptions (where small purchases add up) between two dates.",
    { start_date: dateStr, end_date: dateStr, limit: z.number().int().min(1).max(50).default(15) },
    safe(async ({ start_date, end_date, limit }) => {
      const largest = await query(
        `SELECT ${LOCAL_DATE} AS date, t.amount, c.name AS category, w.name AS wallet, t.description
         FROM public.transactions t
         LEFT JOIN public.categories c ON c.id = t.category_id
         LEFT JOIN public.wallets w ON w.id = t.wallet_id
         WHERE ${DONE} AND t.type = 'expense' AND ${LOCAL_DATE} BETWEEN $3::date AND $4::date
         ORDER BY t.amount DESC LIMIT $5`,
        [start_date, end_date, limit]
      );
      const frequent = await query(
        `SELECT lower(trim(t.description)) AS description, COUNT(*) AS times, SUM(t.amount) AS total,
                AVG(t.amount) AS average, MIN(c.name) AS category
         FROM public.transactions t LEFT JOIN public.categories c ON c.id = t.category_id
         WHERE ${DONE} AND t.type = 'expense' AND ${LOCAL_DATE} BETWEEN $3::date AND $4::date
           AND COALESCE(trim(t.description), '') <> ''
         GROUP BY 1 HAVING COUNT(*) > 1
         ORDER BY total DESC LIMIT $5`,
        [start_date, end_date, limit]
      );
      return {
        largest,
        most_frequent: frequent.map((r) => ({ ...r, total: round(r.total), average: round(r.average) })),
      };
    })
  );

  server.tool(
    "upcoming_bills",
    "Unpaid bills and expected income from Fico's Bills page up to a date (default: December 31 this year), with recurring ones projected forward, overdue ones flagged, and totals. Also lists every recurring bill and income as a monthly cost.",
    { until: dateStr.optional().describe("Inclusive end date, YYYY-MM-DD") },
    safe(async ({ until }) => {
      const end = until ?? yearEnd();
      const sched = await scheduled(end);
      const recurring = await query(
        `SELECT DISTINCT ON (COALESCE(b.parent_bill_id, b.id))
                b.name, b.type::text AS type, b.amount, b.recurring_frequency::text AS frequency,
                c.name AS category, b.pays_wallet_id IS NOT NULL AS credit_card_payment
         FROM public.bills b LEFT JOIN public.categories c ON c.id = b.category_id
         WHERE b.owner_id = $1 AND b.status = 'active' AND b.is_recurring
         ORDER BY COALESCE(b.parent_bill_id, b.id), b.due_date DESC`
      );
      const rec = recurring.map((r) => ({
        ...r,
        per_month: round(r.amount * (PER_MONTH[r.frequency] ?? 1)),
      }));
      const perMonth = (f: (r: any) => boolean) => round(rec.filter(f).reduce((s, r) => s + r.per_month, 0));
      return {
        from: today(),
        until: end,
        ...sched,
        recurring: rec,
        recurring_per_month: {
          bills: perMonth((r) => r.type === "bill" && !r.credit_card_payment),
          income: perMonth((r) => r.type === "income"),
        },
        note: "Credit card payments settle spending already recorded as expenses, so don't count them as extra spending.",
      };
    })
  );

  registerSafeToSpend(server, { query, scheduled, safe, today, dayBefore, round, dateStr, TODAY });

  server.tool(
    "budgets_status",
    "Active budgets with their limit, amount spent, amount left, percent used, period dates and categories.",
    {},
    safe(async () =>
      query(
        `SELECT b.name, b.period::text AS period, b.status::text AS status, b.amount AS limit_amount, b.spent,
                b.remaining, b.percentage_spent, b.alert_threshold,
                (b.start_date AT TIME ZONE $2)::date AS start_date, (b.end_date AT TIME ZONE $2)::date AS end_date,
                ARRAY(SELECT c.name FROM public.categories c
                      WHERE c.id = ANY(CASE WHEN cardinality(b.category_ids) > 0 THEN b.category_ids
                                            ELSE ARRAY[b.category_id] END)) AS categories
         FROM public.budgets b
         WHERE b.owner_id = $1 AND b.status <> 'archived'
         ORDER BY b.percentage_spent DESC`
      )
    )
  );

  server.tool(
    "debts_and_loans",
    "Open debts you owe and money you lent out: remaining balance, interest, installment amount and schedule, and due date.",
    {},
    safe(async () =>
      query(
        `SELECT direction::text AS direction, name, counterparty, principal_amount, remaining_balance, currency,
                interest_rate, interest_type::text AS interest_type, total_with_interest,
                is_installment, installment_amount, installment_frequency::text AS installment_frequency,
                paid_installments, total_installments, (due_date AT TIME ZONE $2)::date AS due_date,
                status::text AS status
         FROM public.obligations
         WHERE owner_id = $1 AND status IN ('active', 'partially_paid', 'defaulted')
         ORDER BY direction, due_date NULLS LAST`
      )
    )
  );

  server.tool(
    "investments",
    "Active investments with amount put in (cost basis), current value, gain or loss, dividends, expected return and maturity. Crypto is valued at quantity × the live CoinGecko price; stale: true means the live price was unavailable and the last known value (as of priced_at) is shown.",
    {},
    safe(async () => {
      const rows = await activeInvestments();
      return rows
        .sort((a, b) => b.current_value - a.current_value)
        .map((r) => ({ ...r, gain: round(r.current_value - r.principal_amount) }));
    })
  );

  server.tool(
    "savings_forecast",
    "Estimate how much you can save between today and a target date (default: next January 1). Combines your average monthly income and spending over recent full months, this month so far, cash and savings on hand, credit card debt, and bills already scheduled before the date. Returns the inputs so the numbers can be checked.",
    {
      target_date: dateStr.optional().describe("YYYY-MM-DD, default next January 1"),
      history_months: z.number().int().min(1).max(12).default(3).describe("Full months to average over"),
    },
    safe(async ({ target_date, history_months }) => {
      const target = target_date ?? nextJanuary();
      const now = today();
      const rows = await monthlyRows(history_months + 1);
      const current = now.slice(0, 7);
      const baseline = await baselineSpending({ query, today, round, safe }, history_months);
      // Income is averaged over the same months as the baseline spending, so a
      // month left out entirely (e.g. imported history) is left out of both.
      const full = rows.filter((r) => r.month !== current && baseline.months_used.includes(r.month));
      const thisMonth = rows.find((r) => r.month === current) ?? { income: 0, expenses: 0 };
      const n = full.length || 1;
      const avgIncome = full.reduce((s, r) => s + r.income, 0) / n;
      const rawExpenses = full.reduce((s, r) => s + r.expenses, 0) / n;
      const avgExpenses = baseline.average_monthly.total;
      const daysLeft = Math.max(0, (Date.parse(target) - Date.parse(now)) / 86400000);
      const monthsLeft = daysLeft / (365.25 / 12);

      const [bal] = await query(
        `SELECT COALESCE(SUM(balance) FILTER (WHERE type::text NOT IN ('savings', 'credit_card')), 0) AS cash,
                COALESCE(SUM(balance) FILTER (WHERE type::text = 'savings'), 0) AS savings,
                COALESCE(SUM(balance) FILTER (WHERE type::text = 'credit_card'), 0) AS card_owed
         FROM public.wallets WHERE owner_id = $1 AND status = 'active'`
      );
      const sched = await scheduled(dayBefore(target));
      const top = await query(
        `SELECT COALESCE(c.name, 'Uncategorized') AS category, SUM(t.amount) / $3::numeric AS monthly_average
         FROM public.transactions t LEFT JOIN public.categories c ON c.id = t.category_id
         WHERE ${DONE} AND t.type = 'expense'
           AND ${LOCAL_DATE} >= date_trunc('month', ${TODAY}) - ($3::int * INTERVAL '1 month')
           AND ${LOCAL_DATE} < date_trunc('month', ${TODAY})
         GROUP BY 1 ORDER BY 2 DESC LIMIT 5`,
        [history_months]
      );

      const trendSavings = (avgIncome - avgExpenses) * monthsLeft;
      return {
        today: now,
        target_date: target,
        months_left: round(monthsLeft),
        history: {
          full_months_used: full.map((r) => r.month),
          avg_monthly_income: round(avgIncome),
          avg_monthly_expenses: round(avgExpenses),
          avg_monthly_expenses_source: "baseline_spending (one-offs, excluded categories and card payments left out)",
          avg_monthly_expenses_including_left_out: round(rawExpenses),
          avg_monthly_net: round(avgIncome - avgExpenses),
        },
        this_month_so_far: { income: round(thisMonth.income), expenses: round(thisMonth.expenses) },
        balances_now: {
          cash_on_hand: round(bal.cash),
          savings: round(bal.savings),
          credit_card_owed: round(bal.card_owed),
        },
        scheduled_until_target: sched.totals,
        estimates: {
          savable_at_current_pace: round(trendSavings),
          cash_left_at_target_if_pace_holds: round(bal.cash - bal.card_owed + trendSavings),
        },
        biggest_spending_categories: top.map((r) => ({ ...r, monthly_average: round(r.monthly_average) })),
        notes: [
          "savable_at_current_pace = average monthly net x months left. Recurring bills are already inside the average spending, so scheduled bills are shown for timing and not subtracted again.",
          "Treat one-off scheduled bills or income that did not happen in the history months as adjustments on top.",
          "Credit card debt is money already spent; paying it down comes out of the cash on hand.",
        ],
      };
    })
  );

  registerPlannedItems(server, { query, safe, dateStr, round, today, yearEnd });
  registerGoalsTools(server, { query, safe, round });
  registerBaselineTools(server, { query, today, round, safe });
  server.tool(
    "net_worth_history",
    "Net worth over time from Fico's daily snapshots (taken at 23:55 Manila time): net worth plus cash on hand, savings, investments, credit card owed, debts and money lent out at each point, ready to chart. Weekly and monthly use the last snapshot in each period. Also returns the change over the range.",
    {
      from: dateStr.optional().describe("Inclusive start, YYYY-MM-DD, default 90 days ago"),
      until: dateStr.optional().describe("Inclusive end, YYYY-MM-DD, default today"),
      interval: z.enum(["daily", "weekly", "monthly"]).default("daily"),
    },
    safe(async ({ from, until, interval }) => {
      const end = until ?? today();
      const start = from ?? new Date(Date.parse(end) - 90 * 86400000).toISOString().slice(0, 10);
      const unit = { daily: "day", weekly: "week", monthly: "month" }[interval];
      const rows = await query(
        `SELECT DISTINCT ON (date_trunc($5, s.snapshot_date::timestamp))
                s.snapshot_date AS date, s.net_worth, s.cash_on_hand, s.savings, s.investments,
                s.credit_card_owed, s.debts_owed, s.lent_out, s.investments_stale
         FROM public.net_worth_snapshots s
         WHERE s.owner_id = $1 AND s.snapshot_date BETWEEN $3::date AND LEAST($4::date, ${TODAY})
         ORDER BY date_trunc($5, s.snapshot_date::timestamp), s.snapshot_date DESC`,
        [start, end, unit]
      );
      const points = rows.map((r) => ({
        ...r,
        net_worth: round(r.net_worth),
        cash_on_hand: round(r.cash_on_hand),
        savings: round(r.savings),
        investments: round(r.investments),
        credit_card_owed: round(r.credit_card_owed),
        debts_owed: round(r.debts_owed),
        lent_out: round(r.lent_out),
        investments_stale: r.investments_stale || undefined,
      }));
      const first = points[0];
      const last = points[points.length - 1];
      return {
        from: start,
        until: end,
        interval,
        points,
        change: first
          ? {
              from_date: first.date,
              to_date: last.date,
              amount: round(last.net_worth - first.net_worth),
              percent: first.net_worth ? round(((last.net_worth - first.net_worth) / Math.abs(first.net_worth)) * 100) : null,
            }
          : null,
        notes: [
          "Net worth = cash on hand + savings + investments + lent out - credit card owed - debts, the same as accounts_overview.",
          "investments_stale marks points where a crypto price was more than 2 hours old when the snapshot was taken.",
          ...(points.length ? [] : ["No snapshots in this range yet. They start on the day the snapshot job was set up."]),
        ],
      };
    })
  );

  return server;
}

// ---------- HTTP wrapper ----------
// Two ways to authenticate, both with the same secret:
//   POST /mcp/<token>                           for Claude's custom connector form
//   POST /mcp with Authorization: Bearer <token> for clients that send headers
const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "1mb" }));

const tokenOk = (given: string) => {
  const a = Buffer.from(given);
  const b = Buffer.from(AUTH_TOKEN);
  return a.length === b.length && timingSafeEqual(a, b);
};

function auth(req: Request, res: Response, next: NextFunction) {
  const header = req.header("authorization") ?? "";
  const given = req.params.token ?? (header.startsWith("Bearer ") ? header.slice(7) : "");
  if (!tokenOk(given)) {
    res.status(401).json({ error: "unauthorized" });
    return;
  }
  next();
}

app.get("/health", (_req, res) => res.json({ ok: true }));

// Stateless Streamable HTTP: a fresh server + transport per request.
async function handleMcp(req: Request, res: Response) {
  const server = buildServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => {
    transport.close();
    server.close();
  });
  try {
    await server.connect(transport);
    await transport.handleRequest(req, res, req.body);
  } catch (e) {
    console.error("MCP request failed:", e);
    if (!res.headersSent) {
      res.status(500).json({
        jsonrpc: "2.0",
        error: { code: -32603, message: "Internal server error" },
        id: null,
      });
    }
  }
}

const methodNotAllowed = (_req: Request, res: Response) => {
  res.status(405).json({
    jsonrpc: "2.0",
    error: { code: -32000, message: "Method not allowed." },
    id: null,
  });
};

for (const path of ["/mcp", "/mcp/:token"]) {
  app.post(path, auth, handleMcp);
  app.get(path, auth, methodNotAllowed);
  app.delete(path, auth, methodNotAllowed);
}

const port = Number(env("PORT", "3000"));
app.listen(port, () => console.log(`fico-mcp listening on :${port}`));
