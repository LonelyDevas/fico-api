# fico-mcp

Read-only MCP server that lets Claude read your Fico data (wallets, transactions,
bills, budgets, debts, investments) straight from Fico's Supabase database and
help you plan savings. It is built for Fico's real schema (the migrations in
`../supabase/migrations`), so there is no column mapping to configure.

## Tools

| Tool | What it gives Claude |
| --- | --- |
| `accounts_overview` | Every wallet and balance, plus cash on hand, savings, credit card owed, investments, debts and net worth. |
| `get_transactions` | Completed transactions in a date range, with category and wallet names. Filter by type, category, wallet or text. |
| `monthly_summary` | Income, expenses, net and savings rate per month. Transfers between your wallets are left out. |
| `category_breakdown` | Spend (or income) per category with percentages. |
| `spending_trends` | Each category's spend per month, its average, whether it is rising, and this month so far. |
| `top_expenses` | Biggest single expenses, and repeated purchases that add up. |
| `upcoming_bills` | Unpaid bills and expected income up to a date, recurring ones projected forward, plus your recurring costs per month. |
| `budgets_status` | Active budgets: limit, spent, left, percent used. |
| `debts_and_loans` | Money you owe and money you lent, with installments and due dates. |
| `investments` | Investments with amount in, current value and gain. |
| `savings_forecast` | How much you can save by a date (default next January 1), with the inputs behind the number. |

How it reads Fico's data: only `completed` transactions count (pending rows are
future bill payments, cancelled ones never happened), income and expense come
from the `type` column, transfers are excluded from income and spending, and a
credit card's balance is treated as money owed. Months are counted in
`FICO_TIMEZONE` (default Asia/Manila).

## 1. Create the read-only database role

Open `readonly-role.sql`, put in your Fico username and a new password, and run
it in the Supabase SQL editor. It prints your user id, which is `FICO_OWNER_ID`. The role can only `SELECT`, and row level security
limits it to your own rows, so it can't see other Fico users or change anything.

## 2. Configure and test locally (optional)

```bash
cp .env.example .env     # fill in the required values
npm install
npm run build
set -a; . ./.env; set +a
npm start
curl -s localhost:3000/health
curl -s -X POST localhost:3000/mcp/$MCP_AUTH_TOKEN \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## 3. Deploy on Render (same as the Fico backend)

In Render choose New > Blueprint, pick the `fico-api` repo and set the
Blueprint path to `mcp/render.yaml`. It creates a separate `fico-mcp` service
(root directory `mcp/`), so the main API is untouched. Render asks
for `SUPABASE_PROJECT_REF`, `FICO_DB_PASSWORD` and `FICO_OWNER_ID` and generates `MCP_AUTH_TOKEN` for you
(copy it from the service's Environment tab). You get a URL like
`https://fico-mcp.onrender.com`.

## 4. Connect to Claude

Claude > Settings > Connectors > Add custom connector:

- Name: `Fico`
- URL: `https://YOUR-HOST/mcp/YOUR_MCP_AUTH_TOKEN`
- Leave the OAuth fields empty.

The secret in the URL is the password. Claude's form only lets most accounts
add a URL (custom request headers are a limited beta), so the server accepts the
token in the path. `Authorization: Bearer <token>` on `/mcp` also works for
clients that can send headers.

## Security notes

- Anyone with the full connector URL can read your finances. Don't paste it anywhere else.
- To revoke access, change `MCP_AUTH_TOKEN` on Render and re-add the connector with the new URL.
- Every query also runs in a READ ONLY transaction with an 8 second timeout.
- Render's free tier sleeps when idle, so the first call after a pause can take ~30 seconds.
