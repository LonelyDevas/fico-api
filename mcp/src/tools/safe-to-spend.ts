import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

// Helpers from server.ts, passed in so this tool reads data the same way the others do.
export type ToolDeps = {
  query: (sql: string, params?: unknown[]) => Promise<any[]>;
  scheduled: (until: string) => Promise<{ items: any[]; totals: Record<string, number> }>;
  safe: <A>(fn: (args: A) => Promise<unknown>) => (args: A) => Promise<any>;
  today: () => string;
  dayBefore: (date: string) => string;
  round: (n: number) => number;
  dateStr: z.ZodString;
  TODAY: string;
};

// Cash on hand minus bills due before the next salary, spread over the days left.
export function registerSafeToSpend(
  server: McpServer,
  { query, scheduled, safe, today, dayBefore, round, dateStr, TODAY }: ToolDeps
) {
  server.tool(
    "safe_to_spend",
    "How much can be spent from now until a date (default: the next salary on Fico's Bills page): cash on hand (bank, cash and e-wallets, not savings or credit cards) minus unpaid bills due before that date, spread over the days left. Also gives a per-day number after keeping a buffer (default 20%).",
    {
      until: dateStr.optional().describe("YYYY-MM-DD, default the next expected salary"),
      buffer_percent: z.number().min(0).max(90).default(20).describe("Share of the available money to keep aside"),
    },
    safe(async ({ until, buffer_percent }) => {
      const now = today();
      let end = until;
      let untilSource = "given";
      if (!end) {
        // Next unpaid income on the Bills page, preferring ones named or categorized as salary.
        const [next] = await query(
          `SELECT b.name, (b.due_date AT TIME ZONE $2)::date AS due_date
           FROM public.bills b LEFT JOIN public.categories c ON c.id = b.category_id
           WHERE b.owner_id = $1 AND b.status = 'active' AND b.type = 'income'
             AND b.payment_status NOT IN ('paid', 'received')
             AND (b.due_date AT TIME ZONE $2)::date > ${TODAY}
           ORDER BY (b.name ILIKE '%salary%' OR c.name ILIKE '%salary%') DESC, b.due_date
           LIMIT 1`
        );
        if (next) {
          end = next.due_date as string;
          untilSource = `next income on the Bills page: ${next.name}`;
        } else {
          const [y, m] = now.split("-").map(Number);
          end = new Date(Date.UTC(y, m, 0)).toISOString().slice(0, 10);
          untilSource = "end of this month (no upcoming income on the Bills page)";
        }
      }
      if (end <= now) throw new Error(`until must be after today (${now})`);

      const wallets = await query(
        `SELECT name, type::text AS type, balance FROM public.wallets
         WHERE owner_id = $1 AND status = 'active' AND type::text NOT IN ('savings', 'credit_card')
         ORDER BY balance DESC`
      );
      const cash = round(wallets.reduce((s, w) => s + w.balance, 0));
      const sched = await scheduled(dayBefore(end));
      const bills = sched.items.filter((x) => x.kind === "bill");
      const billsTotal = round(bills.reduce((s, x) => s + x.amount, 0));
      const daysLeft = Math.round((Date.parse(end) - Date.parse(now)) / 86400000);
      const available = round(cash - billsTotal);
      const buffer = round(Math.max(0, available) * (buffer_percent / 100));
      const afterBuffer = round(available - buffer);
      return {
        today: now,
        until: end,
        until_source: untilSource,
        days_left: daysLeft,
        cash_on_hand: cash,
        wallets,
        bills_due_before_until: bills.map(({ date, name, amount, wallet, overdue }) => ({ date, name, amount, wallet, overdue })),
        bills_total: billsTotal,
        available,
        per_day: round(available / daysLeft),
        buffer: { percent: buffer_percent, amount: buffer },
        available_after_buffer: afterBuffer,
        per_day_after_buffer: round(afterBuffer / daysLeft),
        expected_income_before_until: sched.totals.income,
        notes: [
          "Bills due on the until date itself are left out, since the salary is expected that day.",
          "Income expected before the until date is not added to available; it is shown separately.",
          ...(available < 0 ? ["Bills due before the date are more than the cash on hand."] : []),
        ],
      };
    })
  );
}
