// Sends bill reminders as web-push notifications.
//
// Two ways in:
//  - Scheduled (daily): called with the header `x-cron-secret: <CRON_SECRET>`. Builds one digest per
//    user from their unpaid bills that are overdue or due within their reminder window.
//  - Test: a signed-in user calls it with { "test": true } and gets a test notification on their
//    own devices.
//
// Secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:you@example.com), CRON_SECRET.
import webpush from "npm:web-push@3";
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { supabaseAdmin } from "../_shared/supabase-admin.ts";

type Subscription = { id: string; owner_id: string; endpoint: string; p256dh: string; auth: string };
type Payload = { title: string; body: string; url: string; tag: string };

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

async function sendTo(db: ReturnType<typeof supabaseAdmin>, subs: Subscription[], payload: Payload) {
  let sent = 0;
  for (const sub of subs) {
    try {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
        JSON.stringify(payload),
      );
      sent++;
    } catch (err) {
      const status = (err as { statusCode?: number }).statusCode;
      // 404/410 mean the device unsubscribed or the app was removed: forget it.
      if (status === 404 || status === 410) await db.from("push_subscriptions").delete().eq("id", sub.id);
    }
  }
  return sent;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const db = supabaseAdmin();
  const body = await req.json().catch(() => ({}));

  // --- Test notification for the signed-in user ---
  if (body?.test) {
    const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: auth } = await db.auth.getUser(token);
    if (!auth.user) return jsonResponse({ error: "Not signed in" }, 401);
    const { data: subs } = await db.from("push_subscriptions").select("*").eq("owner_id", auth.user.id);
    const sent = await sendTo(db, subs ?? [], {
      title: "Fico reminders are on",
      body: "You will get a heads up here when bills are due.",
      url: "/bills",
      tag: "fico-test",
    });
    return jsonResponse({ sent });
  }

  // --- Scheduled digest ---
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) {
    return jsonResponse({ error: "Forbidden" }, 403);
  }

  const { data: bills, error } = await db
    .from("bills")
    .select("owner_id, name, due_date, reminder_days")
    .eq("type", "bill")
    .eq("status", "active")
    .eq("reminder", true)
    .in("payment_status", ["unpaid", "overdue", "partial"]);
  if (error) return jsonResponse({ error: error.message }, 500);

  const now = Date.now();
  const day = 86_400_000;
  const perUser = new Map<string, { overdue: string[]; soon: string[] }>();
  for (const bill of bills ?? []) {
    const daysLeft = Math.ceil((new Date(bill.due_date).getTime() - now) / day);
    const window = bill.reminder_days ?? 3;
    if (daysLeft > window) continue;
    const entry = perUser.get(bill.owner_id) ?? { overdue: [], soon: [] };
    (daysLeft < 0 ? entry.overdue : entry.soon).push(bill.name);
    perUser.set(bill.owner_id, entry);
  }

  let notified = 0;
  for (const [ownerId, { overdue, soon }] of perUser) {
    const { data: subs } = await db.from("push_subscriptions").select("*").eq("owner_id", ownerId);
    if (!subs?.length) continue;
    const parts: string[] = [];
    if (overdue.length) parts.push(`${overdue.length} overdue (${overdue.slice(0, 2).join(", ")}${overdue.length > 2 ? "…" : ""})`);
    if (soon.length) parts.push(`${soon.length} due soon (${soon.slice(0, 2).join(", ")}${soon.length > 2 ? "…" : ""})`);
    notified += await sendTo(db, subs, {
      title: overdue.length ? "Bills need attention" : "Bills coming up",
      body: parts.join(" and "),
      url: "/bills",
      tag: "fico-bills",
    });
  }
  return jsonResponse({ users: perUser.size, notified });
});
