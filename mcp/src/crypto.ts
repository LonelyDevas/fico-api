// Live crypto valuation. A crypto holding is worth quantity × the CoinGecko price in its own
// currency (PHP), looked up by coin_id, or by coin_symbol when no id was saved. principal_amount
// stays the cost basis. Coins CoinGecko can't price (it often rate-limits shared hosts) are asked of
// Coinbase's public exchange rates by ticker. If both fail, the holding keeps its last known value:
// the last price this server saw, else the price Fico's crypto-prices job stored, else the price
// implied by the saved value (current_value ÷ quantity, as of when the row was saved). It is flagged
// stale with that time, and never reset to the principal or to zero. This only reads; nothing is written.

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

const FRESH_MS = 60_000;
const API_KEY = (process.env.COINGECKO_KEY ?? "").trim();

type Price = { price: number; at: number };
// Last good price per "coin:currency", kept for the life of the process.
const lastPrices = new Map<string, Price>();

export type Holding = {
  type: string;
  currency: string;
  quantity: number | null;
  coin_id: string | null;
  coin_symbol: string | null;
  current_value: number;
  // Written by the crypto-prices job (migration 0049); read through to_jsonb so they may be absent.
  stored_price: number | null;
  stored_priced_at: string | null;
  // When the row was last saved, for the implied-price fallback.
  saved_at?: string | null;
};

export type Valued = {
  current_value: number;
  price: number | null;
  priced_at: string | null;
  stale: boolean;
  /** Where the price came from: live, job (crypto-prices job), saved (current_value ÷ quantity). */
  price_source?: "live" | "job" | "saved";
};

const ID_SYMBOLS = Object.fromEntries(Object.entries(SYMBOL_IDS).map(([sym, id]) => [id, sym]));
const tickerOf = (id: string, symbol?: string | null) => (symbol || ID_SYMBOLS[id] || "").toUpperCase();

const coinOf = (h: Holding) => h.coin_id || SYMBOL_IDS[(h.coin_symbol ?? "").toUpperCase()] || null;
const isPriced = (h: Holding) => h.type === "crypto" && Number(h.quantity) > 0 && !!coinOf(h);

async function refresh(ids: string[], vs: string) {
  const missing = ids.filter((id) => Date.now() - (lastPrices.get(`${id}:${vs}`)?.at ?? 0) >= FRESH_MS);
  if (!missing.length) return;
  const params = new URLSearchParams({ ids: missing.join(","), vs_currencies: vs });
  if (API_KEY) params.set("x_cg_demo_api_key", API_KEY);
  const res = await fetch(`https://api.coingecko.com/api/v3/simple/price?${params}`, {
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) throw new Error(`CoinGecko ${res.status}`);
  const json = (await res.json()) as Record<string, Record<string, number>>;
  const at = Date.now();
  for (const id of missing) {
    const price = json[id]?.[vs];
    if (typeof price === "number" && price > 0) lastPrices.set(`${id}:${vs}`, { price, at });
  }
}

// Coinbase's public rates, one request per ticker: { data: { rates: { PHP: "3512345.67", ... } } }.
async function coinbasePrice(ticker: string, vs: string): Promise<number | null> {
  if (!ticker) return null;
  const res = await fetch(`https://api.coinbase.com/v2/exchange-rates?currency=${encodeURIComponent(ticker)}`, {
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) return null;
  const json = (await res.json()) as { data?: { rates?: Record<string, string> } };
  const price = Number(json.data?.rates?.[vs.toUpperCase()]);
  return price > 0 ? price : null;
}

async function refreshWithFallback(ids: string[], vs: string, tickers: Map<string, string>) {
  await refresh(ids, vs).catch((e) => console.warn(`CoinGecko (${vs}): ${(e as Error).message}`));
  const left = ids.filter((id) => Date.now() - (lastPrices.get(`${id}:${vs}`)?.at ?? 0) >= FRESH_MS);
  await Promise.all(
    left.map(async (id) => {
      const price = await coinbasePrice(tickers.get(id) ?? "", vs).catch(() => null);
      if (price) lastPrices.set(`${id}:${vs}`, { price, at: Date.now() });
    })
  );
}

/** Current value of each holding, in the same order. Non-crypto rows keep their stored value. */
export async function valueHoldings(rows: Holding[]): Promise<Valued[]> {
  const byCurrency = new Map<string, Set<string>>();
  const tickers = new Map<string, string>();
  for (const h of rows.filter(isPriced)) {
    const vs = (h.currency || "PHP").toLowerCase();
    const id = coinOf(h)!;
    byCurrency.set(vs, (byCurrency.get(vs) ?? new Set()).add(id));
    tickers.set(id, tickerOf(id, h.coin_symbol));
  }
  await Promise.all([...byCurrency].map(([vs, ids]) => refreshWithFallback([...ids].sort(), vs, tickers)));

  return rows.map((h) => {
    const stored = { current_value: h.current_value, price: h.stored_price, priced_at: h.stored_priced_at };
    if (!isPriced(h)) return { ...stored, stale: false };
    const quantity = Number(h.quantity);
    const known = lastPrices.get(`${coinOf(h)}:${(h.currency || "PHP").toLowerCase()}`);
    const storedAt = h.stored_priced_at ? Date.parse(h.stored_priced_at) : 0;
    const storedPrice = Number(h.stored_price);
    if (known && known.at >= storedAt) {
      return {
        current_value: Math.round(quantity * known.price * 100) / 100,
        price: known.price,
        priced_at: new Date(known.at).toISOString(),
        stale: Date.now() - known.at >= FRESH_MS,
        price_source: "live",
      };
    }
    if (storedPrice > 0 && storedAt) {
      return {
        current_value: Math.round(quantity * storedPrice * 100) / 100,
        price: storedPrice,
        priced_at: h.stored_priced_at,
        stale: true,
        price_source: "job",
      };
    }
    // Never priced: the value saved on the row is all we know.
    const implied = Number(h.current_value) / quantity;
    return {
      current_value: Number(h.current_value),
      price: implied > 0 ? implied : null,
      priced_at: h.saved_at ?? null,
      stale: true,
      price_source: "saved",
    };
  });
}
