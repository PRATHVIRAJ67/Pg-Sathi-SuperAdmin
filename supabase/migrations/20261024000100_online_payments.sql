-- =============================================================================
-- Online rent payments through each owner's own Razorpay account.
--
-- * Owners paste their Razorpay API keys. Keys live in private.payment_gateways,
--   which no client role can read; the owner dashboard only ever sees the key
--   id, the mode (test/live) and whether a webhook secret is set.
-- * Saving keys goes through the server (apps/resident-api), which first checks
--   them against Razorpay, then calls gateway_save_credentials as service_role.
-- * A resident paying a bill: the server re-reads the bill balance here
--   (gateway_prepare_order), creates the Razorpay order, and records it
--   (gateway_register_order). Nothing about the amount comes from the client.
-- * A payment is recorded only by gateway_complete_order, which the server
--   calls after verifying Razorpay's signature (checkout callback or webhook).
--   It is idempotent: replays return the same payment.
-- * The manual path (UPI ID / QR, cash, bank transfer recorded by the owner) is
--   unchanged.
-- =============================================================================

create table private.payment_gateways (
  tenant_id uuid primary key references public.tenants (id) on delete cascade,
  provider text not null default 'razorpay' check (provider = 'razorpay'),
  key_id text not null check (key_id ~ '^rzp_(test|live)_[A-Za-z0-9]{6,40}$'),
  key_secret text not null check (char_length(key_secret) between 8 and 200),
  webhook_secret text check (char_length(webhook_secret) between 4 and 200),
  is_enabled boolean not null default true,
  verified_at timestamptz not null,
  updated_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One row per Razorpay order a resident starts. The payments row is created
-- only once the payment is verified, so failed attempts never use up receipt
-- numbers or show in the owner's payment list.
create table private.gateway_orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  resident_id uuid not null,
  invoice_id uuid not null,
  amount_paise bigint not null check (amount_paise > 0),
  provider text not null default 'razorpay',
  provider_order_id text not null unique check (char_length(provider_order_id) between 6 and 64),
  status text not null default 'created' check (status in ('created', 'paid')),
  payment_id uuid,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  foreign key (tenant_id, resident_id) references public.residents (tenant_id, id) on delete cascade,
  foreign key (tenant_id, resident_id, invoice_id) references public.invoices (tenant_id, resident_id, id) on delete cascade
);
create index gateway_orders_tenant_idx on private.gateway_orders (tenant_id, created_at desc);

revoke all on private.payment_gateways, private.gateway_orders from public, anon, authenticated;

create or replace function private.gateway_ready(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.payment_gateways g where g.tenant_id = p_tenant_id and g.is_enabled);
$$;

-- ---------------------------------------------------------------------------
-- Owner dashboard (authenticated)
-- ---------------------------------------------------------------------------

