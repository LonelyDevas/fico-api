// Revalues every active crypto holding at the live CoinGecko price: current_value = quantity × price.
//
// Called by pg_cron with the header `x-cron-secret: <CRON_SECRET>` every 30 minutes (scheduled in
// migrations/0070_schedule_crypto_prices.sql).
// One CoinGecko request per currency covers every holding. Coins CoinGecko leaves out (or all of
// them, when it rate-limits) are asked of Coinbase's public exchange rates by ticker. If both fail, or a coin has no
// price, those rows are left as they are, so current_value keeps the last known value and
// price_updated_at shows how old it is. principal_amount (the cost basis) is never touched.
// The first good price of each Manila day is also saved as a value snapshot, so the app can work out
// returns over Today, 1W, 1M and so on for crypto too.
//
// Secrets: CRON_SECRET (shared with bill-reminders), optional COINGECKO_KEY (free demo key).
import { corsHeaders, jsonResponse } from "../_shared/cors.ts";
import { supabaseAdmin } from "../_shared/supabase-admin.ts";

// Ticker to CoinGecko id, for holdings saved without a coin_id.
const SYMBOL_IDS: Record<string, string> = {
  BTC: "bitcoin", ETH: "ethereum", BNB: "binancecoin", USDT: "tether", USDC: "usd-coin",
  SOL: "solana", XRP: "ripple", DOGE: "dogecoin", ADA: "cardano", TRX: "tron",
  TON: "the-open-network", AVAX: "avalanche-2", SHIB: "shiba-inu", DOT: "polkadot",
  LINK: "chainlink", POL: "polygon-ecosystem-token", LTC: "litecoin", BCH: "bitcoin-cash",
  UNI: "uniswap", XLM: "stellar", NEAR: "near", ZRO: "layerzero", CAKE: "pancakeswap-token",
  DAI: "dai", APT: "aptos", ARB: "arbitrum", OP: "optimism", SUI: "sui", PEPE: "pepe",
  ICP: "internet-computer", ATOM: "cosmos", XMR: "monero", FIL: "filecoin",
  HBAR: "hedera-hashgraph", AAVE: "aave", MKR: "maker", ETC: "ethereum-classic",
  ALGO: "algorand", VET: "vechain", INJ: "injective-protocol",
};

const coinOf = (h: { coin_id: string | null; coin_symbol: string | null }) =>
  h.coin_id || SYMBOL_IDS[(h.coin_symbol ?? "").toUpperCase()] || null;
const ID_SYMBOLS = Object.fromEntries(Object.entries(SYMBOL_IDS).map(([sym, id]) => [id, sym]));
const tickerOf = (h: { coin_id: string | null; coin_symbol: string | null }) =>
  (h.coin_symbol || ID_SYMBOLS[coinOf(h) ?? ""] || "").toUpperCase();

// Coinbase's public rates for one ticker: { data: { rates: { PHP: "3512345.67", ... } } }.
async function coinbasePrice(ticker: string, vs: string): Promise<number | null> {
  if (!ticker) return null;
  try {
    const res = await fetch(`https://api.coinbase.com/v2/exchange-rates?currency=${encodeURIComponent(ticker)}`);
    if (!res.ok) return null;
    const json = (await res.json()) as { data?: { rates?: Record<string, string> } };
    const price = Number(json.data?.rates?.[vs.toUpperCase()]);
    return price > 0 ? price : null;
  } catch {
    return null;
  }
}

async function fetchPrices(ids: string[], vs: string): Promise<Record<string, number>> {
  const params = new URLSearchParams({ ids: ids.join(","), vs_currencies: vs });
  const key = Deno.env.get("COINGECKO_KEY");
  if (key) params.set("x_cg_demo_api_key", key);
  const res = await fetch(`https://api.coingecko.com/api/v3/simple/price?${params}`);
  if (!res.ok) throw new Error(`CoinGecko ${res.status}`);
  const json = (await res.json()) as Record<string, Record<string, number>>;
  const prices: Record<string, number> = {};
  for (const id of ids) {
    const price = json[id]?.[vs];
    if (typeof price === "number" && price > 0) prices[id] = price;
  }
  return prices;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) {
    return jsonResponse({ error: "Forbidden" }, 403);
  }

  const db = supabaseAdmin();
  const { data: holdings, error } = await db
    .from("investments")
    .select("id, currency, coin_id, coin_symbol, quantity")
    .eq("type", "crypto")
    .eq("status", "active")
    .gt("quantity", 0);
  if (error) return jsonResponse({ error: error.message }, 500);

  const byCurrency = new Map<string, typeof holdings>();
  for (const h of holdings ?? []) {
    if (!coinOf(h)) continue;
    const vs = (h.currency || "PHP").toLowerCase();
    byCurrency.set(vs, [...(byCurrency.get(vs) ?? []), h]);
  }

  // Holdings that already have a snapshot today (Manila), so only the first run of the day adds one.
  const manilaMidnight = new Date(Math.floor((Date.now() + 8 * 3_600_000) / 86_400_000) * 86_400_000 - 8 * 3_600_000);
  const { data: todays } = await db
    .from("investment_value_snapshots")
    .select("investment_id")
    .in("investment_id", (holdings ?? []).map((h) => h.id))
    .gte("snapshot_date", manilaMidnight.toISOString());
  const snappedToday = new Set((todays ?? []).map((r) => r.investment_id));

  let updated = 0;
  let snapshots = 0;
  const failed: string[] = [];
  for (const [vs, rows] of byCurrency) {
    let prices: Record<string, number> = {};
    try {
      prices = await fetchPrices([...new Set(rows.map((h) => coinOf(h)!))].sort(), vs);
    } catch (err) {
      failed.push(`${vs}: ${(err as Error).message}, trying Coinbase`);
    }
    for (const h of rows) {
      const id = coinOf(h)!;
      if (prices[id]) continue;
      const price = await coinbasePrice(tickerOf(h), vs);
      if (price) prices[id] = price;
    }
    const now = new Date().toISOString();
    for (const h of rows) {
      const price = prices[coinOf(h)!];
      if (!price) {
        failed.push(`${h.id}: no ${vs} price for ${coinOf(h)}`);
        continue;
      }
      const { error: updateError } = await db
        .from("investments")
        .update({
          current_value: Math.round(Number(h.quantity) * price * 100) / 100,
          last_price: price,
          price_updated_at: now,
        })
        .eq("id", h.id);
      if (updateError) {
        failed.push(`${h.id}: ${updateError.message}`);
        continue;
      }
      updated++;
      if (!snappedToday.has(h.id)) {
        const { error: snapError } = await db.from("investment_value_snapshots").insert({
          investment_id: h.id,
          value: Math.round(Number(h.quantity) * price * 100) / 100,
          snapshot_date: now,
          notes: "Daily price",
        });
        if (snapError) failed.push(`${h.id} snapshot: ${snapError.message}`);
        else snapshots++;
      }
    }
  }
  return jsonResponse({ holdings: holdings?.length ?? 0, updated, snapshots, failed });
});
