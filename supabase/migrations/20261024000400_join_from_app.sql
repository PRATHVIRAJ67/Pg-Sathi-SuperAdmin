-- =============================================================================
-- Joining a PG from the resident app.
--
-- The student scans the PG's join QR in the app, creates their own login
-- (email + password, verified with an email code), and sends the join request
-- while signed in. The request remembers that login (join_requests.user_id).
-- When the owner approves, the new resident is linked to that login, so the
-- app opens straight away: no "Give app login" step and no password sharing.
-- Requests from the web form (no login) work exactly as before.
-- =============================================================================

alter table public.join_requests add column user_id uuid references auth.users (id) on delete set null;
create index join_requests_user_idx on public.join_requests (user_id) where user_id is not null;

create or replace function public.submit_join_request(p_code text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link public.join_links;
  v_tenant public.tenants;
  v_uid uuid := auth.uid();
  v_name text := private.clean_text(p_data ->> 'full_name');
  v_phone text := private.check_phone(p_data ->> 'phone');
  v_email text := private.check_email(p_data ->> 'email');
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

  if v_uid is not null then
    if exists (select 1 from public.resident_user_links l where l.tenant_id = v_link.tenant_id and l.user_id = v_uid) then
      perform private.fail('You already stay at this PG. Open the app’s home screen to see your room.', 'duplicate');
    end if;
    -- The login's own email is the one that counts.
    select coalesce(v_email, lower(u.email)) into v_email from auth.users u where u.id = v_uid;
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
   where r.tenant_id = v_link.tenant_id and r.status = 'pending'
     and (r.phone = v_phone or (v_uid is not null and r.user_id = v_uid))
   order by r.created_at desc limit 1
   for update;

  if v_existing is null then
    insert into public.join_requests (
      tenant_id, link_id, property_id, full_name, phone, email, gender, date_of_birth, occupation, organization,
      id_proof_type, id_proof_number, permanent_address, emergency_contact_name, emergency_contact_phone,
      emergency_contact_relation, preferred_move_in, room_preference, note, user_id
    ) values (
      v_link.tenant_id, v_link.id, v_property, v_name, v_phone, v_email,
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
      private.clean_text(p_data ->> 'note'),
      v_uid
    )
    returning id into v_existing;
    perform private.audit(v_link.tenant_id, 'join_request.received', 'join_request', v_existing,
      jsonb_build_object('name', v_name, 'from_app', v_uid is not null));
  else
    update public.join_requests r set
      link_id = v_link.id, property_id = v_property, full_name = v_name, phone = v_phone,
      email = v_email,
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
      user_id = coalesce(v_uid, r.user_id),
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

/**
 * As before, and: a request sent from the app is linked to the sender's
 * login, so the resident can use the app as soon as they are approved.
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

  -- Sent from the app: give that login access to this resident.
  if v_req.user_id is not null
     and not exists (select 1 from public.resident_user_links l where l.tenant_id = v_req.tenant_id and l.user_id = v_req.user_id) then
    insert into public.resident_user_links (tenant_id, resident_id, user_id) values (v_req.tenant_id, v_resident, v_req.user_id);
    perform private.audit(v_req.tenant_id, 'resident.app_access_granted', 'resident', v_resident,
      jsonb_build_object('via', 'join_request'));
  end if;

  update public.join_requests r set status = 'approved', resident_id = v_resident, reviewed_by = auth.uid(),
         reviewed_at = now(), updated_at = now()
   where r.id = p_request_id;
  perform private.audit(v_req.tenant_id, 'join_request.approved', 'join_request', p_request_id, jsonb_build_object('resident_id', v_resident));
  return v_resident;
end;
$$;

/** The signed-in person's own join requests (the app's "waiting for approval" screen). */
create or replace function public.my_join_requests()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_auth();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id, 'status', r.status, 'created_at', r.created_at, 'reviewed_at', r.reviewed_at,
      'reject_reason', r.reject_reason, 'business_name', t.name, 'property_name', p.name,
      'contact_phone', t.contact_phone
    ) order by r.created_at desc)
    from public.join_requests r
    join public.tenants t on t.id = r.tenant_id
    left join public.properties p on p.id = r.property_id
    where r.user_id = auth.uid()), '[]'::jsonb);
end;
$$;

/** Owner list, now saying whether approval also opens the app for them. */
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
      'from_app', r.user_id is not null,
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

revoke execute on function public.my_join_requests() from public, anon;
grant execute on function public.my_join_requests() to authenticated;
