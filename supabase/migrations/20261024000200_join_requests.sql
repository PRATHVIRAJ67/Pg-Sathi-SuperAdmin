-- =============================================================================
-- Self-registration by QR code.
--
-- The owner creates a join link (for the whole business or one property) and
-- prints its QR code. Someone coming to stay scans it, fills in their details
-- on a public form (no account needed), and a join request appears in the
-- owner dashboard. The owner approves it, which creates the resident through
-- save_resident (same checks and plan limits as adding one by hand), and then
-- assigns a bed and rent as usual. Adding residents by hand is unchanged.
--
-- The public form can only call join_link_info and submit_join_request, and
-- only with an active link code. It can never read anything back.
-- =============================================================================

create table public.join_links (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  property_id uuid,
  code text not null unique check (code ~ '^[a-z0-9]{10,32}$'),
  is_active boolean not null default true,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete cascade
);
create index join_links_tenant_idx on public.join_links (tenant_id);

create type public.join_request_status as enum ('pending', 'approved', 'rejected');

create table public.join_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants (id) on delete cascade,
  link_id uuid,
  property_id uuid,
  status public.join_request_status not null default 'pending',
  full_name text not null check (char_length(full_name) between 2 and 120),
  phone text not null check (char_length(phone) between 6 and 20),
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
  preferred_move_in date,
  room_preference text check (char_length(room_preference) <= 60),
  note text check (char_length(note) <= 500),
  resident_id uuid,
  reviewed_by uuid references auth.users (id) on delete set null,
  reviewed_at timestamptz,
  reject_reason text check (char_length(reject_reason) <= 300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, id),
  foreign key (tenant_id, link_id) references public.join_links (tenant_id, id) on delete set null (link_id),
  foreign key (tenant_id, property_id) references public.properties (tenant_id, id) on delete set null (property_id),
  foreign key (tenant_id, resident_id) references public.residents (tenant_id, id) on delete set null (resident_id)
);
create index join_requests_tenant_idx on public.join_requests (tenant_id, status, created_at desc);
create index join_requests_phone_idx on public.join_requests (tenant_id, phone) where status = 'pending';
create index join_requests_link_recent_idx on public.join_requests (link_id, created_at desc);

alter table public.join_links enable row level security;
alter table public.join_requests enable row level security;
create policy join_links_select on public.join_links for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()));
create policy join_requests_select on public.join_requests for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()));
revoke all on public.join_links, public.join_requests from anon, authenticated;
grant select on public.join_links, public.join_requests to authenticated;

create or replace function private.new_join_code()
returns text
language sql
volatile
set search_path = ''
as $$
  select substr(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 1, 14);
$$;

-- ---------------------------------------------------------------------------
-- Public form (anon or signed in)
-- ---------------------------------------------------------------------------

/** What the public form shows at the top: whose PG this is. */
create or replace function public.join_link_info(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_link public.join_links;
  v_tenant public.tenants;
begin
  select * into v_link from public.join_links l where l.code = lower(btrim(coalesce(p_code, ''))) and l.is_active;
  if v_link.id is not null then
    select * into v_tenant from public.tenants t where t.id = v_link.tenant_id;
  end if;
  if v_link.id is null or v_tenant.status in ('suspended', 'cancelled') then
    perform private.fail('This link is no longer active. Ask the PG for a new QR code.', 'not_found', 'P0002');
  end if;
  return jsonb_build_object(
    'business_name', v_tenant.name,
    'city', v_tenant.city,
    'contact_phone', v_tenant.contact_phone,
    'property', (select jsonb_build_object('id', p.id, 'name', p.name, 'locality', p.locality, 'city', p.city, 'gender_policy', p.gender_policy)
                   from public.properties p where p.id = v_link.property_id),
    'properties', case when v_link.property_id is null then coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'locality', p.locality, 'gender_policy', p.gender_policy) order by p.name)
        from public.properties p where p.tenant_id = v_link.tenant_id and p.status = 'active'), '[]'::jsonb) else '[]'::jsonb end
  );
end;
$$;

