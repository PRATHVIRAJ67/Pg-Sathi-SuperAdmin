-- =============================================================================
-- PG SaaS — foundation: schemas, enums, platform tables, tenants, memberships.
--
-- Conventions
--   * Money is stored as BIGINT paise (1 INR = 100 paise). Never floating point.
--   * Every tenant-owned table carries tenant_id and exposes UNIQUE (tenant_id, id)
--     so child tables can use composite foreign keys that make cross-tenant
--     references impossible at the database level.
--   * Clients never write tables directly. All writes go through audited
--     SECURITY DEFINER functions (see the *_api migrations); reads go through
--     SECURITY INVOKER functions or SELECT, both guarded by RLS.
-- =============================================================================

create schema if not exists private;
comment on schema private is 'Internal helpers. Not exposed through the Data API.';

-- ---------------------------------------------------------------------------
-- Enums (system-level vocabularies, not business data)
-- ---------------------------------------------------------------------------
create type public.tenant_role as enum ('owner', 'manager', 'accountant', 'staff');
create type public.tenant_status as enum ('trial', 'active', 'suspended', 'cancelled');
create type public.subscription_status as enum ('trialing', 'active', 'past_due', 'cancelled');
create type public.rent_mode as enum ('per_bed', 'per_room');
create type public.stay_status as enum ('active', 'ended');
create type public.invoice_status as enum ('issued', 'void');
create type public.invoice_kind as enum ('rent', 'other');
create type public.invoice_item_kind as enum ('rent', 'charge', 'discount', 'adjustment', 'other');
create type public.payment_method as enum ('cash', 'upi', 'bank_transfer', 'card', 'cheque', 'other');
create type public.payment_source as enum ('manual', 'gateway');
-- recorded/voided: manual entries made by staff.
-- pending/succeeded/failed/refunded: reserved for verified gateway transactions.
create type public.payment_status as enum ('recorded', 'voided', 'pending', 'succeeded', 'failed', 'refunded');
create type public.deposit_txn_kind as enum ('collected', 'refunded', 'deducted');

-- ---------------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------------
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Today's date in India. Overdue status is always derived from stored due
-- dates relative to this, never from a background job.
create or replace function private.today()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone 'Asia/Kolkata')::date;
$$;

create or replace function private.clean_text(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim(p_value), '');
$$;

-- ---------------------------------------------------------------------------
-- Profiles (one per auth user)
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text check (char_length(full_name) <= 120),
  phone text check (char_length(phone) <= 20),
  email text check (char_length(email) <= 254),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_updated_at before update on public.profiles
  for each row execute function private.set_updated_at();

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, email, phone)
  values (
    new.id,
    left(private.clean_text(new.raw_user_meta_data ->> 'full_name'), 120),
    new.email,
    new.phone
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------------------------------------------------------------------------
-- Platform administration. Rows are inserted by an operator using SQL or the
-- service role — never through public signup or any client-callable function.
-- ---------------------------------------------------------------------------
create table public.platform_admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  note text,
  granted_at timestamptz not null default now()
);

-- Subscription plans are configuration data managed by platform admins.
create table public.plans (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[a-z0-9][a-z0-9_-]{1,39}$'),
  name text not null check (char_length(name) between 2 and 60),
  description text check (char_length(description) <= 500),
  price_paise bigint not null default 0 check (price_paise >= 0),
  billing_interval text not null default 'month' check (billing_interval in ('month', 'year')),
  -- NULL limit = unlimited
  max_properties integer check (max_properties > 0),
  max_residents integer check (max_residents > 0),
  max_staff integer check (max_staff >= 0),
  features text[] not null default '{}',
  trial_days integer not null default 0 check (trial_days between 0 and 365),
  is_public boolean not null default true,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger plans_updated_at before update on public.plans
  for each row execute function private.set_updated_at();

create table public.platform_settings (
  id boolean primary key default true check (id),
  default_plan_id uuid references public.plans (id),
  signup_enabled boolean not null default true,
  support_email text check (char_length(support_email) <= 254),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null
);
insert into public.platform_settings (id) values (true);

-- ---------------------------------------------------------------------------
-- Tenants (one per PG business workspace)
-- ---------------------------------------------------------------------------
create table public.tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 120),
  status public.tenant_status not null default 'trial',
  contact_name text check (char_length(contact_name) <= 120),
  contact_phone text check (char_length(contact_phone) <= 20),
  contact_email text check (char_length(contact_email) <= 254),
  address_line text check (char_length(address_line) <= 300),
  city text check (char_length(city) <= 80),
  state text check (char_length(state) <= 80),
  postal_code text check (char_length(postal_code) <= 12),
  gstin text check (gstin ~ '^[0-9A-Z]{15}$'),
  logo_path text,
  created_by uuid not null references auth.users (id),
  -- Client-generated key that makes provisioning idempotent and retry-safe.
  provision_request_id uuid not null,
  onboarding_step text not null default 'property'
    check (onboarding_step in ('property', 'rooms', 'rent', 'residents', 'done')),
  onboarding_completed_at timestamptz,
  status_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (created_by, provision_request_id)
);
create index tenants_created_by_idx on public.tenants (created_by);
create index tenants_status_idx on public.tenants (status);
create trigger tenants_updated_at before update on public.tenants
  for each row execute function private.set_updated_at();

