-- =============================================================================
-- Finance: invoices, payments, allocations, deposits, expenses.
--
-- Integrity rules enforced by the database (not just the UI):
--   * invoice.paid_paise is derived from live allocations and CHECKed <= total.
--   * allocations reference payment and invoice through (tenant_id, resident_id,
--     ...) composite keys, so a payment can only settle its own resident's
--     invoices inside the same tenant.
--   * total allocated from a payment can never exceed the payment amount.
--   * manual payments can never carry gateway state; a gateway "succeeded"
--     status can only exist on gateway-sourced rows.
--   * every payment has a per-tenant idempotency key, so retries never create
--     duplicates.
-- =============================================================================

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  resident_id uuid not null,
  property_id uuid not null,
  stay_id uuid,
  invoice_number text not null,
  kind public.invoice_kind not null default 'rent',
  period_start date,
  period_end date,
  issue_date date not null,
  due_date date not null,
  status public.invoice_status not null default 'issued',
  total_paise bigint not null check (total_paise >= 0),
  paid_paise bigint not null default 0 check (paid_paise >= 0),
  notes text check (char_length(notes) <= 1000),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references auth.users (id) on delete set null,
  void_reason text check (char_length(void_reason) <= 500),
  unique (tenant_id, id),
  unique (tenant_id, resident_id, id),
  unique (tenant_id, invoice_number),
  foreign key (tenant_id, resident_id) references public.residents (tenant_id, id) on delete restrict,
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete restrict,
  foreign key (tenant_id, resident_id, stay_id) references public.stays (tenant_id, resident_id, id) on delete restrict,
  check (paid_paise <= total_paise),
  check (due_date >= issue_date),
  check (period_start is null or period_end >= period_start),
  check ((status = 'void') = (voided_at is not null))
);
-- One live rent invoice per stay per billing period.
create unique index invoices_one_rent_per_period on public.invoices (stay_id, period_start)
  where kind = 'rent' and status = 'issued' and stay_id is not null;
create index invoices_tenant_due_idx on public.invoices (tenant_id, due_date);
create index invoices_resident_idx on public.invoices (resident_id, due_date);
create index invoices_property_idx on public.invoices (property_id, due_date);

create table public.invoice_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  invoice_id uuid not null,
  kind public.invoice_item_kind not null default 'rent',
  description text not null check (char_length(description) between 1 and 200),
  -- negative amounts are allowed for discounts / adjustments
  amount_paise bigint not null,
  sort_order smallint not null default 0,
  foreign key (tenant_id, invoice_id) references public.invoices (tenant_id, id) on delete cascade
);
create index invoice_items_invoice_idx on public.invoice_items (invoice_id);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  resident_id uuid not null,
  property_id uuid,
  receipt_number text not null,
  amount_paise bigint not null check (amount_paise > 0),
  paid_on date not null,
  method public.payment_method not null,
  source public.payment_source not null default 'manual',
  status public.payment_status not null default 'recorded',
  reference text check (char_length(reference) <= 100),
  notes text check (char_length(notes) <= 1000),
  idempotency_key uuid not null,
  recorded_by uuid references auth.users (id) on delete set null,
  -- Future gateway integration (server-verified only).
  gateway_provider text,
  gateway_order_id text,
  gateway_payment_id text,
  gateway_verified_at timestamptz,
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  voided_by uuid references auth.users (id) on delete set null,
  void_reason text check (char_length(void_reason) <= 500),
  unique (tenant_id, id),
  unique (tenant_id, resident_id, id),
  unique (tenant_id, idempotency_key),
  unique (tenant_id, receipt_number),
  unique (gateway_provider, gateway_payment_id),
  foreign key (tenant_id, resident_id) references public.residents (tenant_id, id) on delete restrict,
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete set null (property_id),
  check (
    (source = 'manual' and status in ('recorded', 'voided')
      and gateway_provider is null and gateway_payment_id is null and gateway_verified_at is null)
    or
    (source = 'gateway' and status in ('pending', 'succeeded', 'failed', 'refunded', 'voided')
      and gateway_provider is not null
      and (status <> 'succeeded' or gateway_verified_at is not null))
  ),
  check ((status = 'voided') = (voided_at is not null))
);
create index payments_tenant_paid_on_idx on public.payments (tenant_id, paid_on desc);
create index payments_resident_idx on public.payments (resident_id, paid_on desc);
create index payments_property_idx on public.payments (property_id, paid_on desc);

