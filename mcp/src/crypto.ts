// Live crypto valuation. A crypto holding is worth quantity × the CoinGecko price in its own
// currency (PHP), looked up by coin_id, or by coin_symbol when no id was saved. principal_amount
// stays the cost basis. If CoinGecko can't be reached, the holding keeps its last known value
// (the last price this server saw, or the value Fico's crypto-prices job stored) and is flagged
// stale. It is never reset to the principal or to zero. This only reads; nothing is written.

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
};

export type Valued = {
  current_value: number;
  price: number | null;
  priced_at: string | null;
  stale: boolean;
};

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

/** Current value of each holding, in the same order. Non-crypto rows keep their stored value. */
export async function valueHoldings(rows: Holding[]): Promise<Valued[]> {
  const byCurrency = new Map<string, Set<string>>();
  for (const h of rows.filter(isPriced)) {
    const vs = (h.currency || "PHP").toLowerCase();
    byCurrency.set(vs, (byCurrency.get(vs) ?? new Set()).add(coinOf(h)!));
  }
  await Promise.all(
    [...byCurrency].map(([vs, ids]) =>
      refresh([...ids].sort(), vs).catch((e) => console.warn(`Crypto prices (${vs}): ${(e as Error).message}`))
    )
  );

  return rows.map((h) => {
    const stored = {
      current_value: h.current_value,
      price: h.stored_price,
      priced_at: h.stored_priced_at,
    };
    if (!isPriced(h)) return { ...stored, stale: false };
    const known = lastPrices.get(`${coinOf(h)}:${(h.currency || "PHP").toLowerCase()}`);
    const storedAt = h.stored_priced_at ? Date.parse(h.stored_priced_at) : 0;
    if (!known || known.at < storedAt) return { ...stored, stale: true };
    return {
      current_value: Math.round(Number(h.quantity) * known.price * 100) / 100,
      price: known.price,
      priced_at: new Date(known.at).toISOString(),
      stale: Date.now() - known.at >= FRESH_MS,
    };
  });
}
