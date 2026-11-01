// Sends bill reminders as web-push notifications.
//
// Two ways in:
//  - Scheduled (daily, 09:00 Manila; see migrations/0056_schedule_notifications.sql): called with the header `x-cron-secret: <CRON_SECRET>`. Builds one digest per
//    user from their unpaid bills and open debts/loans that are overdue, due within the reminder
//    window, or due in exactly a week.
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

  // Debts and loans with a single due date. Installment ones are reminded through their installment bills.
  const { data: obligations, error: obligationsError } = await db
    .from("obligations")
    .select("owner_id, name, counterparty, direction, due_date")
    .eq("is_installment", false)
    .not("due_date", "is", null)
    .in("status", ["active", "partially_paid"]);
  if (obligationsError) return jsonResponse({ error: obligationsError.message }, 500);

  const now = Date.now();
  const day = 86_400_000;
  // Daily inside the reminder window (and while overdue), plus a one-off heads up a week out.
  const WEEK_AHEAD = 7;
  type Due = { overdue: string[]; soon: string[]; nextWeek: string[] };
  const emptyDue = (): Due => ({ overdue: [], soon: [], nextWeek: [] });
  const perUser = new Map<string, { pay: Due; collect: Due; hasBills: boolean }>();
  const add = (ownerId: string, side: "pay" | "collect", name: string, dueDate: string, window: number, isBill: boolean) => {
    const daysLeft = Math.ceil((new Date(dueDate).getTime() - now) / day);
    const weekAhead = daysLeft === WEEK_AHEAD && window < WEEK_AHEAD;
    if (daysLeft > window && !weekAhead) return;
    const entry = perUser.get(ownerId) ?? { pay: emptyDue(), collect: emptyDue(), hasBills: false };
    const due = entry[side];
    (daysLeft < 0 ? due.overdue : weekAhead ? due.nextWeek : due.soon).push(name);
    entry.hasBills ||= isBill;
    perUser.set(ownerId, entry);
  };
  for (const bill of bills ?? []) add(bill.owner_id, "pay", bill.name, bill.due_date, bill.reminder_days ?? 3, true);
  for (const o of obligations ?? []) {
    // A debt is money the user owes; a lending is money owed to them.
    if (o.direction === "debt") add(o.owner_id, "pay", `${o.name} to ${o.counterparty}`, o.due_date, 3, false);
    else add(o.owner_id, "collect", o.counterparty, o.due_date, 3, false);
  }

  const list = (names: string[]) => `${names.slice(0, 2).join(", ")}${names.length > 2 ? "…" : ""}`;
  let notified = 0;
  for (const [ownerId, { pay, collect, hasBills }] of perUser) {
    const { data: subs } = await db.from("push_subscriptions").select("*").eq("owner_id", ownerId);
    if (!subs?.length) continue;
    const parts: string[] = [];
    if (pay.overdue.length) parts.push(`${pay.overdue.length} overdue (${list(pay.overdue)})`);
    if (pay.soon.length) parts.push(`${pay.soon.length} due soon (${list(pay.soon)})`);
    if (pay.nextWeek.length) parts.push(`${pay.nextWeek.length} due in a week (${list(pay.nextWeek)})`);
    if (collect.overdue.length) parts.push(`overdue to collect from ${list(collect.overdue)}`);
    if (collect.soon.length) parts.push(`soon to collect from ${list(collect.soon)}`);
    if (collect.nextWeek.length) parts.push(`to collect in a week from ${list(collect.nextWeek)}`);
    const overdue = pay.overdue.length + collect.overdue.length > 0;
    notified += await sendTo(db, subs, {
      title: overdue ? "Payments need attention" : "Payments coming up",
      body: parts.join(" and "),
      url: hasBills ? "/bills" : "/debts",
      tag: "fico-bills",
    });
  }
  return jsonResponse({ users: perUser.size, notified });
});
