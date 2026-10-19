-- =============================================================================
-- Write API, part 1: workspace provisioning, settings, properties, rooms, beds,
-- residents, stays and rent agreements.
--
-- Every function here is SECURITY DEFINER with an empty search_path and:
--   1. derives the tenant from the referenced row (never trusts a client id
--      on its own — a client-supplied tenant id is only accepted after
--      private.require_write confirms an active membership),
--   2. checks the caller's role explicitly,
--   3. validates input, and
--   4. writes an audit log entry for meaningful changes.
-- =============================================================================

create or replace function private.r_all() returns public.tenant_role[]
language sql immutable set search_path = ''
as $$ select array['owner', 'manager', 'accountant', 'staff']::public.tenant_role[]; $$;

create or replace function private.r_ops() returns public.tenant_role[]
language sql immutable set search_path = ''
as $$ select array['owner', 'manager']::public.tenant_role[]; $$;

create or replace function private.r_finance() returns public.tenant_role[]
language sql immutable set search_path = ''
as $$ select array['owner', 'manager', 'accountant']::public.tenant_role[]; $$;

create or replace function private.r_owner() returns public.tenant_role[]
language sql immutable set search_path = ''
as $$ select array['owner']::public.tenant_role[]; $$;

create or replace function private.fail(p_message text, p_hint text default 'validation', p_errcode text default 'P0001')
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception '%', p_message using errcode = p_errcode, hint = p_hint;
end;
$$;

