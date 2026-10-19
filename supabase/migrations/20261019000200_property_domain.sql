-- =============================================================================
-- Property domain: properties, rooms, beds, residents, stays, agreements.
-- Composite (tenant_id, ...) foreign keys guarantee that no record can point at
-- another tenant's property, room, bed or resident.
-- =============================================================================

create table public.properties (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 120),
  property_type text not null default 'pg'
    check (property_type in ('pg', 'hostel', 'coliving', 'service_apartment', 'other')),
  gender_policy text not null default 'any' check (gender_policy in ('male', 'female', 'any')),
  address_line1 text check (char_length(address_line1) <= 200),
  address_line2 text check (char_length(address_line2) <= 200),
  locality text check (char_length(locality) <= 100),
  city text check (char_length(city) <= 80),
  state text check (char_length(state) <= 80),
  postal_code text check (char_length(postal_code) <= 12),
  contact_phone text check (char_length(contact_phone) <= 20),
  description text check (char_length(description) <= 2000),
  facilities text[] not null default '{}',
  status text not null default 'active' check (status in ('active', 'archived')),
  cover_image_path text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, name)
);
create index properties_tenant_idx on public.properties (tenant_id);
create trigger properties_updated_at before update on public.properties
  for each row execute function private.set_updated_at();

create table public.property_settings (
  property_id uuid primary key,
  tenant_id uuid not null,
  -- NULL = inherit the tenant default
  billing_day smallint check (billing_day between 1 and 28),
  payment_due_days smallint check (payment_due_days between 0 and 60),
  notice_period_days smallint not null default 30 check (notice_period_days between 0 and 365),
  house_rules text check (char_length(house_rules) <= 4000),
  updated_at timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade
);
create trigger property_settings_updated_at before update on public.property_settings
  for each row execute function private.set_updated_at();

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  name text not null check (char_length(name) between 1 and 40),
  floor text check (char_length(floor) <= 40),
  category text check (char_length(category) <= 60),
  rent_mode public.rent_mode not null default 'per_bed',
  -- per_bed: monthly rent of each bed. per_room: monthly rent of the whole room.
  rent_paise bigint not null default 0 check (rent_paise >= 0),
  deposit_paise bigint not null default 0 check (deposit_paise >= 0),
  amenities text[] not null default '{}',
  notes text check (char_length(notes) <= 1000),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, property_id, id),
  unique (property_id, name),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade
);
create index rooms_property_idx on public.rooms (tenant_id, property_id);
create trigger rooms_updated_at before update on public.rooms
  for each row execute function private.set_updated_at();

create table public.beds (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  room_id uuid not null,
  label text not null check (char_length(label) between 1 and 20),
  -- Optional per-bed override of the room's rent.
  rent_paise bigint check (rent_paise >= 0),
  is_unavailable boolean not null default false,
  unavailable_reason text check (char_length(unavailable_reason) <= 200),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, property_id, id),
  unique (room_id, label),
  foreign key (tenant_id, property_id, room_id) references public.rooms (tenant_id, property_id, id) on delete cascade
);
create index beds_room_idx on public.beds (room_id);
create index beds_property_idx on public.beds (tenant_id, property_id);
create trigger beds_updated_at before update on public.beds
  for each row execute function private.set_updated_at();

create table public.residents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  full_name text not null check (char_length(full_name) between 2 and 120),
  phone text check (char_length(phone) <= 20),
  email text check (char_length(email) <= 254),
  gender text check (gender in ('male', 'female', 'other')),
  date_of_birth date,
  occupation text check (char_length(occupation) <= 120),
  organization text check (char_length(organization) <= 120),
  id_proof_type text check (char_length(id_proof_type) <= 40),
  id_proof_number text check (char_length(id_proof_number) <= 40),
  permanent_address text check (char_length(permanent_address) <= 500),
  emergency_contact_name text check (char_length(emergency_contact_name) <= 120),
  emergency_contact_phone text check (char_length(emergency_contact_phone) <= 20),
  emergency_contact_relation text check (char_length(emergency_contact_relation) <= 40),
  notes text check (char_length(notes) <= 2000),
  archived_at timestamptz,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id)
);
create index residents_tenant_idx on public.residents (tenant_id) where archived_at is null;
create index residents_name_idx on public.residents (tenant_id, lower(full_name));
create trigger residents_updated_at before update on public.residents
  for each row execute function private.set_updated_at();

create table public.resident_user_links (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  resident_id uuid not null unique,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (tenant_id, user_id),
  foreign key (tenant_id, resident_id) references public.residents (tenant_id, id) on delete cascade
);
create index resident_user_links_user_idx on public.resident_user_links (user_id);

