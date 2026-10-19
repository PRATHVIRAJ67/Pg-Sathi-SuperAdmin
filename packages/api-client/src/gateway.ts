/**
 * Contract for the future online-payment phase (Razorpay). NOTHING here is
 * implemented or wired into the apps yet — today every payment is recorded
 * manually and stored with source = 'manual'.
 *
 * The database is already prepared:
 *   payments.source       'manual' | 'gateway'
 *   payments.status       gateway rows use pending | succeeded | failed | refunded
 *   payments.gateway_*    provider, order id, payment id, verified_at
 *   CHECK constraints     a 'succeeded' row must have gateway_verified_at, and
 *                         manual rows can never carry gateway fields
 *   UNIQUE                (gateway_provider, gateway_payment_id) → webhook
 *                         replays cannot create duplicates
 *
 * Planned server-side flow (Supabase Edge Functions, secrets in function env):
 *   1. create-order:  authenticated owner/resident asks to pay invoice X.
 *      The function re-reads the invoice balance from the DB (never trusts the
 *      client amount), creates a Razorpay order with the server key, inserts a
 *      payments row (source=gateway, status=pending, gateway_order_id).
 *   2. Client opens Razorpay Checkout with the order id only.
 *   3. webhook:  verifies the X-Razorpay-Signature HMAC with the webhook
 *      secret, looks up the payment by order id, and inside one transaction
 *      marks it succeeded (gateway_verified_at = now()), then allocates it with
 *      the same allocation function used for manual payments. Duplicate events
 *      are no-ops thanks to the unique gateway_payment_id.
 *   4. The client callback only refreshes data. It never marks anything paid.
 */
export interface CreateGatewayOrderRequest {
  invoiceId: string;
  /** Optional partial amount; the server caps it at the live balance. */
  amountPaise?: number;
}

export interface GatewayOrder {
  paymentId: string;
  provider: 'razorpay';
  orderId: string;
  amountPaise: number;
  currency: 'INR';
  /** Public key id for Checkout. Never the key secret. */
  publicKeyId: string;
}

export interface PaymentGateway {
  readonly provider: 'razorpay';
  /** Calls the create-order edge function. */
  createOrder(request: CreateGatewayOrderRequest): Promise<GatewayOrder>;
}