create or replace function public.submit_join_request(p_code text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link public.join_links;
  v_tenant public.tenants;
  v_name text := private.clean_text(p_data ->> 'full_name');
  v_phone text := private.check_phone(p_data ->> 'phone');
  v_property uuid;
  v_move_in date;
  v_existing uuid;
begin
  select * into v_link from public.join_links l where l.code = lower(btrim(coalesce(p_code, ''))) and l.is_active;
  if v_link.id is not null then
    select * into v_tenant from public.tenants t where t.id = v_link.tenant_id;
  end if;
  if v_link.id is null or v_tenant.status in ('suspended', 'cancelled') then
    perform private.fail('This link is no longer active. Ask the PG for a new QR code.', 'not_found', 'P0002');
  end if;

  -- Simple abuse limits for a public form.
  if (select count(*) from public.join_requests r where r.link_id = v_link.id and r.created_at > now() - interval '10 minutes') >= 20 then
    perform private.fail('Too many requests right now. Please try again in a few minutes.', 'rate_limited');
  end if;
  if (select count(*) from public.join_requests r where r.tenant_id = v_link.tenant_id and r.status = 'pending') >= 300 then
    perform private.fail('This PG is not taking new requests right now. Please contact them directly.', 'rate_limited');
  end if;

  if v_name is null or char_length(v_name) < 2 then
    perform private.fail('Enter your full name.');
  end if;
  if v_phone is null then
    perform private.fail('Enter your phone number so the PG can contact you.');
  end if;

  v_property := coalesce(v_link.property_id, nullif(p_data ->> 'property_id', '')::uuid);
  if v_property is not null and not exists (
    select 1 from public.properties p where p.id = v_property and p.tenant_id = v_link.tenant_id and p.status = 'active'
  ) then
    v_property := null;
  end if;
  v_move_in := (private.clean_text(p_data ->> 'preferred_move_in'))::date;
  if v_move_in is not null and (v_move_in < private.today() - 60 or v_move_in > private.today() + 365) then
    perform private.fail('Choose a move-in date within the next year.');
  end if;

  -- The same person submitting again updates their pending request.
  select r.id into v_existing from public.join_requests r
   where r.tenant_id = v_link.tenant_id and r.phone = v_phone and r.status = 'pending'
   for update;

  if v_existing is null then
    insert into public.join_requests (
      tenant_id, link_id, property_id, full_name, phone, email, gender, date_of_birth, occupation, organization,
      id_proof_type, id_proof_number, permanent_address, emergency_contact_name, emergency_contact_phone,
      emergency_contact_relation, preferred_move_in, room_preference, note
    ) values (
      v_link.tenant_id, v_link.id, v_property, v_name, v_phone,
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
      v_move_in,
      private.clean_text(p_data ->> 'room_preference'),
      private.clean_text(p_data ->> 'note')
    )
    returning id into v_existing;
    perform private.audit(v_link.tenant_id, 'join_request.received', 'join_request', v_existing, jsonb_build_object('name', v_name));
  else
    update public.join_requests r set
      link_id = v_link.id, property_id = v_property, full_name = v_name,
      email = private.check_email(p_data ->> 'email'),
      gender = private.clean_text(p_data ->> 'gender'),
      date_of_birth = (private.clean_text(p_data ->> 'date_of_birth'))::date,
      occupation = private.clean_text(p_data ->> 'occupation'),
      organization = private.clean_text(p_data ->> 'organization'),
      id_proof_type = private.clean_text(p_data ->> 'id_proof_type'),
      id_proof_number = private.clean_text(p_data ->> 'id_proof_number'),
      permanent_address = private.clean_text(p_data ->> 'permanent_address'),
      emergency_contact_name = private.clean_text(p_data ->> 'emergency_contact_name'),
      emergency_contact_phone = private.check_phone(p_data ->> 'emergency_contact_phone', 'Emergency contact phone'),
      emergency_contact_relation = private.clean_text(p_data ->> 'emergency_contact_relation'),
      preferred_move_in = v_move_in,
      room_preference = private.clean_text(p_data ->> 'room_preference'),
      note = private.clean_text(p_data ->> 'note'),
      updated_at = now()
    where r.id = v_existing;
  end if;
  -- Nothing is returned that could reveal other people's data.
  return jsonb_build_object('ok', true, 'business_name', v_tenant.name);
exception
  when check_violation then
    perform private.fail('Some details are too long or invalid. Please check and try again.');
  when invalid_datetime_format or datetime_field_overflow or invalid_text_representation then
    perform private.fail('Some details are not valid. Check the dates and try again.');
end;
$$;

-- ---------------------------------------------------------------------------
-- Owner dashboard
-- ---------------------------------------------------------------------------
create or replace function public.list_join_links(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_role(p_tenant_id, private.r_ops());
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', l.id, 'code', l.code, 'property_id', l.property_id, 'property_name', p.name,
      'is_active', l.is_active, 'created_at', l.created_at,
      'requests', (select count(*) from public.join_requests r where r.link_id = l.id)
    ) order by p.name nulls first, l.created_at)
    from public.join_links l left join public.properties p on p.id = l.property_id
    where l.tenant_id = p_tenant_id), '[]'::jsonb);