create table public.stays (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  resident_id uuid not null,
  property_id uuid not null,
  bed_id uuid not null,
  move_in_date date not null,
  expected_move_out_date date,
  move_out_date date,
  status public.stay_status not null default 'active',
  notes text check (char_length(notes) <= 1000),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  unique (tenant_id, resident_id, id),
  foreign key (tenant_id, resident_id) references public.residents (tenant_id, id) on delete restrict,
  foreign key (tenant_id, property_id, bed_id) references public.beds (tenant_id, property_id, id) on delete restrict,
  check (move_out_date is null or move_out_date >= move_in_date),
  check (expected_move_out_date is null or expected_move_out_date >= move_in_date),
  check ((status = 'active' and move_out_date is null) or (status = 'ended' and move_out_date is not null))
);
-- The core integrity guarantees for bed allocation (race-safe, not UI-only):
create unique index stays_one_active_per_bed on public.stays (bed_id) where status = 'active';
create unique index stays_one_active_per_resident on public.stays (resident_id) where status = 'active';
create index stays_tenant_idx on public.stays (tenant_id, status);
create index stays_property_idx on public.stays (property_id, status);
create trigger stays_updated_at before update on public.stays
  for each row execute function private.set_updated_at();

-- Rent agreements are append-only. Changing rent closes the current agreement
-- (sets effective_to) and opens a new one, so history is never rewritten.
create table public.rent_agreements (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  resident_id uuid not null,
  stay_id uuid not null,
  monthly_rent_paise bigint not null check (monthly_rent_paise >= 0),
  deposit_paise bigint not null default 0 check (deposit_paise >= 0),
  billing_day smallint not null default 1 check (billing_day between 1 and 28),
  effective_from date not null,
  effective_to date,
  note text check (char_length(note) <= 500),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (tenant_id, resident_id, stay_id) references public.stays (tenant_id, resident_id, id) on delete restrict,
  check (effective_to is null or effective_to >= effective_from)
);
create unique index rent_agreements_one_open_per_stay on public.rent_agreements (stay_id) where effective_to is null;
create index rent_agreements_stay_idx on public.rent_agreements (stay_id, effective_from);

create or replace function private.protect_rent_agreement()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Rent agreements are historical records and cannot be deleted'
      using errcode = 'P0001', hint = 'immutable_record';
  end if;
  -- Only closing an open agreement is allowed.
  if old.effective_to is not null
     or new.effective_to is null
     or (to_jsonb(new) - 'effective_to') is distinct from (to_jsonb(old) - 'effective_to') then
    raise exception 'Rent agreements are historical records; create a new agreement instead'
      using errcode = 'P0001', hint = 'immutable_record';
  end if;
  return new;
end;
$$;
create trigger rent_agreements_protect before update or delete on public.rent_agreements
  for each row execute function private.protect_rent_agreement();

-- Additional charges an owner can configure (laundry, electricity share, ...).
create table public.charge_templates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  property_id uuid,
  name text not null check (char_length(name) between 2 and 80),
  amount_paise bigint not null check (amount_paise > 0),
  frequency text not null default 'monthly' check (frequency in ('monthly', 'one_time')),
  -- When true, monthly charges are added automatically to generated rent invoices.
  apply_by_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade
);
create index charge_templates_tenant_idx on public.charge_templates (tenant_id);
create trigger charge_templates_updated_at before update on public.charge_templates
  for each row execute function private.set_updated_at();

create table public.maintenance_tickets (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  property_id uuid not null,
  room_id uuid,
  resident_id uuid,
  title text not null check (char_length(title) between 3 and 140),
  description text check (char_length(description) <= 4000),
  priority text not null default 'medium' check (priority in ('low', 'medium', 'high', 'urgent')),
  status text not null default 'open' check (status in ('open', 'in_progress', 'resolved', 'closed')),
  created_by uuid references auth.users (id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade,
  foreign key (tenant_id, property_id, room_id) references public.rooms (tenant_id, property_id, id) on delete set null (room_id),
  foreign key (tenant_id, resident_id) references public.residents (tenant_id, id) on delete set null (resident_id)
);
create index maintenance_tickets_tenant_idx on public.maintenance_tickets (tenant_id, status);
create trigger maintenance_tickets_updated_at before update on public.maintenance_tickets
  for each row execute function private.set_updated_at();

-- Invitations for staff members and residents. Only a SHA-256 hash of the
-- token is stored; the plain token is shown once to the inviter.
create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  kind text not null check (kind in ('member', 'resident')),
  email text not null check (email = lower(email) and char_length(email) between 3 and 254),
  role public.tenant_role,
  resident_id uuid,
  token_hash text not null unique,
  invited_by uuid references auth.users (id) on delete set null,
  expires_at timestamptz not null,
  accepted_at timestamptz,
  accepted_by uuid references auth.users (id) on delete set null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (tenant_id, resident_id) references public.residents (tenant_id, id) on delete cascade,
  check (
    (kind = 'member' and role is not null and role <> 'owner' and resident_id is null)
    or (kind = 'resident' and role is null and resident_id is not null)
  )
);
create index invitations_tenant_idx on public.invitations (tenant_id, created_at desc);
