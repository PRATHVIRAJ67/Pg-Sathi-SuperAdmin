# Edge Functions

No Edge Functions are deployed yet. Everything the MVP needs runs as Postgres
functions called through the Data API (see `../migrations`). No cron jobs,
queues or schedulers exist; this is intentional for the MVP.

## Planned (online payments phase)

| Function | Purpose | Secrets (function env only) |
| --- | --- | --- |
| `razorpay-create-order` | Re-reads the invoice balance from the database, creates a Razorpay order, inserts a `payments` row with `source = 'gateway'` and `status = 'pending'`. | `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `SUPABASE_SERVICE_ROLE_KEY` |
| `razorpay-webhook` | Verifies `X-Razorpay-Signature` (HMAC-SHA256 of the raw body with the webhook secret), then marks the payment `succeeded` with `gateway_verified_at`, allocates it, and writes an audit log entry. Replays are no-ops because `(gateway_provider, gateway_payment_id)` is unique. | `RAZORPAY_WEBHOOK_SECRET`, `SUPABASE_SERVICE_ROLE_KEY` |

These rules are already enforced by the schema (`payments` CHECK constraints):

- a manual payment can never carry gateway fields;
- a gateway payment can only be `succeeded` when `gateway_verified_at` is set.

A frontend callback must never mark anything as paid; it should only refresh
data. The TypeScript contract lives in `packages/api-client/src/gateway.ts`.

Set function secrets with `supabase secrets set NAME=value`. Never put them in
`VITE_*` or `EXPO_PUBLIC_*` variables: those are bundled into client code.