end;
$$;

/** One link per property (or one for the whole business); returns the existing one if there is. */
create or replace function public.create_join_link(p_tenant_id uuid, p_property_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform private.require_write(p_tenant_id, private.r_ops());
  if p_property_id is not null and not exists (select 1 from public.properties p where p.id = p_property_id and p.tenant_id = p_tenant_id) then
    perform private.fail('Property not found', 'not_found', 'P0002');
  end if;
  select l.id into v_id from public.join_links l
   where l.tenant_id = p_tenant_id and l.property_id is not distinct from p_property_id
   order by l.is_active desc, l.created_at desc limit 1;
  if v_id is not null then
    update public.join_links l set is_active = true, updated_at = now() where l.id = v_id;
    return v_id;
  end if;
  insert into public.join_links (tenant_id, property_id, code, created_by)
  values (p_tenant_id, p_property_id, private.new_join_code(), auth.uid())
  returning id into v_id;
  perform private.audit(p_tenant_id, 'join_link.created', 'join_link', v_id, jsonb_build_object('property_id', p_property_id));
  return v_id;
end;
$$;

create or replace function public.set_join_link_active(p_link_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  select l.tenant_id into v_tenant from public.join_links l where l.id = p_link_id;
  perform private.require_write(v_tenant, private.r_ops());
  update public.join_links l set is_active = coalesce(p_active, false), updated_at = now() where l.id = p_link_id;
  perform private.audit(v_tenant, case when p_active then 'join_link.enabled' else 'join_link.disabled' end, 'join_link', p_link_id);
end;
$$;

/** New code: the old QR stops working (e.g. a photo of it was shared too widely). */
create or replace function public.regenerate_join_link(p_link_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  select l.tenant_id into v_tenant from public.join_links l where l.id = p_link_id;
  perform private.require_write(v_tenant, private.r_ops());
  update public.join_links l set code = private.new_join_code(), is_active = true, updated_at = now() where l.id = p_link_id;
  perform private.audit(v_tenant, 'join_link.regenerated', 'join_link', p_link_id);
end;
$$;

create or replace function public.list_join_requests(p_tenant_id uuid, p_status text default 'pending')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_role(p_tenant_id, private.r_ops());
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id, 'status', r.status, 'created_at', r.created_at, 'updated_at', r.updated_at,
      'full_name', r.full_name, 'phone', r.phone, 'email', r.email, 'gender', r.gender,
      'date_of_birth', r.date_of_birth, 'occupation', r.occupation, 'organization', r.organization,
      'id_proof_type', r.id_proof_type, 'id_proof_number', r.id_proof_number,
      'permanent_address', r.permanent_address,
      'emergency_contact_name', r.emergency_contact_name, 'emergency_contact_phone', r.emergency_contact_phone,
      'emergency_contact_relation', r.emergency_contact_relation,
      'preferred_move_in', r.preferred_move_in, 'room_preference', r.room_preference, 'note', r.note,
      'property_id', r.property_id, 'property_name', p.name,
      'resident_id', r.resident_id, 'reviewed_at', r.reviewed_at, 'reject_reason', r.reject_reason,
      -- Someone with this phone number is already a resident here.
      'existing_resident', (select jsonb_build_object('id', x.id, 'full_name', x.full_name)
                              from public.residents x where x.tenant_id = r.tenant_id and x.phone = r.phone and x.archived_at is null
                              order by x.created_at desc limit 1)
    ) order by r.created_at desc)
    from public.join_requests r left join public.properties p on p.id = r.property_id
    where r.tenant_id = p_tenant_id
      and (p_status = 'all' or r.status::text = p_status)
    limit 200), '[]'::jsonb);