/** Connection status for Settings → Payments. Never returns a secret. */
create or replace function public.get_payment_gateway(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_g private.payment_gateways;
begin
  perform private.require_role(p_tenant_id, private.r_finance());
  select * into v_g from private.payment_gateways g where g.tenant_id = p_tenant_id;
  if v_g.tenant_id is null then
    return null;
  end if;
  return jsonb_build_object(
    'provider', v_g.provider,
    'key_id', v_g.key_id,
    'mode', case when v_g.key_id like 'rzp_live_%' then 'live' else 'test' end,
    'is_enabled', v_g.is_enabled,
    'has_webhook_secret', v_g.webhook_secret is not null,
    'verified_at', v_g.verified_at,
    'updated_at', v_g.updated_at
  );
end;
$$;

create or replace function public.set_payment_gateway_enabled(p_tenant_id uuid, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_write(p_tenant_id, private.r_owner());
  update private.payment_gateways g set is_enabled = coalesce(p_enabled, false), updated_by = auth.uid(), updated_at = now()
   where g.tenant_id = p_tenant_id;
  if not found then
    perform private.fail('Connect Razorpay first.', 'not_found', 'P0002');
  end if;
  perform private.audit(p_tenant_id, case when p_enabled then 'payment_gateway.enabled' else 'payment_gateway.disabled' end,
                        'tenant', p_tenant_id);
end;
$$;

/** Removes the stored keys. Payments already received stay as they are. */
create or replace function public.remove_payment_gateway(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_write(p_tenant_id, private.r_owner());
  delete from private.payment_gateways g where g.tenant_id = p_tenant_id;
  perform private.audit(p_tenant_id, 'payment_gateway.removed', 'tenant', p_tenant_id);
end;
$$;

/** For the resident app: can this business take online payments right now? */
create or replace function public.online_payments_available(p_tenant_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_auth();
  if not (p_tenant_id in (select private.member_tenant_ids())
          or exists (select 1 from public.resident_user_links l where l.tenant_id = p_tenant_id and l.user_id = auth.uid())) then
    return false;
  end if;
  return private.gateway_ready(p_tenant_id)
     and exists (select 1 from public.tenants t where t.id = p_tenant_id and t.status not in ('suspended', 'cancelled'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Server only (service_role, called by apps/resident-api)
-- ---------------------------------------------------------------------------

/** Stores keys that the server has just checked against Razorpay. */
create or replace function public.gateway_save_credentials(
  p_tenant_id uuid,
  p_actor uuid,
  p_key_id text,
  p_key_secret text,
  p_webhook_secret text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key_id text := btrim(coalesce(p_key_id, ''));
  v_secret text := btrim(coalesce(p_key_secret, ''));
  v_webhook text := nullif(btrim(coalesce(p_webhook_secret, '')), '');
begin
  if not exists (
    select 1 from public.tenant_memberships m
     where m.tenant_id = p_tenant_id and m.user_id = p_actor and m.role = 'owner' and m.status = 'active'
  ) then
    perform private.fail('Only the owner can connect Razorpay.', 'forbidden', '42501');
  end if;
  if v_key_id !~ '^rzp_(test|live)_[A-Za-z0-9]{6,40}$' then
    perform private.fail('The Key ID should look like rzp_test_… or rzp_live_…');
  end if;
  if char_length(v_secret) < 8 then
    perform private.fail('Enter the Key Secret.');
  end if;

  insert into private.payment_gateways as g (tenant_id, key_id, key_secret, webhook_secret, is_enabled, verified_at, updated_by)
  values (p_tenant_id, v_key_id, v_secret, v_webhook, true, now(), p_actor)
  on conflict (tenant_id) do update
     set key_id = excluded.key_id,
         key_secret = excluded.key_secret,
         -- Leaving the webhook secret blank keeps the one already saved.
         webhook_secret = coalesce(excluded.webhook_secret, g.webhook_secret),
         is_enabled = true,
         verified_at = now(),
         updated_by = p_actor,
         updated_at = now();

  insert into public.audit_logs (tenant_id, actor_id, action, entity_type, entity_id, details)
  values (p_tenant_id, p_actor, 'payment_gateway.connected', 'tenant', p_tenant_id,
          jsonb_build_object('provider', 'razorpay', 'mode', case when v_key_id like 'rzp_live_%' then 'live' else 'test' end,
                             'key_id', v_key_id, 'webhook', v_webhook is not null));
end;
$$;

/**
 * Checks that p_user may pay p_invoice_id online (their own bill) and returns
 * what the server needs to create the Razorpay order. The amount is the live
 * bill balance, never a client value.
 */
create or replace function public.gateway_prepare_order(p_user_id uuid, p_invoice_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_inv public.invoices;
  v_g private.payment_gateways;
  v_res public.residents;
  v_tenant public.tenants;
begin
  select * into v_inv from public.invoices i where i.id = p_invoice_id;
  if v_inv.id is null or not exists (
    select 1 from public.resident_user_links l where l.resident_id = v_inv.resident_id and l.user_id = p_user_id
  ) then
    perform private.fail('Bill not found.', 'not_found', 'P0002');
  end if;
  select * into v_tenant from public.tenants t where t.id = v_inv.tenant_id;
  if v_tenant.status in ('suspended', 'cancelled') then
    perform private.fail('Your PG is not accepting online payments right now.', 'tenant_inactive', '42501');
  end if;
  select * into v_g from private.payment_gateways g where g.tenant_id = v_inv.tenant_id and g.is_enabled;
  if v_g.tenant_id is null then
    perform private.fail('Your PG has not turned on online payments.', 'not_supported');
  end if;
  if v_inv.status <> 'issued' then
    perform private.fail('This bill was cancelled.', 'validation');
  end if;
  if v_inv.total_paise - v_inv.paid_paise <= 0 then
    perform private.fail('This bill is already paid.', 'already_paid');
  end if;
  select * into v_res from public.residents r where r.id = v_inv.resident_id;
  return jsonb_build_object(
    'tenant_id', v_inv.tenant_id,
    'resident_id', v_inv.resident_id,
    'invoice_id', v_inv.id,
    'invoice_number', v_inv.invoice_number,
    'amount_paise', v_inv.total_paise - v_inv.paid_paise,
    'key_id', v_g.key_id,
    'key_secret', v_g.key_secret
  );
end;
$$;

create or replace function public.gateway_register_order(
  p_tenant_id uuid,
  p_resident_id uuid,
  p_invoice_id uuid,
  p_amount_paise bigint,
  p_provider_order_id text,
  p_user_id uuid
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  insert into private.gateway_orders (tenant_id, resident_id, invoice_id, amount_paise, provider_order_id, created_by)
  values (p_tenant_id, p_resident_id, p_invoice_id, p_amount_paise, p_provider_order_id, p_user_id)
  returning id;
$$;

/** Everything the hosted checkout page and the confirm step need for one order. */
create or replace function public.gateway_order_context(p_provider_order_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_o private.gateway_orders;
  v_g private.payment_gateways;
begin
  select * into v_o from private.gateway_orders o where o.provider_order_id = p_provider_order_id;
  if v_o.id is null then
    perform private.fail('Payment not found.', 'not_found', 'P0002');
  end if;
  select * into v_g from private.payment_gateways g where g.tenant_id = v_o.tenant_id;
  if v_g.tenant_id is null then
    perform private.fail('Your PG has turned off online payments.', 'not_supported');
  end if;
  return jsonb_build_object(
    'tenant_id', v_o.tenant_id,
    'invoice_id', v_o.invoice_id,
    'amount_paise', v_o.amount_paise,
    'status', v_o.status,
    'key_id', v_g.key_id,
    'key_secret', v_g.key_secret,
    'business_name', (select t.name from public.tenants t where t.id = v_o.tenant_id),
    'invoice_number', (select i.invoice_number from public.invoices i where i.id = v_o.invoice_id),
    'period_start', (select i.period_start from public.invoices i where i.id = v_o.invoice_id),
    'resident', (select jsonb_build_object('name', r.full_name, 'phone', r.phone, 'email', r.email)
                   from public.residents r where r.id = v_o.resident_id)
  );
end;
$$;

create or replace function public.gateway_webhook_secret(p_tenant_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select g.webhook_secret from private.payment_gateways g where g.tenant_id = p_tenant_id;
$$;

/**
 * Records a payment that the server has verified with Razorpay. Applies it to
 * the bill it was started from first, then to any other open bills (oldest
 * first); anything left over stays as advance credit, like a manual payment.
 */
create or replace function public.gateway_complete_order(
  p_tenant_id uuid,
  p_provider_order_id text,
  p_provider_payment_id text,
  p_amount_paise bigint,
  p_method text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_o private.gateway_orders;
  v_payment_id uuid;
  v_property_id uuid;
  v_balance bigint;
  v_method public.payment_method;
begin
  select * into v_o from private.gateway_orders o where o.provider_order_id = p_provider_order_id for update;
  if v_o.id is null or v_o.tenant_id is distinct from p_tenant_id then
    perform private.fail('Payment not found.', 'not_found', 'P0002');
  end if;
  if v_o.status = 'paid' then
    return v_o.payment_id;
  end if;
  select p.id into v_payment_id from public.payments p
   where p.gateway_provider = 'razorpay' and p.gateway_payment_id = p_provider_payment_id;
  if v_payment_id is not null then
    update private.gateway_orders o set status = 'paid', payment_id = v_payment_id, paid_at = now() where o.id = v_o.id;
    return v_payment_id;
  end if;
  if coalesce(p_amount_paise, 0) <= 0 then
    perform private.fail('Payment amount must be greater than zero');
  end if;

  v_method := case lower(coalesce(p_method, ''))
    when 'upi' then 'upi'
    when 'card' then 'card'
    when 'netbanking' then 'bank_transfer'
    else 'other'
  end::public.payment_method;

  select s.property_id into v_property_id from public.stays s where s.resident_id = v_o.resident_id and s.status = 'active';
  if v_property_id is null then
    select s.property_id into v_property_id from public.stays s where s.resident_id = v_o.resident_id order by s.move_in_date desc limit 1;
  end if;

  insert into public.payments (
    tenant_id, resident_id, property_id, receipt_number, amount_paise, paid_on, method,
    source, status, reference, notes, idempotency_key,
    gateway_provider, gateway_order_id, gateway_payment_id, gateway_verified_at
  ) values (
    v_o.tenant_id, v_o.resident_id, v_property_id,
    private.next_document_number(v_o.tenant_id, 'receipt'),
    p_amount_paise, private.today(), v_method,
    'gateway', 'succeeded', left(p_provider_payment_id, 100), 'Paid online via Razorpay', v_o.id,
    'razorpay', p_provider_order_id, p_provider_payment_id, now()
  )
  returning id into v_payment_id;

  -- The bill the resident paid first, then everything else oldest first.
  select i.total_paise - i.paid_paise into v_balance from public.invoices i
   where i.id = v_o.invoice_id and i.status = 'issued' for update;
  if coalesce(v_balance, 0) > 0 then
    insert into public.payment_allocations (tenant_id, resident_id, payment_id, invoice_id, amount_paise)
    values (v_o.tenant_id, v_o.resident_id, v_payment_id, v_o.invoice_id, least(v_balance, p_amount_paise));
  end if;
  perform private.allocate_payment(v_payment_id);

  update private.gateway_orders o set status = 'paid', payment_id = v_payment_id, paid_at = now() where o.id = v_o.id;

  insert into public.audit_logs (tenant_id, actor_id, action, entity_type, entity_id, details)
  values (v_o.tenant_id, v_o.created_by, 'payment.received_online', 'payment', v_payment_id,
          jsonb_build_object('resident_id', v_o.resident_id, 'amount_paise', p_amount_paise, 'method', v_method,
                             'provider', 'razorpay', 'provider_payment_id', p_provider_payment_id));
  return v_payment_id;
end;
$$;

revoke all on function private.gateway_ready(uuid) from public, anon, authenticated;

revoke execute on function public.get_payment_gateway(uuid), public.set_payment_gateway_enabled(uuid, boolean),
  public.remove_payment_gateway(uuid), public.online_payments_available(uuid) from public, anon;
grant execute on function public.get_payment_gateway(uuid), public.set_payment_gateway_enabled(uuid, boolean),
  public.remove_payment_gateway(uuid), public.online_payments_available(uuid) to authenticated;

revoke execute on function public.gateway_save_credentials(uuid, uuid, text, text, text),
  public.gateway_prepare_order(uuid, uuid),
  public.gateway_register_order(uuid, uuid, uuid, bigint, text, uuid),
  public.gateway_order_context(text),
  public.gateway_webhook_secret(uuid),
  public.gateway_complete_order(uuid, text, text, bigint, text) from public, anon, authenticated;
grant execute on function public.gateway_save_credentials(uuid, uuid, text, text, text),
  public.gateway_prepare_order(uuid, uuid),
  public.gateway_register_order(uuid, uuid, uuid, bigint, text, uuid),
  public.gateway_order_context(text),
  public.gateway_webhook_secret(uuid),
  public.gateway_complete_order(uuid, text, text, bigint, text) to service_role;