create table public.tenant_settings (
  tenant_id uuid primary key references public.tenants (id) on delete cascade,
  default_rent_mode public.rent_mode not null default 'per_bed',
  default_billing_day smallint not null default 1 check (default_billing_day between 1 and 28),
  payment_due_days smallint not null default 5 check (payment_due_days between 0 and 60),
  default_deposit_paise bigint not null default 0 check (default_deposit_paise >= 0),
  prorate_first_month boolean not null default true,
  invoice_prefix text not null default 'INV' check (invoice_prefix ~ '^[A-Z0-9]{1,8}$'),
  receipt_prefix text not null default 'RCT' check (receipt_prefix ~ '^[A-Z0-9]{1,8}$'),
  next_invoice_number integer not null default 1 check (next_invoice_number > 0),
  next_receipt_number integer not null default 1 check (next_receipt_number > 0),
  payment_methods public.payment_method[] not null default '{cash,upi,bank_transfer}',
  expense_categories text[] not null default '{Electricity,Water,Groceries,Maintenance,Salaries,Internet,Building rent,Other}',
  facility_options text[] not null default '{WiFi,Meals,Laundry,Housekeeping,Power backup,Hot water,AC,Parking,CCTV,Gym}',
  receipt_footer text check (char_length(receipt_footer) <= 500),
  upi_id text check (char_length(upi_id) <= 100),
  -- Reserved for future explicitly-triggered notifications. No scheduling exists.
  notification_prefs jsonb not null default '{}'::jsonb check (jsonb_typeof(notification_prefs) = 'object'),
  updated_at timestamptz not null default now()
);
create trigger tenant_settings_updated_at before update on public.tenant_settings
  for each row execute function private.set_updated_at();

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null unique references public.tenants (id) on delete cascade,
  plan_id uuid not null references public.plans (id),
  status public.subscription_status not null default 'trialing',
  trial_ends_at timestamptz,
  current_period_start timestamptz,
  current_period_end timestamptz,
  -- Filled only once a billing provider is integrated and verified.
  provider text,
  provider_subscription_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index subscriptions_plan_idx on public.subscriptions (plan_id);
create trigger subscriptions_updated_at before update on public.subscriptions
  for each row execute function private.set_updated_at();

create table public.tenant_memberships (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.tenant_role not null,
  status text not null default 'active' check (status in ('active', 'suspended')),
  invited_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, user_id)
);
create index tenant_memberships_user_idx on public.tenant_memberships (user_id) where status = 'active';
create trigger tenant_memberships_updated_at before update on public.tenant_memberships
  for each row execute function private.set_updated_at();

create table public.audit_logs (
  id bigint generated always as identity primary key,
  tenant_id uuid references public.tenants (id) on delete cascade,
  actor_id uuid references auth.users (id) on delete set null,
  action text not null check (char_length(action) <= 80),
  entity_type text check (char_length(entity_type) <= 60),
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index audit_logs_tenant_idx on public.audit_logs (tenant_id, created_at desc);
create index audit_logs_platform_idx on public.audit_logs (created_at desc) where tenant_id is null;

create or replace function private.audit(
  p_tenant_id uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid,
  p_details jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_logs (tenant_id, actor_id, action, entity_type, entity_id, details)
  values (p_tenant_id, auth.uid(), p_action, p_entity_type, p_entity_id, coalesce(p_details, '{}'::jsonb));
$$;
