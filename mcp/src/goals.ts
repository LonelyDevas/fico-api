import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

// The helpers server.ts already has, passed in so this file stays a plain add-on.
interface Deps {
  query: (sql: string, params?: unknown[]) => Promise<any[]>;
  safe: <A>(fn: (args: A) => Promise<unknown>) => (args: A) => Promise<any>;
  round: (n: number) => number;
}

const DAYS_PER_MONTH = 365.25 / 12;

// Savings goals from Fico's Goals page. Saved so far is the live balance of the wallets linked to a
// goal, or of every savings wallet when none are linked (the same rule the app uses).
export function registerGoalsTools(server: McpServer, { query, safe, round }: Deps) {
  server.tool(
    "goals_progress",
    "Savings goals from Fico's Goals page: target, deadline, the wallets that count toward it, saved so far, remaining, months left and the monthly amount needed to reach it on time.",
    {},
    safe(async () => {
      const goals = await query(
        `SELECT g.name, g.target_amount, g.deadline, g.linked_wallet_ids::text[] AS linked_wallet_ids,
                (now() AT TIME ZONE $2)::date AS today
         FROM public.goals g
         WHERE g.owner_id = $1 AND g.status = 'active'
         ORDER BY g.deadline NULLS LAST, g.created_at`
      );
      const wallets = await query(
        `SELECT id::text AS id, name, type::text AS type, balance
         FROM public.wallets WHERE owner_id = $1 AND status = 'active' AND type::text <> 'credit_card'`
      );

      const out = goals.map((g) => {
        const linked: string[] = g.linked_wallet_ids ?? [];
        const counted = linked.length
          ? wallets.filter((w) => linked.includes(w.id))
          : wallets.filter((w) => w.type === "savings");
        const saved = round(counted.reduce((s, w) => s + w.balance, 0));
        const remaining = round(Math.max(0, g.target_amount - saved));
        const daysLeft = g.deadline ? Math.round((Date.parse(g.deadline) - Date.parse(g.today)) / 86400000) : null;
        const monthsLeft = daysLeft === null ? null : round(Math.max(0, daysLeft) / DAYS_PER_MONTH);
        return {
          name: g.name,
          target_amount: round(g.target_amount),
          deadline: g.deadline,
          wallets: counted.map((w) => ({ name: w.name, type: w.type, balance: round(w.balance) })),
          wallets_rule: linked.length ? "linked wallets" : "all savings wallets (none linked)",
          saved_so_far: saved,
          remaining,
          percent: round(Math.min(100, (saved / g.target_amount) * 100)),
          reached: remaining === 0,
          days_left: daysLeft,
          months_left: monthsLeft,
          // Under a month left means the whole remainder is due now.
          monthly_needed: monthsLeft === null ? null : round(remaining / Math.max(1, monthsLeft)),
          past_deadline: daysLeft !== null && daysLeft < 0 && remaining > 0,
        };
      });

      return {
        today: goals[0]?.today ?? null,
        goals: out,
        totals: {
          target: round(out.reduce((s, g) => s + g.target_amount, 0)),
          remaining: round(out.reduce((s, g) => s + g.remaining, 0)),
          monthly_needed: round(out.reduce((s, g) => s + (g.monthly_needed ?? 0), 0)),
        },
        note: "Goals that share a wallet each count its full balance, so don't add their saved amounts together.",
      };
    })
  );
}
