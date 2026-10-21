import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

// What server.ts hands over, so this file reuses its read-only query and helpers.
export interface ToolDeps {
  query: (sql: string, params?: unknown[]) => Promise<any[]>;
  safe: <A>(fn: (args: A) => Promise<unknown>) => (args: A) => Promise<any>;
  dateStr: z.ZodString;
  round: (n: number) => number;
  today: () => string;
  yearEnd: () => string;
}

// Planned items are one-off income and expenses the user expects (13th month pay, gifts, a trip),
// each with a low and a high estimate. Fico's app writes them; this tool only reads.
export function registerPlannedItems(server: McpServer, { query, safe, dateStr, round, today, yearEnd }: ToolDeps) {
  server.tool(
    "planned_items",
    "One-off income and expenses the user expects but that aren't on the Bills page (13th month pay, birthday or Christmas money, trips, visits), each with a low and a high estimate and a status (expected or confirmed). Returns the items between two dates plus totals for a low case (least income, most spending) and a high case (most income, least spending). Add these on top of savings_forecast, which only knows past averages and scheduled bills.",
    {
      from: dateStr.optional().describe("Inclusive start, YYYY-MM-DD, default today"),
      until: dateStr.optional().describe("Inclusive end, YYYY-MM-DD, default December 31 this year"),
      status: z.enum(["expected", "confirmed"]).optional().describe("Only items with this status"),
    },
    safe(async ({ from, until, status }: { from?: string; until?: string; status?: "expected" | "confirmed" }) => {
      const start = from ?? today();
      const end = until ?? yearEnd();
      const rows = await query(
        `SELECT p.date, p.name, p.type, p.amount_low, p.amount_high, p.status, c.name AS category, p.notes
         FROM public.planned_items p LEFT JOIN public.categories c ON c.id = p.category_id
         WHERE p.owner_id = $1 AND p.date BETWEEN COALESCE($3::date, (now() AT TIME ZONE $2)::date) AND $4::date
           AND ($5::text IS NULL OR p.status = $5::text)
         ORDER BY p.date, p.name`,
        [from ?? null, end, status ?? null]
      );
      const sum = (type: string, key: "amount_low" | "amount_high") =>
        round(rows.filter((r) => r.type === type).reduce((s, r) => s + r[key], 0));
      const income = { low: sum("income", "amount_low"), high: sum("income", "amount_high") };
      const expenses = { low: sum("expense", "amount_low"), high: sum("expense", "amount_high") };
      return {
        from: start,
        until: end,
        status: status ?? "all",
        items: rows,
        totals: {
          income,
          expenses,
          low_case_net: round(income.low - expenses.high),
          high_case_net: round(income.high - expenses.low),
        },
        notes: [
          "Amounts are PHP. low_case_net = lowest income minus highest spending; high_case_net = highest income minus lowest spending.",
          "Expected items may not happen; pass status 'confirmed' for only the sure ones.",
        ],
      };
    })
  );
}
