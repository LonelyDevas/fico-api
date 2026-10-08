// Sends each user a short spending update as a web-push notification.
//
// Called by pg_cron with the header `x-cron-secret: <CRON_SECRET>` (see scripts/schedule-spending-digest.sql).
// Only users who turned on notifications (they have a push_subscriptions row) are sent one.
// "Today" and "this month" follow Manila time (UTC+8).
//
// Secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT, CRON_SECRET (shared with bill-reminders).
import webpush from "npm:web-push@3";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { supabaseAdmin } from "../_shared/supabase-admin.ts";

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

const OFFSET_MS = 8 * 3_600_000; // Manila
const money = (n: number) => "₱" + Math.round(n).toLocaleString("en-US");

// Midnight (Manila) as a UTC instant, for a Manila-local date.
const manilaMidnight = (y: number, m: number, d: number) => new Date(Date.UTC(y, m, d) - OFFSET_MS);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) {
    return jsonResponse({ error: "Forbidden" }, 403);
  }

  const db = supabaseAdmin();
  const local = new Date(Date.now() + OFFSET_MS);
  const y = local.getUTCFullYear();
  const m = local.getUTCMonth();
  const d = local.getUTCDate();
  const dayStart = manilaMidnight(y, m, d).getTime();
  const monthStart = manilaMidnight(y, m, 1);
  const daysElapsed = d;

  const { data: subs, error } = await db.from("push_subscriptions").select("*");
  if (error) return jsonResponse({ error: error.message }, 500);

  const byOwner = new Map<string, typeof subs>();
  for (const s of subs ?? []) byOwner.set(s.owner_id, [...(byOwner.get(s.owner_id) ?? []), s]);

  const { data: cats } = await db.from("categories").select("id, name");
  const catName = new Map((cats ?? []).map((c) => [c.id, c.name]));

  let notified = 0;
  for (const [ownerId, devices] of byOwner) {
    const { data: txs } = await db
      .from("transactions")
      .select("amount, date, category_id")
      .eq("owner_id", ownerId)
      .eq("type", "expense")
      .eq("status", "completed")
      .gte("date", monthStart.toISOString());
    if (!txs?.length) continue;

    let today = 0;
    let month = 0;
    const byCat = new Map<string, number>();
    for (const t of txs) {
      const amt = Number(t.amount);
      month += amt;
      if (new Date(t.date).getTime() >= dayStart) {
        today += amt;
        const name = (t.category_id && catName.get(t.category_id)) || "Other";
        byCat.set(name, (byCat.get(name) ?? 0) + amt);
      }
    }
    const top = [...byCat.entries()].sort((a, b) => b[1] - a[1])[0];
    const avg = month / daysElapsed;

    let body = today > 0
      ? `Spent ${money(today)} today${top ? `, mostly ${top[0]} (${money(top[1])})` : ""}.`
      : "Nothing spent yet today.";
    body += ` ${money(month)} so far this month`;
    if (today > 0 && avg > 0) body += today > avg * 1.5 ? " — a heavy day." : ".";
    else body += ".";

    const payload = JSON.stringify({ title: "Your spending", body, url: "/transactions", tag: "fico-spending" });
    for (const sub of devices) {
      try {
        await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, payload);
        notified++;
      } catch (err) {
        const status = (err as { statusCode?: number }).statusCode;
        if (status === 404 || status === 410) await db.from("push_subscriptions").delete().eq("id", sub.id);
      }
    }
  }
  return jsonResponse({ users: byOwner.size, notified });
});