create table public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  resident_id uuid not null,
  payment_id uuid not null,
  invoice_id uuid not null,
  amount_paise bigint not null check (amount_paise > 0),
  created_at timestamptz not null default now(),
  voided_at timestamptz,
  foreign key (tenant_id, resident_id, payment_id) references public.payments (tenant_id, resident_id, id) on delete restrict,
  foreign key (tenant_id, resident_id, invoice_id) references public.invoices (tenant_id, resident_id, id) on delete restrict
);
create index payment_allocations_invoice_idx on public.payment_allocations (invoice_id) where voided_at is null;
create index payment_allocations_payment_idx on public.payment_allocations (payment_id);

-- Keeps invoices.paid_paise in sync and enforces "never allocate more than the
-- payment amount". The CHECK on invoices enforces "never more than the total".
create or replace function private.sync_allocation_totals()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invoice_ids uuid[];
  v_payment_ids uuid[];
  v_over uuid;
begin
  if tg_op = 'DELETE' then
    raise exception 'Payment allocations are historical; void the payment instead'
      using errcode = 'P0001', hint = 'immutable_record';
  end if;

  v_invoice_ids := array[new.invoice_id];
  v_payment_ids := array[new.payment_id];
  if tg_op = 'UPDATE' then
    if old.invoice_id <> new.invoice_id or old.payment_id <> new.payment_id
       or old.amount_paise <> new.amount_paise or old.voided_at is not null then
      raise exception 'Payment allocations can only be voided'
        using errcode = 'P0001', hint = 'immutable_record';
    end if;
  end if;

  update public.invoices i
     set paid_paise = coalesce((
       select sum(a.amount_paise) from public.payment_allocations a
        where a.invoice_id = i.id and a.voided_at is null), 0)
   where i.id = any (v_invoice_ids);

  select p.id into v_over
    from public.payments p
   where p.id = any (v_payment_ids)
     and p.amount_paise < (
       select coalesce(sum(a.amount_paise), 0) from public.payment_allocations a
        where a.payment_id = p.id and a.voided_at is null);
  if v_over is not null then
    raise exception 'Allocations exceed the payment amount'
      using errcode = 'P0001', hint = 'over_allocated';
  end if;
  return null;
end;
$$;
create trigger payment_allocations_sync
  after insert or update or delete on public.payment_allocations
  for each row execute function private.sync_allocation_totals();

create table public.deposit_transactions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  resident_id uuid not null,
  stay_id uuid,
  kind public.deposit_txn_kind not null,
  amount_paise bigint not null check (amount_paise > 0),
  txn_date date not null,
  method public.payment_method,
  reference text check (char_length(reference) <= 100),
  notes text check (char_length(notes) <= 1000),
  idempotency_key uuid not null,
  recorded_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  unique (tenant_id, idempotency_key),
  foreign key (tenant_id, resident_id) references public.residents (tenant_id, id) on delete restrict,
  foreign key (tenant_id, resident_id, stay_id) references public.stays (tenant_id, resident_id, id) on delete restrict
);
create index deposit_transactions_resident_idx on public.deposit_transactions (resident_id, txn_date);
create index deposit_transactions_tenant_idx on public.deposit_transactions (tenant_id, txn_date desc);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  property_id uuid,
  category text not null check (char_length(category) between 2 and 60),
  amount_paise bigint not null check (amount_paise > 0),
  expense_date date not null,
  payee text check (char_length(payee) <= 120),
  method public.payment_method,
  reference text check (char_length(reference) <= 100),
  notes text check (char_length(notes) <= 1000),
  receipt_path text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete restrict
);
create index expenses_tenant_date_idx on public.expenses (tenant_id, expense_date desc);
create index expenses_property_idx on public.expenses (property_id, expense_date desc);
create trigger expenses_updated_at before update on public.expenses
  for each row execute function private.set_updated_at();

-- Derived payment status. Overdue is computed from stored due dates at query
-- time — there is no scheduler that flips statuses.
create or replace function private.invoice_payment_status(
  p_status public.invoice_status,
  p_total bigint,
  p_paid bigint,
  p_due date
)
returns text
language sql
stable
set search_path = ''
as $$
  select case
    when p_status = 'void' then 'void'
    when p_paid >= p_total then 'paid'
    when p_due < private.today() then 'overdue'
    when p_paid > 0 then 'partially_paid'
    else 'pending'
  end;
$$;