-- Parses a JSON value into whole paise, rejecting fractions and non-numbers.
create or replace function private.to_paise(p_value jsonb, p_field text)
returns bigint
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_num numeric;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return null;
  end if;
  if jsonb_typeof(p_value) <> 'number' then
    perform private.fail(format('%s must be a number', p_field));
  end if;
  v_num := (p_value #>> '{}')::numeric;
  if v_num <> trunc(v_num) then
    perform private.fail(format('%s must be a whole number of paise', p_field));
  end if;
  if abs(v_num) > 100000000000 then
    perform private.fail(format('%s is too large', p_field));
  end if;
  return v_num::bigint;
end;
$$;

create or replace function private.text_array(p_value jsonb, p_field text, p_max integer default 50)
returns text[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_result text[];
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return '{}';
  end if;
  if jsonb_typeof(p_value) <> 'array' then
    perform private.fail(format('%s must be a list', p_field));
  end if;
  select coalesce(array_agg(distinct v), '{}')
    into v_result
    from (
      select left(private.clean_text(e), 60) as v
        from jsonb_array_elements_text(p_value) e
    ) s
   where v is not null;
  if cardinality(v_result) > p_max then
    perform private.fail(format('%s can have at most %s entries', p_field, p_max));
  end if;
  return v_result;
end;
$$;

create or replace function private.check_phone(p_phone text, p_field text default 'Phone number')
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := private.clean_text(p_phone);
begin
  if v is not null and v !~ '^\+?[0-9][0-9 ()-]{5,18}$' then
    perform private.fail(format('%s is not valid', p_field));
  end if;
  return v;
end;
$$;

create or replace function private.check_email(p_email text, p_field text default 'Email')
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := lower(private.clean_text(p_email));
begin
  if v is not null and v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    perform private.fail(format('%s is not valid', p_field));
  end if;
  return v;
end;
$$;

-- Sequential, gap-free per-tenant document numbers. The row lock on
-- tenant_settings serialises concurrent callers.
create or replace function private.next_document_number(p_tenant_id uuid, p_kind text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prefix text;
  v_number integer;
begin
  if p_kind = 'invoice' then
    update public.tenant_settings
       set next_invoice_number = next_invoice_number + 1
     where tenant_id = p_tenant_id
    returning invoice_prefix, next_invoice_number - 1 into v_prefix, v_number;
  else
    update public.tenant_settings
       set next_receipt_number = next_receipt_number + 1
     where tenant_id = p_tenant_id
    returning receipt_prefix, next_receipt_number - 1 into v_prefix, v_number;
  end if;
  if v_number is null then
    perform private.fail('Workspace settings are missing', 'misconfigured');
  end if;
  return v_prefix || '-' || lpad(v_number::text, 5, '0');
end;
$$;

-- =============================================================================
-- Workspace provisioning (self-service onboarding)
-- =============================================================================
create or replace function public.provision_workspace(
  p_request_id uuid,
  p_business_name text,
  p_owner_name text default null,
  p_contact_phone text default null,
  p_contact_email text default null,
  p_city text default null,
  p_state text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_auth();
  v_email_confirmed timestamptz;
  v_phone_confirmed timestamptz;
  v_tenant_id uuid;
  v_settings public.platform_settings;
  v_plan public.plans;
  v_name text := private.clean_text(p_business_name);
begin
  if p_request_id is null then
    perform private.fail('A provisioning request id is required');
  end if;

  select u.email_confirmed_at, u.phone_confirmed_at
    into v_email_confirmed, v_phone_confirmed
    from auth.users u where u.id = v_uid;
  if v_email_confirmed is null and v_phone_confirmed is null then
    perform private.fail('Verify your email address before creating a workspace', 'not_verified', '42501');
  end if;

  -- Serialise provisioning per user so concurrent retries cannot race.
  perform pg_advisory_xact_lock(hashtextextended('provision:' || v_uid::text, 0));

  -- Idempotent replay of the same request.
  select t.id into v_tenant_id
    from public.tenants t
   where t.created_by = v_uid and t.provision_request_id = p_request_id;
  if found then
    return v_tenant_id;
  end if;

  -- Resume an unfinished workspace rather than creating a duplicate.
  select t.id into v_tenant_id
    from public.tenants t
    join public.tenant_memberships m
      on m.tenant_id = t.id and m.user_id = v_uid and m.role = 'owner' and m.status = 'active'
   where t.created_by = v_uid and t.onboarding_completed_at is null
   order by t.created_at
   limit 1;
  if found then
    return v_tenant_id;
  end if;

  select * into v_settings from public.platform_settings where id;
  if not coalesce(v_settings.signup_enabled, false) then
    perform private.fail('New workspace sign-ups are currently paused', 'signup_disabled', '42501');
  end if;

  if v_name is null or char_length(v_name) < 2 or char_length(v_name) > 120 then
    perform private.fail('Business name must be between 2 and 120 characters');
  end if;

  if (select count(*) from public.tenants t where t.created_by = v_uid) >= 5 then
    perform private.fail('You have reached the maximum number of workspaces for one account', 'workspace_limit');
  end if;

  select * into v_plan from public.plans p where p.id = v_settings.default_plan_id and p.is_active;
  if v_plan.id is null then
    select * into v_plan from public.plans p
     where p.is_active and p.is_public
     order by p.sort_order, p.price_paise
     limit 1;
  end if;
  if v_plan.id is null then
    perform private.fail('No subscription plan is configured. Please contact support.', 'misconfigured');
  end if;

  insert into public.tenants (
    name, status, contact_name, contact_phone, contact_email, city, state, created_by, provision_request_id
  ) values (
    v_name,
    case when v_plan.trial_days > 0 then 'trial' else 'active' end::public.tenant_status,
    left(private.clean_text(p_owner_name), 120),
    private.check_phone(p_contact_phone),
    private.check_email(p_contact_email),
    left(private.clean_text(p_city), 80),
    left(private.clean_text(p_state), 80),
    v_uid,
    p_request_id
  )
  returning id into v_tenant_id;

  insert into public.tenant_settings (tenant_id) values (v_tenant_id);

  insert into public.subscriptions (tenant_id, plan_id, status, trial_ends_at, current_period_start)
  values (
    v_tenant_id,
    v_plan.id,
    case when v_plan.trial_days > 0 then 'trialing' else 'active' end::public.subscription_status,
    case when v_plan.trial_days > 0 then now() + make_interval(days => v_plan.trial_days) end,
    now()
  );

  -- Role is fixed server-side; the client cannot choose it.
  insert into public.tenant_memberships (tenant_id, user_id, role) values (v_tenant_id, v_uid, 'owner');

  update public.profiles
     set full_name = coalesce(left(private.clean_text(p_owner_name), 120), full_name),
         phone = coalesce(private.check_phone(p_contact_phone), phone)
   where id = v_uid;

  perform private.audit(v_tenant_id, 'workspace.provisioned', 'tenant', v_tenant_id,
    jsonb_build_object('plan', v_plan.code));
  return v_tenant_id;
end;
$$;

create or replace function public.update_workspace(p_tenant_id uuid, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_write(p_tenant_id, private.r_owner());
  if p_data ? 'name' and char_length(coalesce(private.clean_text(p_data ->> 'name'), '')) < 2 then
    perform private.fail('Business name must be at least 2 characters');
  end if;
  if p_data ? 'gstin' and private.clean_text(p_data ->> 'gstin') is not null
     and upper(private.clean_text(p_data ->> 'gstin')) !~ '^[0-9A-Z]{15}$' then
    perform private.fail('GSTIN must be 15 letters or digits');
  end if;

  update public.tenants t set
    name = case when p_data ? 'name' then private.clean_text(p_data ->> 'name') else t.name end,
    contact_name = case when p_data ? 'contact_name' then left(private.clean_text(p_data ->> 'contact_name'), 120) else t.contact_name end,
    contact_phone = case when p_data ? 'contact_phone' then private.check_phone(p_data ->> 'contact_phone') else t.contact_phone end,
    contact_email = case when p_data ? 'contact_email' then private.check_email(p_data ->> 'contact_email') else t.contact_email end,
    address_line = case when p_data ? 'address_line' then left(private.clean_text(p_data ->> 'address_line'), 300) else t.address_line end,
    city = case when p_data ? 'city' then left(private.clean_text(p_data ->> 'city'), 80) else t.city end,
    state = case when p_data ? 'state' then left(private.clean_text(p_data ->> 'state'), 80) else t.state end,
    postal_code = case when p_data ? 'postal_code' then left(private.clean_text(p_data ->> 'postal_code'), 12) else t.postal_code end,
    gstin = case when p_data ? 'gstin' then upper(private.clean_text(p_data ->> 'gstin')) else t.gstin end,
    logo_path = case when p_data ? 'logo_path' then private.clean_text(p_data ->> 'logo_path') else t.logo_path end
  where t.id = p_tenant_id;

  perform private.audit(p_tenant_id, 'workspace.updated', 'tenant', p_tenant_id,
    jsonb_build_object('fields', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_object_keys(p_data) k)));
end;
$$;

create or replace function public.update_tenant_settings(p_tenant_id uuid, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_methods public.payment_method[];
begin
  perform private.require_write(p_tenant_id, private.r_owner());

  if p_data ? 'payment_methods' then
    begin
      select coalesce(array_agg(distinct m::public.payment_method), '{}')
        into v_methods
        from jsonb_array_elements_text(p_data -> 'payment_methods') m;
    exception when invalid_text_representation then
      perform private.fail('Unknown payment method');
    end;
    if cardinality(v_methods) = 0 then
      perform private.fail('Enable at least one payment method');
    end if;
  end if;

  update public.tenant_settings s set
    default_rent_mode = case when p_data ? 'default_rent_mode' then (p_data ->> 'default_rent_mode')::public.rent_mode else s.default_rent_mode end,
    default_billing_day = case when p_data ? 'default_billing_day' then (p_data ->> 'default_billing_day')::smallint else s.default_billing_day end,
    payment_due_days = case when p_data ? 'payment_due_days' then (p_data ->> 'payment_due_days')::smallint else s.payment_due_days end,
    default_deposit_paise = case when p_data ? 'default_deposit_paise' then coalesce(private.to_paise(p_data -> 'default_deposit_paise', 'Default deposit'), 0) else s.default_deposit_paise end,
    prorate_first_month = case when p_data ? 'prorate_first_month' then (p_data ->> 'prorate_first_month')::boolean else s.prorate_first_month end,
    invoice_prefix = case when p_data ? 'invoice_prefix' then upper(private.clean_text(p_data ->> 'invoice_prefix')) else s.invoice_prefix end,
    receipt_prefix = case when p_data ? 'receipt_prefix' then upper(private.clean_text(p_data ->> 'receipt_prefix')) else s.receipt_prefix end,
    payment_methods = case when p_data ? 'payment_methods' then v_methods else s.payment_methods end,
    expense_categories = case when p_data ? 'expense_categories' then private.text_array(p_data -> 'expense_categories', 'Expense categories') else s.expense_categories end,
    facility_options = case when p_data ? 'facility_options' then private.text_array(p_data -> 'facility_options', 'Facilities') else s.facility_options end,
    receipt_footer = case when p_data ? 'receipt_footer' then private.clean_text(p_data ->> 'receipt_footer') else s.receipt_footer end,
    upi_id = case when p_data ? 'upi_id' then private.clean_text(p_data ->> 'upi_id') else s.upi_id end,
    notification_prefs = case when p_data ? 'notification_prefs' and jsonb_typeof(p_data -> 'notification_prefs') = 'object'
                              then p_data -> 'notification_prefs' else s.notification_prefs end
  where s.tenant_id = p_tenant_id;

  perform private.audit(p_tenant_id, 'settings.updated', 'tenant_settings', p_tenant_id,
    jsonb_build_object('fields', (select coalesce(jsonb_agg(k), '[]'::jsonb) from jsonb_object_keys(p_data) k)));
exception
  when check_violation then
    perform private.fail('One of the settings is outside the allowed range');
end;
$$;

create or replace function public.set_onboarding_step(p_tenant_id uuid, p_step text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_write(p_tenant_id, private.r_owner());
  if p_step not in ('property', 'rooms', 'rent', 'residents', 'done') then
    perform private.fail('Unknown onboarding step');
  end if;
  update public.tenants t
     set onboarding_step = p_step,
         onboarding_completed_at = case when p_step = 'done' then coalesce(t.onboarding_completed_at, now()) else t.onboarding_completed_at end
   where t.id = p_tenant_id;
  if p_step = 'done' then
    perform private.audit(p_tenant_id, 'workspace.onboarding_completed', 'tenant', p_tenant_id);
  end if;
end;
$$;

create or replace function public.update_my_profile(p_data jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_auth();
begin
  update public.profiles p set
    full_name = case when p_data ? 'full_name' then left(private.clean_text(p_data ->> 'full_name'), 120) else p.full_name end,
    phone = case when p_data ? 'phone' then private.check_phone(p_data ->> 'phone') else p.phone end
  where p.id = v_uid;
end;
$$;

-- =============================================================================
-- Properties
-- =============================================================================
create or replace function public.save_property(p_tenant_id uuid, p_property_id uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := p_tenant_id;
  v_id uuid := p_property_id;
  v_name text := private.clean_text(p_data ->> 'name');
  v_settings jsonb := coalesce(p_data -> 'settings', '{}'::jsonb);
begin
  if v_id is not null then
    select p.tenant_id into v_tenant_id from public.properties p where p.id = v_id;
  end if;
  perform private.require_write(v_tenant_id, private.r_ops());

  if v_id is null then
    if v_name is null then
      perform private.fail('Property name is required');
    end if;
    insert into public.properties (
      tenant_id, name, property_type, gender_policy, address_line1, address_line2, locality, city, state,
      postal_code, contact_phone, description, facilities, created_by
    ) values (
      v_tenant_id,
      v_name,
      coalesce(private.clean_text(p_data ->> 'property_type'), 'pg'),
      coalesce(private.clean_text(p_data ->> 'gender_policy'), 'any'),
      private.clean_text(p_data ->> 'address_line1'),
      private.clean_text(p_data ->> 'address_line2'),
      private.clean_text(p_data ->> 'locality'),
      private.clean_text(p_data ->> 'city'),
      private.clean_text(p_data ->> 'state'),
      private.clean_text(p_data ->> 'postal_code'),
      private.check_phone(p_data ->> 'contact_phone'),
      private.clean_text(p_data ->> 'description'),
      private.text_array(p_data -> 'facilities', 'Facilities'),
      auth.uid()
    )
    returning id into v_id;
    insert into public.property_settings (property_id, tenant_id) values (v_id, v_tenant_id);
    perform private.audit(v_tenant_id, 'property.created', 'property', v_id, jsonb_build_object('name', v_name));
  else
    update public.properties p set
      name = case when p_data ? 'name' then coalesce(v_name, p.name) else p.name end,
      property_type = case when p_data ? 'property_type' then coalesce(private.clean_text(p_data ->> 'property_type'), p.property_type) else p.property_type end,
      gender_policy = case when p_data ? 'gender_policy' then coalesce(private.clean_text(p_data ->> 'gender_policy'), p.gender_policy) else p.gender_policy end,
      address_line1 = case when p_data ? 'address_line1' then private.clean_text(p_data ->> 'address_line1') else p.address_line1 end,
      address_line2 = case when p_data ? 'address_line2' then private.clean_text(p_data ->> 'address_line2') else p.address_line2 end,
      locality = case when p_data ? 'locality' then private.clean_text(p_data ->> 'locality') else p.locality end,
      city = case when p_data ? 'city' then private.clean_text(p_data ->> 'city') else p.city end,
      state = case when p_data ? 'state' then private.clean_text(p_data ->> 'state') else p.state end,
      postal_code = case when p_data ? 'postal_code' then private.clean_text(p_data ->> 'postal_code') else p.postal_code end,
      contact_phone = case when p_data ? 'contact_phone' then private.check_phone(p_data ->> 'contact_phone') else p.contact_phone end,
      description = case when p_data ? 'description' then private.clean_text(p_data ->> 'description') else p.description end,
      facilities = case when p_data ? 'facilities' then private.text_array(p_data -> 'facilities', 'Facilities') else p.facilities end,
      cover_image_path = case when p_data ? 'cover_image_path' then private.clean_text(p_data ->> 'cover_image_path') else p.cover_image_path end
    where p.id = v_id;
    perform private.audit(v_tenant_id, 'property.updated', 'property', v_id);
  end if;

  if v_settings <> '{}'::jsonb then
    update public.property_settings s set
      billing_day = case when v_settings ? 'billing_day' then (v_settings ->> 'billing_day')::smallint else s.billing_day end,
      payment_due_days = case when v_settings ? 'payment_due_days' then (v_settings ->> 'payment_due_days')::smallint else s.payment_due_days end,
      notice_period_days = case when v_settings ? 'notice_period_days' then coalesce((v_settings ->> 'notice_period_days')::smallint, 30) else s.notice_period_days end,
      house_rules = case when v_settings ? 'house_rules' then private.clean_text(v_settings ->> 'house_rules') else s.house_rules end
    where s.property_id = v_id;
  end if;
  return v_id;
exception
  when unique_violation then
    perform private.fail('A property with this name already exists', 'duplicate');
  when check_violation then
    perform private.fail('Some property details are invalid. Check the name, type and field lengths.');
end;
$$;

create or replace function public.set_property_archived(p_property_id uuid, p_archived boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  select p.tenant_id into v_tenant_id from public.properties p where p.id = p_property_id;
  perform private.require_write(v_tenant_id, private.r_owner());
  if p_archived and exists (select 1 from public.stays s where s.property_id = p_property_id and s.status = 'active') then
    perform private.fail('Move out all residents before archiving this property', 'has_active_stays');
  end if;
  update public.properties set status = case when p_archived then 'archived' else 'active' end where id = p_property_id;
  perform private.audit(v_tenant_id, case when p_archived then 'property.archived' else 'property.restored' end, 'property', p_property_id);
end;
$$;

-- =============================================================================
-- Rooms and beds
-- =============================================================================
create or replace function private.default_bed_label(p_index integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_index between 1 and 26 then chr(64 + p_index) else 'Bed ' || p_index end;
$$;

-- p_rooms: [{ name, floor?, category?, rent_mode?, rent_paise, deposit_paise?, bed_count?, bed_labels?[] }]
create or replace function public.create_rooms(p_property_id uuid, p_rooms jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_room jsonb;
  v_room_id uuid;
  v_ids jsonb := '[]'::jsonb;
  v_labels text[];
  v_count integer;
  v_name text;
  v_default_mode public.rent_mode;
  i integer;
begin
  select p.tenant_id into v_tenant_id from public.properties p where p.id = p_property_id;
  perform private.require_write(v_tenant_id, private.r_ops());
  if jsonb_typeof(p_rooms) <> 'array' or jsonb_array_length(p_rooms) = 0 then
    perform private.fail('Add at least one room');
  end if;
  if jsonb_array_length(p_rooms) > 200 then
    perform private.fail('You can add at most 200 rooms at a time');
  end if;
  select s.default_rent_mode into v_default_mode from public.tenant_settings s where s.tenant_id = v_tenant_id;

  for v_room in select * from jsonb_array_elements(p_rooms) loop
    v_name := private.clean_text(v_room ->> 'name');
    if v_name is null then
      perform private.fail('Every room needs a name or number');
    end if;

    if v_room ? 'bed_labels' and jsonb_typeof(v_room -> 'bed_labels') = 'array' and jsonb_array_length(v_room -> 'bed_labels') > 0 then
      select array_agg(private.clean_text(l) order by ord)
        into v_labels
        from jsonb_array_elements_text(v_room -> 'bed_labels') with ordinality as t(l, ord);
    else
      v_count := coalesce((v_room ->> 'bed_count')::integer, 1);
      if v_count < 1 or v_count > 30 then
        perform private.fail(format('Room %s: beds must be between 1 and 30', v_name));
      end if;
      select array_agg(private.default_bed_label(g)) into v_labels from generate_series(1, v_count) g;
    end if;
    if array_position(v_labels, null) is not null then
      perform private.fail(format('Room %s: bed labels cannot be empty', v_name));
    end if;

    begin
      insert into public.rooms (tenant_id, property_id, name, floor, category, rent_mode, rent_paise, deposit_paise, amenities, notes)
      values (
        v_tenant_id, p_property_id, v_name,
        private.clean_text(v_room ->> 'floor'),
        private.clean_text(v_room ->> 'category'),
        coalesce((v_room ->> 'rent_mode')::public.rent_mode, v_default_mode, 'per_bed'),
        coalesce(private.to_paise(v_room -> 'rent_paise', 'Rent'), 0),
        coalesce(private.to_paise(v_room -> 'deposit_paise', 'Deposit'), 0),
        private.text_array(v_room -> 'amenities', 'Amenities'),
        private.clean_text(v_room ->> 'notes')
      )
      returning id into v_room_id;
    exception when unique_violation then
      perform private.fail(format('Room %s already exists in this property', v_name), 'duplicate');
    end;

    for i in 1 .. cardinality(v_labels) loop
      begin
        insert into public.beds (tenant_id, property_id, room_id, label, sort_order)
        values (v_tenant_id, p_property_id, v_room_id, v_labels[i], i);
      exception when unique_violation then
        perform private.fail(format('Room %s has duplicate bed label %s', v_name, v_labels[i]), 'duplicate');
      end;
    end loop;
    v_ids := v_ids || to_jsonb(v_room_id);
  end loop;

  perform private.audit(v_tenant_id, 'rooms.created', 'property', p_property_id,
    jsonb_build_object('count', jsonb_array_length(v_ids)));
  return v_ids;
exception
  when check_violation then
    perform private.fail('Some room details are invalid. Check names, rents and field lengths.');
end;
$$;

create or replace function public.update_room(p_room_id uuid, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  select r.tenant_id into v_tenant_id from public.rooms r where r.id = p_room_id;
  perform private.require_write(v_tenant_id, private.r_ops());
  -- Rent changes here affect suggestions for future assignments only. Existing
  -- rent agreements and invoices keep their own recorded amounts.
  update public.rooms r set
    name = case when p_data ? 'name' then coalesce(private.clean_text(p_data ->> 'name'), r.name) else r.name end,
    floor = case when p_data ? 'floor' then private.clean_text(p_data ->> 'floor') else r.floor end,
    category = case when p_data ? 'category' then private.clean_text(p_data ->> 'category') else r.category end,
    rent_mode = case when p_data ? 'rent_mode' then (p_data ->> 'rent_mode')::public.rent_mode else r.rent_mode end,
    rent_paise = case when p_data ? 'rent_paise' then coalesce(private.to_paise(p_data -> 'rent_paise', 'Rent'), 0) else r.rent_paise end,
    deposit_paise = case when p_data ? 'deposit_paise' then coalesce(private.to_paise(p_data -> 'deposit_paise', 'Deposit'), 0) else r.deposit_paise end,
    amenities = case when p_data ? 'amenities' then private.text_array(p_data -> 'amenities', 'Amenities') else r.amenities end,
    notes = case when p_data ? 'notes' then private.clean_text(p_data ->> 'notes') else r.notes end,
    is_active = case when p_data ? 'is_active' then (p_data ->> 'is_active')::boolean else r.is_active end
  where r.id = p_room_id;
  perform private.audit(v_tenant_id, 'room.updated', 'room', p_room_id);
exception
  when unique_violation then
    perform private.fail('Another room in this property already uses that name', 'duplicate');
  when check_violation then
    perform private.fail('Some room details are invalid');
end;
$$;

create or replace function public.delete_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  select r.tenant_id into v_tenant_id from public.rooms r where r.id = p_room_id;
  perform private.require_write(v_tenant_id, private.r_ops());
  if exists (select 1 from public.stays s join public.beds b on b.id = s.bed_id where b.room_id = p_room_id) then
    perform private.fail('This room has stay history. Mark it inactive instead of deleting it.', 'has_history');
  end if;
  delete from public.rooms where id = p_room_id;
  perform private.audit(v_tenant_id, 'room.deleted', 'room', p_room_id);
end;
$$;

create or replace function public.add_beds(p_room_id uuid, p_count integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.rooms;
  v_existing integer;
  v_label text;
  v_next integer;
  i integer;
begin
  select * into v_room from public.rooms r where r.id = p_room_id;
  perform private.require_write(v_room.tenant_id, private.r_ops());
  if p_count is null or p_count < 1 or p_count > 20 then
    perform private.fail('Add between 1 and 20 beds at a time');
  end if;
  select count(*), coalesce(max(sort_order), 0) into v_existing, v_next from public.beds b where b.room_id = p_room_id;
  if v_existing + p_count > 30 then
    perform private.fail('A room can have at most 30 beds');
  end if;
  for i in 1 .. p_count loop
    v_next := v_next + 1;
    v_label := private.default_bed_label(v_next);
    while exists (select 1 from public.beds b where b.room_id = p_room_id and b.label = v_label) loop
      v_next := v_next + 1;
      v_label := private.default_bed_label(v_next);
    end loop;
    insert into public.beds (tenant_id, property_id, room_id, label, sort_order)
    values (v_room.tenant_id, v_room.property_id, p_room_id, v_label, v_next);
  end loop;
  perform private.audit(v_room.tenant_id, 'beds.added', 'room', p_room_id, jsonb_build_object('count', p_count));
end;
$$;

create or replace function public.update_bed(p_bed_id uuid, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bed public.beds;
begin
  select * into v_bed from public.beds b where b.id = p_bed_id;
  perform private.require_write(v_bed.tenant_id, private.r_ops());
  if coalesce((p_data ->> 'is_unavailable')::boolean, false)
     and exists (select 1 from public.stays s where s.bed_id = p_bed_id and s.status = 'active') then
    perform private.fail('This bed is occupied. Move the resident out before marking it unavailable.', 'bed_occupied');
  end if;
  update public.beds b set
    label = case when p_data ? 'label' then coalesce(private.clean_text(p_data ->> 'label'), b.label) else b.label end,
    rent_paise = case when p_data ? 'rent_paise' then private.to_paise(p_data -> 'rent_paise', 'Bed rent') else b.rent_paise end,
    is_unavailable = case when p_data ? 'is_unavailable' then (p_data ->> 'is_unavailable')::boolean else b.is_unavailable end,
    unavailable_reason = case
      when p_data ? 'is_unavailable' and not (p_data ->> 'is_unavailable')::boolean then null
      when p_data ? 'unavailable_reason' then private.clean_text(p_data ->> 'unavailable_reason')
      else b.unavailable_reason end
  where b.id = p_bed_id;
  perform private.audit(v_bed.tenant_id, 'bed.updated', 'bed', p_bed_id);
exception
  when unique_violation then
    perform private.fail('Another bed in this room already uses that label', 'duplicate');
end;
$$;

create or replace function public.delete_bed(p_bed_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_bed public.beds;
begin
  select * into v_bed from public.beds b where b.id = p_bed_id;
  perform private.require_write(v_bed.tenant_id, private.r_ops());
  if exists (select 1 from public.stays s where s.bed_id = p_bed_id) then
    perform private.fail('This bed has stay history. Mark it unavailable instead of deleting it.', 'has_history');
  end if;
  delete from public.beds where id = p_bed_id;
  perform private.audit(v_bed.tenant_id, 'bed.deleted', 'bed', p_bed_id);
end;
$$;

-- Suggested monthly rent for a bed: bed override, else per-bed room rent,
-- else the room rent split evenly across its beds.
create or replace function private.suggested_bed_rent(p_bed_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    b.rent_paise,
    case when r.rent_mode = 'per_bed' then r.rent_paise
         else round(r.rent_paise::numeric / greatest((select count(*) from public.beds x where x.room_id = r.id), 1))::bigint
    end)
    from public.beds b
    join public.rooms r on r.id = b.room_id
   where b.id = p_bed_id;
$$;

-- =============================================================================
-- Residents
-- =============================================================================
create or replace function public.save_resident(p_tenant_id uuid, p_resident_id uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := p_tenant_id;
  v_id uuid := p_resident_id;
  v_name text := private.clean_text(p_data ->> 'full_name');
begin
  if v_id is not null then
    select r.tenant_id into v_tenant_id from public.residents r where r.id = v_id;
  end if;
  perform private.require_write(v_tenant_id, private.r_ops());

  if v_id is null then
    if v_name is null or char_length(v_name) < 2 then
      perform private.fail('Resident name must be at least 2 characters');
    end if;
    insert into public.residents (
      tenant_id, full_name, phone, email, gender, date_of_birth, occupation, organization,
      id_proof_type, id_proof_number, permanent_address, emergency_contact_name,
      emergency_contact_phone, emergency_contact_relation, notes, created_by
    ) values (
      v_tenant_id, v_name,
      private.check_phone(p_data ->> 'phone'),
      private.check_email(p_data ->> 'email'),
      private.clean_text(p_data ->> 'gender'),
      (private.clean_text(p_data ->> 'date_of_birth'))::date,
      private.clean_text(p_data ->> 'occupation'),
      private.clean_text(p_data ->> 'organization'),
      private.clean_text(p_data ->> 'id_proof_type'),
      private.clean_text(p_data ->> 'id_proof_number'),
      private.clean_text(p_data ->> 'permanent_address'),
      private.clean_text(p_data ->> 'emergency_contact_name'),
      private.check_phone(p_data ->> 'emergency_contact_phone', 'Emergency contact phone'),
      private.clean_text(p_data ->> 'emergency_contact_relation'),
      private.clean_text(p_data ->> 'notes'),
      auth.uid()
    )
    returning id into v_id;
    perform private.audit(v_tenant_id, 'resident.created', 'resident', v_id);
  else
    if p_data ? 'full_name' and (v_name is null or char_length(v_name) < 2) then
      perform private.fail('Resident name must be at least 2 characters');
    end if;
    update public.residents r set
      full_name = case when p_data ? 'full_name' then v_name else r.full_name end,
      phone = case when p_data ? 'phone' then private.check_phone(p_data ->> 'phone') else r.phone end,
      email = case when p_data ? 'email' then private.check_email(p_data ->> 'email') else r.email end,
      gender = case when p_data ? 'gender' then private.clean_text(p_data ->> 'gender') else r.gender end,
      date_of_birth = case when p_data ? 'date_of_birth' then (private.clean_text(p_data ->> 'date_of_birth'))::date else r.date_of_birth end,
      occupation = case when p_data ? 'occupation' then private.clean_text(p_data ->> 'occupation') else r.occupation end,
      organization = case when p_data ? 'organization' then private.clean_text(p_data ->> 'organization') else r.organization end,
      id_proof_type = case when p_data ? 'id_proof_type' then private.clean_text(p_data ->> 'id_proof_type') else r.id_proof_type end,
      id_proof_number = case when p_data ? 'id_proof_number' then private.clean_text(p_data ->> 'id_proof_number') else r.id_proof_number end,
      permanent_address = case when p_data ? 'permanent_address' then private.clean_text(p_data ->> 'permanent_address') else r.permanent_address end,
      emergency_contact_name = case when p_data ? 'emergency_contact_name' then private.clean_text(p_data ->> 'emergency_contact_name') else r.emergency_contact_name end,
      emergency_contact_phone = case when p_data ? 'emergency_contact_phone' then private.check_phone(p_data ->> 'emergency_contact_phone', 'Emergency contact phone') else r.emergency_contact_phone end,
      emergency_contact_relation = case when p_data ? 'emergency_contact_relation' then private.clean_text(p_data ->> 'emergency_contact_relation') else r.emergency_contact_relation end,
      notes = case when p_data ? 'notes' then private.clean_text(p_data ->> 'notes') else r.notes end
    where r.id = v_id;
    perform private.audit(v_tenant_id, 'resident.updated', 'resident', v_id);
  end if;
  return v_id;
exception
  when check_violation then
    perform private.fail('Some resident details are invalid. Check field lengths and gender.');
  when invalid_datetime_format or datetime_field_overflow then
    perform private.fail('Date of birth is not a valid date');
end;
$$;

create or replace function public.set_resident_archived(p_resident_id uuid, p_archived boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  select r.tenant_id into v_tenant_id from public.residents r where r.id = p_resident_id;
  perform private.require_write(v_tenant_id, private.r_ops());
  if p_archived and exists (select 1 from public.stays s where s.resident_id = p_resident_id and s.status = 'active') then
    perform private.fail('Move the resident out before archiving', 'has_active_stays');
  end if;
  update public.residents set archived_at = case when p_archived then now() else null end where id = p_resident_id;
  perform private.audit(v_tenant_id, case when p_archived then 'resident.archived' else 'resident.restored' end, 'resident', p_resident_id);
end;
$$;

-- =============================================================================
-- Stays (bed assignment, transfer, move-out) and rent agreements
-- =============================================================================

-- p_data: { move_in_date?, monthly_rent_paise?, deposit_paise?, billing_day?,
--           expected_move_out_date?, notes?, deposit_collected_paise?, deposit_method? }
create or replace function public.assign_bed(p_resident_id uuid, p_bed_id uuid, p_data jsonb default '{}'::jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_resident public.residents;
  v_bed public.beds;
  v_room public.rooms;
  v_property public.properties;
  v_tenant_settings public.tenant_settings;
  v_billing_day smallint;
  v_stay_id uuid;
  v_move_in date := coalesce((private.clean_text(p_data ->> 'move_in_date'))::date, private.today());
  v_rent bigint;
  v_deposit bigint;
  v_collected bigint := private.to_paise(p_data -> 'deposit_collected_paise', 'Deposit collected');
begin
  select * into v_resident from public.residents r where r.id = p_resident_id;
  perform private.require_write(v_resident.tenant_id, private.r_ops());

  select * into v_bed from public.beds b where b.id = p_bed_id for update;
  if v_bed.id is null or v_bed.tenant_id <> v_resident.tenant_id then
    perform private.fail('Bed not found', 'not_found', 'P0002');
  end if;
  select * into v_room from public.rooms r where r.id = v_bed.room_id;
  select * into v_property from public.properties p where p.id = v_bed.property_id;
  select * into v_tenant_settings from public.tenant_settings s where s.tenant_id = v_resident.tenant_id;

  if v_resident.archived_at is not null then
    perform private.fail('This resident is archived. Restore them before assigning a bed.');
  end if;
  if v_property.status <> 'active' or not v_room.is_active then
    perform private.fail('This room or property is not active');
  end if;
  if v_bed.is_unavailable then
    perform private.fail('This bed is marked unavailable', 'bed_unavailable');
  end if;
  if exists (select 1 from public.stays s where s.resident_id = p_resident_id and s.status = 'active') then
    perform private.fail('This resident already has a bed. Use transfer to move them.', 'resident_has_active_stay');
  end if;
  if exists (select 1 from public.stays s where s.bed_id = p_bed_id and s.status = 'active') then
    perform private.fail('This bed is already occupied', 'bed_occupied');
  end if;
  if v_move_in > private.today() + 365 then
    perform private.fail('Move-in date is too far in the future');
  end if;

  v_rent := coalesce(private.to_paise(p_data -> 'monthly_rent_paise', 'Monthly rent'), private.suggested_bed_rent(p_bed_id), 0);
  v_deposit := coalesce(private.to_paise(p_data -> 'deposit_paise', 'Deposit'),
                        nullif(v_room.deposit_paise, 0), v_tenant_settings.default_deposit_paise, 0);
  v_billing_day := coalesce(
    (p_data ->> 'billing_day')::smallint,
    (select ps.billing_day from public.property_settings ps where ps.property_id = v_bed.property_id),
    v_tenant_settings.default_billing_day,
    1);
  if v_rent < 0 or v_deposit < 0 then
    perform private.fail('Rent and deposit cannot be negative');
  end if;

  begin
    insert into public.stays (tenant_id, resident_id, property_id, bed_id, move_in_date, expected_move_out_date, notes, created_by)
    values (
      v_resident.tenant_id, p_resident_id, v_bed.property_id, p_bed_id, v_move_in,
      (private.clean_text(p_data ->> 'expected_move_out_date'))::date,
      private.clean_text(p_data ->> 'notes'),
      auth.uid()
    )
    returning id into v_stay_id;
  exception when unique_violation then
    -- Lost a race with a concurrent assignment.
    perform private.fail('This bed or resident was just assigned by someone else. Refresh and try again.', 'bed_occupied');
  end;

  insert into public.rent_agreements (tenant_id, resident_id, stay_id, monthly_rent_paise, deposit_paise, billing_day, effective_from, created_by)
  values (v_resident.tenant_id, p_resident_id, v_stay_id, v_rent, v_deposit, v_billing_day, v_move_in, auth.uid());

  if coalesce(v_collected, 0) > 0 then
    insert into public.deposit_transactions (tenant_id, resident_id, stay_id, kind, amount_paise, txn_date, method, idempotency_key, recorded_by, notes)
    values (
      v_resident.tenant_id, p_resident_id, v_stay_id, 'collected', v_collected, v_move_in,
      coalesce((p_data ->> 'deposit_method')::public.payment_method, 'cash'),
      gen_random_uuid(), auth.uid(), 'Collected at move-in'
    );
    perform private.audit(v_resident.tenant_id, 'deposit.collected', 'resident', p_resident_id,
      jsonb_build_object('amount_paise', v_collected));
  end if;

  perform private.audit(v_resident.tenant_id, 'stay.started', 'stay', v_stay_id,
    jsonb_build_object('resident_id', p_resident_id, 'bed_id', p_bed_id, 'monthly_rent_paise', v_rent, 'deposit_paise', v_deposit));
  return v_stay_id;
exception
  when invalid_datetime_format or datetime_field_overflow then
    perform private.fail('One of the dates is not valid');
end;
$$;

create or replace function public.end_stay(p_stay_id uuid, p_move_out_date date, p_notes text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stay public.stays;
begin
  select * into v_stay from public.stays s where s.id = p_stay_id for update;
  perform private.require_write(v_stay.tenant_id, private.r_ops());
  if v_stay.status <> 'active' then
    perform private.fail('This stay has already ended');
  end if;
  if p_move_out_date is null or p_move_out_date < v_stay.move_in_date then
    perform private.fail('Move-out date must be on or after the move-in date');
  end if;
  update public.stays
     set status = 'ended',
         move_out_date = p_move_out_date,
         notes = coalesce(private.clean_text(p_notes), notes)
   where id = p_stay_id;
  -- effective_to is exclusive: the agreement covered [effective_from, effective_to).
  update public.rent_agreements
     set effective_to = greatest(p_move_out_date, effective_from)
   where stay_id = p_stay_id and effective_to is null;
  perform private.audit(v_stay.tenant_id, 'stay.ended', 'stay', p_stay_id,
    jsonb_build_object('resident_id', v_stay.resident_id, 'move_out_date', p_move_out_date));
end;
$$;

create or replace function public.transfer_bed(p_stay_id uuid, p_new_bed_id uuid, p_transfer_date date, p_monthly_rent_paise bigint default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stay public.stays;
  v_agreement public.rent_agreements;
  v_new_stay uuid;
begin
  select * into v_stay from public.stays s where s.id = p_stay_id;
  perform private.require_write(v_stay.tenant_id, private.r_ops());
  if v_stay.status <> 'active' then
    perform private.fail('Only an active stay can be transferred');
  end if;
  if v_stay.bed_id = p_new_bed_id then
    perform private.fail('Choose a different bed');
  end if;
  select * into v_agreement from public.rent_agreements a where a.stay_id = p_stay_id and a.effective_to is null;

  perform public.end_stay(p_stay_id, p_transfer_date, 'Transferred to another bed');
  v_new_stay := public.assign_bed(
    v_stay.resident_id,
    p_new_bed_id,
    jsonb_build_object(
      'move_in_date', p_transfer_date,
      'monthly_rent_paise', coalesce(p_monthly_rent_paise, v_agreement.monthly_rent_paise),
      'deposit_paise', v_agreement.deposit_paise,
      'billing_day', v_agreement.billing_day,
      'expected_move_out_date', v_stay.expected_move_out_date
    ));
  -- Deposit held moves with the resident; the ledger is per resident.
  return v_new_stay;
end;
$$;

create or replace function public.change_rent(p_stay_id uuid, p_monthly_rent_paise bigint, p_effective_from date, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stay public.stays;
  v_current public.rent_agreements;
  v_new_id uuid;
begin
  select * into v_stay from public.stays s where s.id = p_stay_id;
  perform private.require_write(v_stay.tenant_id, private.r_ops());
  if v_stay.status <> 'active' then
    perform private.fail('Rent can only be changed for an active stay');
  end if;
  if p_monthly_rent_paise is null or p_monthly_rent_paise < 0 then
    perform private.fail('Enter a valid monthly rent');
  end if;
  select * into v_current from public.rent_agreements a where a.stay_id = p_stay_id and a.effective_to is null for update;
  if p_effective_from is null or p_effective_from < v_current.effective_from then
    perform private.fail('The new rent must start on or after the current agreement start date');
  end if;

  -- Close the current agreement; it stays in history unchanged otherwise.
  update public.rent_agreements set effective_to = p_effective_from where id = v_current.id;
  insert into public.rent_agreements (tenant_id, resident_id, stay_id, monthly_rent_paise, deposit_paise, billing_day, effective_from, note, created_by)
  values (v_stay.tenant_id, v_stay.resident_id, p_stay_id, p_monthly_rent_paise, v_current.deposit_paise,
          v_current.billing_day, p_effective_from, private.clean_text(p_note), auth.uid())
  returning id into v_new_id;

  perform private.audit(v_stay.tenant_id, 'rent.changed', 'stay', p_stay_id,
    jsonb_build_object('from_paise', v_current.monthly_rent_paise, 'to_paise', p_monthly_rent_paise, 'effective_from', p_effective_from));
  return v_new_id;
end;
$$;

-- =============================================================================
-- Additional charges
-- =============================================================================
create or replace function public.save_charge_template(p_tenant_id uuid, p_charge_id uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := p_tenant_id;
  v_id uuid := p_charge_id;
begin
  if v_id is not null then
    select c.tenant_id into v_tenant_id from public.charge_templates c where c.id = v_id;
  end if;
  perform private.require_write(v_tenant_id, private.r_ops());
  if v_id is null then
    insert into public.charge_templates (tenant_id, property_id, name, amount_paise, frequency, apply_by_default)
    values (
      v_tenant_id,
      (private.clean_text(p_data ->> 'property_id'))::uuid,
      private.clean_text(p_data ->> 'name'),
      private.to_paise(p_data -> 'amount_paise', 'Amount'),
      coalesce(private.clean_text(p_data ->> 'frequency'), 'monthly'),
      coalesce((p_data ->> 'apply_by_default')::boolean, false)
    )
    returning id into v_id;
  else
    update public.charge_templates c set
      name = case when p_data ? 'name' then private.clean_text(p_data ->> 'name') else c.name end,
      amount_paise = case when p_data ? 'amount_paise' then private.to_paise(p_data -> 'amount_paise', 'Amount') else c.amount_paise end,
      frequency = case when p_data ? 'frequency' then private.clean_text(p_data ->> 'frequency') else c.frequency end,
      apply_by_default = case when p_data ? 'apply_by_default' then (p_data ->> 'apply_by_default')::boolean else c.apply_by_default end,
      is_active = case when p_data ? 'is_active' then (p_data ->> 'is_active')::boolean else c.is_active end
    where c.id = v_id;
  end if;
  perform private.audit(v_tenant_id, 'charge_template.saved', 'charge_template', v_id);
  return v_id;
exception
  when not_null_violation or check_violation then
    perform private.fail('Charge name (2–80 characters) and a positive amount are required');
  when foreign_key_violation then
    perform private.fail('Property not found', 'not_found', 'P0002');
end;
$$;

create or replace function public.delete_charge_template(p_charge_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  select c.tenant_id into v_tenant_id from public.charge_templates c where c.id = p_charge_id;
  perform private.require_write(v_tenant_id, private.r_ops());
  delete from public.charge_templates where id = p_charge_id;
  perform private.audit(v_tenant_id, 'charge_template.deleted', 'charge_template', p_charge_id);
end;
$$;