end;
$$;

/**
 * Approves a request: creates the resident with save_resident (so the usual
 * validation and plan limits apply), using any corrections the owner made.
 * Returns the new resident's id so the dashboard can go straight to
 * assigning a bed. Approving twice returns the same resident.
 */
create or replace function public.approve_join_request(p_request_id uuid, p_data jsonb default '{}'::jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.join_requests;
  v_resident uuid;
  v_fields jsonb;
begin
  select * into v_req from public.join_requests r where r.id = p_request_id for update;
  perform private.require_write(v_req.tenant_id, private.r_ops());
  if v_req.status = 'approved' then
    return v_req.resident_id;
  end if;
  if v_req.status = 'rejected' then
    perform private.fail('This request was rejected.');
  end if;
  v_fields := jsonb_strip_nulls(jsonb_build_object(
    'full_name', v_req.full_name, 'phone', v_req.phone, 'email', v_req.email, 'gender', v_req.gender,
    'date_of_birth', v_req.date_of_birth, 'occupation', v_req.occupation, 'organization', v_req.organization,
    'id_proof_type', v_req.id_proof_type, 'id_proof_number', v_req.id_proof_number,
    'permanent_address', v_req.permanent_address,
    'emergency_contact_name', v_req.emergency_contact_name, 'emergency_contact_phone', v_req.emergency_contact_phone,
    'emergency_contact_relation', v_req.emergency_contact_relation,
    'notes', concat_ws(E'\n',
      'Joined by QR code' || coalesce(' on ' || to_char(v_req.created_at at time zone 'Asia/Kolkata', 'DD Mon YYYY'), ''),
      case when v_req.preferred_move_in is not null then 'Wants to move in: ' || to_char(v_req.preferred_move_in, 'DD Mon YYYY') end,
      case when v_req.room_preference is not null then 'Room preference: ' || v_req.room_preference end,
      v_req.note)
  )) || coalesce(p_data, '{}'::jsonb);
  v_resident := public.save_resident(v_req.tenant_id, null, v_fields);
  update public.join_requests r set status = 'approved', resident_id = v_resident, reviewed_by = auth.uid(),
         reviewed_at = now(), updated_at = now()
   where r.id = p_request_id;
  perform private.audit(v_req.tenant_id, 'join_request.approved', 'join_request', p_request_id, jsonb_build_object('resident_id', v_resident));
  return v_resident;
end;
$$;

create or replace function public.reject_join_request(p_request_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.join_requests;
begin
  select * into v_req from public.join_requests r where r.id = p_request_id for update;
  perform private.require_write(v_req.tenant_id, private.r_ops());
  if v_req.status <> 'pending' then
    perform private.fail('This request was already handled.');
  end if;
  update public.join_requests r set status = 'rejected', reject_reason = left(private.clean_text(p_reason), 300),
         reviewed_by = auth.uid(), reviewed_at = now(), updated_at = now()
   where r.id = p_request_id;
  perform private.audit(v_req.tenant_id, 'join_request.rejected', 'join_request', p_request_id);
end;
$$;

revoke all on function private.new_join_code() from public, anon, authenticated;

revoke execute on function public.join_link_info(text), public.submit_join_request(text, jsonb) from public;
grant execute on function public.join_link_info(text), public.submit_join_request(text, jsonb) to anon, authenticated;

revoke execute on function public.list_join_links(uuid), public.create_join_link(uuid, uuid), public.set_join_link_active(uuid, boolean),
  public.regenerate_join_link(uuid), public.list_join_requests(uuid, text), public.approve_join_request(uuid, jsonb),
  public.reject_join_request(uuid, text) from public, anon;
grant execute on function public.list_join_links(uuid), public.create_join_link(uuid, uuid), public.set_join_link_active(uuid, boolean),
  public.regenerate_join_link(uuid), public.list_join_requests(uuid, text), public.approve_join_request(uuid, jsonb),
  public.reject_join_request(uuid, text) to authenticated;
