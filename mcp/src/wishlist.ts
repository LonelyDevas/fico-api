import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

// The helpers server.ts already has, passed in so this file stays a plain add-on.
interface Deps {
  query: (sql: string, params?: unknown[]) => Promise<any[]>;
  safe: <A>(fn: (args: A) => Promise<unknown>) => (args: A) => Promise<any>;
  round: (n: number) => number;
}

const DAYS_PER_MONTH = 365.25 / 12;
const PRIORITY_LABEL: Record<string, string> = { need: "Need it", want: "Want it", someday: "Someday" };

// Wishlist from Fico's Wishlist page: things the user wants to buy, with a price, how much they
// want it and an optional "want it by" date. Fico's app writes them; this tool only reads.
export function registerWishlist(server: McpServer, { query, safe, round }: Deps) {
  server.tool(
    "wishlist",
    "Things the user wants to buy, from Fico's Wishlist page: name, price, priority (need, want or someday), an optional want-it-by date with the monthly amount to set aside to get there, link and note. By default lists what is still wanted, with totals per priority; pass status 'bought' or 'all' to see what was already bought. Pair with safe_to_spend or savings_forecast to say what is affordable and when.",
    {
      status: z.enum(["wanted", "bought", "all"]).default("wanted").describe("Which items, default the ones still wanted"),
      priority: z.enum(["need", "want", "someday"]).optional().describe("Only items with this priority"),
    },
    safe(async ({ status, priority }: { status: "wanted" | "bought" | "all"; priority?: "need" | "want" | "someday" }) => {
      const rows = await query(
        `SELECT w.name, w.price, w.priority, w.status, w.target_date, w.bought_on, w.url, w.notes,
                w.created_at::date AS added_on, (now() AT TIME ZONE $2)::date AS today
         FROM public.wishlist_items w
         WHERE w.owner_id = $1 AND ($3::text = 'all' OR w.status = $3::text)
           AND ($4::text IS NULL OR w.priority = $4::text)
         ORDER BY w.status DESC, array_position(array['need','want','someday'], w.priority),
                  w.target_date NULLS LAST, w.created_at`,
        [status ?? "wanted", priority ?? null]
      );
      const today: string | null = rows[0]?.today ?? null;

      const items = rows.map((r) => {
        const wanted = r.status === "wanted";
        const daysLeft = wanted && r.target_date ? Math.round((Date.parse(r.target_date) - Date.parse(r.today)) / 86400000) : null;
        const monthsLeft = daysLeft === null ? null : round(Math.max(0, daysLeft) / DAYS_PER_MONTH);
        return {
          name: r.name,
          price: round(r.price),
          priority: r.priority,
          priority_label: PRIORITY_LABEL[r.priority] ?? r.priority,
          status: r.status,
          want_by: r.target_date,
          days_left: daysLeft,
          // Under a month left means the whole price is due now.
          monthly_to_set_aside: monthsLeft === null ? null : round(r.price / Math.max(1, monthsLeft)),
          past_want_by: daysLeft !== null && daysLeft < 0,
          bought_on: r.bought_on,
          added_on: r.added_on,
          url: r.url,
          notes: r.notes,
        };
      });

      const wanted = items.filter((i) => i.status === "wanted");
      const total = (list: typeof items) => round(list.reduce((s, i) => s + i.price, 0));
      return {
        today,
        status: status ?? "wanted",
        items,
        totals: {
          wanted: total(wanted),
          by_priority: {
            need: total(wanted.filter((i) => i.priority === "need")),
            want: total(wanted.filter((i) => i.priority === "want")),
            someday: total(wanted.filter((i) => i.priority === "someday")),
          },
          monthly_to_set_aside: round(wanted.reduce((s, i) => s + (i.monthly_to_set_aside ?? 0), 0)),
          bought: total(items.filter((i) => i.status === "bought")),
        },
        notes: [
          "Amounts are PHP. Wishlist items are wishes, not bills: they are not in savings_forecast or upcoming_bills.",
          "monthly_to_set_aside only covers items with a want-by date.",
        ],
      };
    })
  );
}
