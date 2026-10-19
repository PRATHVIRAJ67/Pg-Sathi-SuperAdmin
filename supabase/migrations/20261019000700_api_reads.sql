-- =============================================================================
-- Read API. All functions are SECURITY INVOKER: they run with the caller's
-- privileges, so RLS still filters every table they touch. Each one also
-- checks membership up front so unauthorised calls fail loudly instead of
-- silently returning empty data. Results are JSON shaped for the clients.
-- =============================================================================

create or replace function public.my_context()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_uid uuid := private.require_auth();
begin
  return jsonb_build_object(
    'user', coalesce(
      (select jsonb_build_object('id', p.id, 'full_name', p.full_name, 'email', p.email, 'phone', p.phone)
         from public.profiles p where p.id = v_uid),
      jsonb_build_object('id', v_uid)),
    'is_platform_admin', private.is_platform_admin(),
    'workspaces', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tenant_id', t.id, 'name', t.name, 'role', m.role, 'status', t.status,
               'onboarding_step', t.onboarding_step, 'onboarding_completed_at', t.onboarding_completed_at,
               'logo_path', t.logo_path) order by t.created_at)
        from public.tenant_memberships m
        join public.tenants t on t.id = m.tenant_id
       where m.user_id = v_uid and m.status = 'active'), '[]'::jsonb),
    'resident_links', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tenant_id', l.tenant_id, 'tenant_name', t.name,
               'resident_id', l.resident_id, 'resident_name', r.full_name))
        from public.resident_user_links l
        join public.tenants t on t.id = l.tenant_id
        join public.residents r on r.id = l.resident_id
       where l.user_id = v_uid), '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_workspace(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_role public.tenant_role := private.require_role(p_tenant_id, private.r_all());
begin
  return (
    select jsonb_build_object(
      'tenant', to_jsonb(t) - 'provision_request_id',
      'settings', to_jsonb(s),
      'subscription', to_jsonb(sub),
      'plan', to_jsonb(pl),
      'usage', jsonb_build_object(
        'properties', (select count(*) from public.properties p where p.tenant_id = t.id and p.status = 'active'),
        'residents', (select count(*) from public.residents r where r.tenant_id = t.id and r.archived_at is null),
        'staff', (select count(*) from public.tenant_memberships m where m.tenant_id = t.id and m.role <> 'owner' and m.status = 'active')
      ),
      'my_role', v_role
    )
    from public.tenants t
    join public.tenant_settings s on s.tenant_id = t.id
    left join public.subscriptions sub on sub.tenant_id = t.id
    left join public.plans pl on pl.id = sub.plan_id
    where t.id = p_tenant_id
  );
end;
$$;

create or replace function public.list_plans()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(p) order by p.sort_order, p.price_paise), '[]'::jsonb)
    from public.plans p
   where p.is_active and p.is_public;
$$;

-- -----------------------------------------------------------------------------
-- Properties, rooms, beds
-- -----------------------------------------------------------------------------
create or replace function public.list_properties(p_tenant_id uuid, p_include_archived boolean default false)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform private.require_role(p_tenant_id, private.r_all());
  return coalesce((
    select jsonb_agg(
             to_jsonb(p) || jsonb_build_object(
               'room_count', (select count(*) from public.rooms r where r.property_id = p.id),
               'bed_count', (select count(*) from public.beds b where b.property_id = p.id),
               'occupied_count', (select count(*) from public.stays s where s.property_id = p.id and s.status = 'active'),
               'unavailable_count', (select count(*) from public.beds b where b.property_id = p.id and b.is_unavailable)
             ) order by p.status, p.name)
      from public.properties p
     where p.tenant_id = p_tenant_id
       and (p_include_archived or p.status = 'active')), '[]'::jsonb);
end;
$$;

create or replace function public.get_property(p_property_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_property public.properties;
begin
  select * into v_property from public.properties p where p.id = p_property_id;
  perform private.require_role(v_property.tenant_id, private.r_all());
  return to_jsonb(v_property) || jsonb_build_object(
    'settings', (select to_jsonb(ps) from public.property_settings ps where ps.property_id = p_property_id),
    'room_count', (select count(*) from public.rooms r where r.property_id = p_property_id),
    'bed_count', (select count(*) from public.beds b where b.property_id = p_property_id),
    'occupied_count', (select count(*) from public.stays s where s.property_id = p_property_id and s.status = 'active'),
    'unavailable_count', (select count(*) from public.beds b where b.property_id = p_property_id and b.is_unavailable)
  );
end;
$$;

create or replace function public.list_rooms(p_tenant_id uuid, p_property_id uuid default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform private.require_role(p_tenant_id, private.r_all());
  return coalesce((
    select jsonb_agg(
             to_jsonb(r) || jsonb_build_object(
               'property_name', p.name,
               'beds', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'id', b.id,
                          'label', b.label,
                          'rent_paise', b.rent_paise,
                          'suggested_rent_paise', coalesce(
                            b.rent_paise,
                            case when r.rent_mode = 'per_bed' then r.rent_paise
                                 else round(r.rent_paise::numeric / greatest((select count(*) from public.beds x where x.room_id = r.id), 1))::bigint end),
                          'is_unavailable', b.is_unavailable,
                          'unavailable_reason', b.unavailable_reason,
                          'status', case when b.is_unavailable then 'unavailable' when s.id is not null then 'occupied' else 'vacant' end,
                          'occupant', case when s.id is not null then jsonb_build_object(
                            'stay_id', s.id, 'resident_id', s.resident_id, 'full_name', res.full_name, 'move_in_date', s.move_in_date) end
                        ) order by b.sort_order, b.label), '[]'::jsonb)
                   from public.beds b
                   left join public.stays s on s.bed_id = b.id and s.status = 'active'
                   left join public.residents res on res.id = s.resident_id
                  where b.room_id = r.id)
             ) order by p.name, char_length(r.name), r.name)
      from public.rooms r
      join public.properties p on p.id = r.property_id
     where r.tenant_id = p_tenant_id
       and p.status = 'active'
       and (p_property_id is null or r.property_id = p_property_id)), '[]'::jsonb);
end;
$$;

-- -----------------------------------------------------------------------------
-- Residents
-- -----------------------------------------------------------------------------
-- p_params: { search?, property_id?, status?: current|active|unassigned|moved_out|archived|all,
--             sort?: name|outstanding|move_in, limit?, offset? }
create or replace function public.list_residents(p_tenant_id uuid, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_role public.tenant_role := private.require_role(p_tenant_id, private.r_all());
  v_fin boolean := v_role = any (private.r_finance());
  v_search text := lower(private.clean_text(p_params ->> 'search'));
  v_property uuid := (private.clean_text(p_params ->> 'property_id'))::uuid;
  v_status text := coalesce(private.clean_text(p_params ->> 'status'), 'current');
  v_sort text := coalesce(private.clean_text(p_params ->> 'sort'), 'name');
  v_limit integer := least(greatest(coalesce((p_params ->> 'limit')::integer, 50), 1), 500);
  v_offset integer := greatest(coalesce((p_params ->> 'offset')::integer, 0), 0);
  v_today date := private.today();
  v_result jsonb;
begin
  with inv as (
    select i.resident_id,
           sum(i.total_paise - i.paid_paise) filter (where i.status = 'issued') as outstanding,
           sum(i.total_paise - i.paid_paise) filter (where i.status = 'issued' and i.due_date < v_today) as overdue
      from public.invoices i
     where i.tenant_id = p_tenant_id
     group by i.resident_id
  ),
  alloc as (
    select a.payment_id, sum(a.amount_paise) as allocated
      from public.payment_allocations a
     where a.tenant_id = p_tenant_id and a.voided_at is null
     group by a.payment_id
  ),
  credit as (
    select p.resident_id, sum(p.amount_paise - coalesce(al.allocated, 0)) as credit
      from public.payments p
      left join alloc al on al.payment_id = p.id
     where p.tenant_id = p_tenant_id and p.status in ('recorded', 'succeeded')
     group by p.resident_id
  ),
  dep as (
    select d.resident_id, sum(case when d.kind = 'collected' then d.amount_paise else -d.amount_paise end) as held
      from public.deposit_transactions d
     where d.tenant_id = p_tenant_id
     group by d.resident_id
  ),
  base as (
    select r.id, r.full_name, r.phone, r.email, r.gender, r.occupation, r.archived_at, r.created_at,
           s.id as stay_id, s.property_id, s.bed_id, s.move_in_date, s.expected_move_out_date,
           pr.name as property_name, rm.id as room_id, rm.name as room_name, b.label as bed_label,
           (select a.monthly_rent_paise from public.rent_agreements a where a.stay_id = s.id and a.effective_to is null) as monthly_rent_paise,
           case
             when r.archived_at is not null then 'archived'
             when s.id is not null then 'active'
             when exists (select 1 from public.stays s2 where s2.resident_id = r.id) then 'moved_out'
             else 'unassigned'
           end as status,
           coalesce(inv.outstanding, 0) as outstanding_paise,
           coalesce(inv.overdue, 0) as overdue_paise,
           coalesce(credit.credit, 0) as credit_paise,
           coalesce(dep.held, 0) as deposit_held_paise
      from public.residents r
      left join public.stays s on s.resident_id = r.id and s.status = 'active'
      left join public.properties pr on pr.id = s.property_id
      left join public.beds b on b.id = s.bed_id
      left join public.rooms rm on rm.id = b.room_id
      left join inv on inv.resident_id = r.id
      left join credit on credit.resident_id = r.id
      left join dep on dep.resident_id = r.id
     where r.tenant_id = p_tenant_id
  ),
  filtered as (
    select * from base
     where (v_search is null
            or lower(full_name) like '%' || v_search || '%'
            or coalesce(phone, '') like '%' || v_search || '%'
            or lower(coalesce(email, '')) like '%' || v_search || '%'
            or lower(coalesce(room_name, '')) = v_search)
       and (v_property is null or property_id = v_property)
       and case v_status
             when 'current' then status in ('active', 'unassigned')
             when 'all' then status <> 'archived'
             else status = v_status
           end
  ),
  paged as (
    select * from filtered
     order by
       case when v_sort = 'outstanding' then outstanding_paise end desc nulls last,
       case when v_sort = 'move_in' then move_in_date end desc nulls last,
       lower(full_name)
     limit v_limit offset v_offset
  )
  select jsonb_build_object(
           'total', (select count(*) from filtered),
           'rows', coalesce((
             select jsonb_agg(
                      jsonb_build_object(
                        'id', id, 'full_name', full_name, 'phone', phone, 'email', email, 'gender', gender,
                        'occupation', occupation, 'archived_at', archived_at, 'created_at', created_at,
                        'status', status,
                        'stay', case when stay_id is not null then jsonb_build_object(
                          'stay_id', stay_id, 'property_id', property_id, 'property_name', property_name,
                          'room_id', room_id, 'room_name', room_name, 'bed_id', bed_id, 'bed_label', bed_label,
                          'move_in_date', move_in_date, 'expected_move_out_date', expected_move_out_date) end,
                        'monthly_rent_paise', case when v_fin then monthly_rent_paise end,
                        'outstanding_paise', case when v_fin then outstanding_paise end,
                        'overdue_paise', case when v_fin then overdue_paise end,
                        'credit_paise', case when v_fin then credit_paise end,
                        'deposit_held_paise', case when v_fin then deposit_held_paise end
                      ) order by
                        case when v_sort = 'outstanding' then outstanding_paise end desc nulls last,
                        case when v_sort = 'move_in' then move_in_date end desc nulls last,
                        lower(full_name))
               from paged), '[]'::jsonb)
         )
    into v_result;
  return v_result;
end;
$$;

create or replace function public.get_resident(p_resident_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_resident public.residents;
  v_role public.tenant_role;
  v_self boolean;
  v_fin boolean;
  v_today date := private.today();
  v_status text;
begin
  select * into v_resident from public.residents r where r.id = p_resident_id;
  if v_resident.id is null then
    perform private.fail('Resident not found', 'not_found', 'P0002');
  end if;
  v_role := private.member_role(v_resident.tenant_id);
  v_self := p_resident_id in (select private.my_resident_ids());
  if v_role is null and not v_self then
    perform private.fail('Resident not found', 'not_found', 'P0002');
  end if;
  v_fin := v_self or v_role = any (private.r_finance());

  v_status := case
    when v_resident.archived_at is not null then 'archived'
    when exists (select 1 from public.stays s where s.resident_id = p_resident_id and s.status = 'active') then 'active'
    when exists (select 1 from public.stays s where s.resident_id = p_resident_id) then 'moved_out'
    else 'unassigned' end;

  return to_jsonb(v_resident) || jsonb_build_object(
    'status', v_status,
    'stays', coalesce((
      select jsonb_agg(to_jsonb(s) || jsonb_build_object(
               'property_name', p.name, 'room_id', rm.id, 'room_name', rm.name, 'bed_label', b.label,
               'agreements', coalesce((
                 select jsonb_agg(to_jsonb(a) order by a.effective_from desc)
                   from public.rent_agreements a where a.stay_id = s.id), '[]'::jsonb)
             ) order by s.move_in_date desc, s.created_at desc)
        from public.stays s
        join public.properties p on p.id = s.property_id
        join public.beds b on b.id = s.bed_id
        join public.rooms rm on rm.id = b.room_id
       where s.resident_id = p_resident_id), '[]'::jsonb),
    'finance_visible', v_fin,
    'balance', case when v_fin then jsonb_build_object(
      'invoiced_paise', coalesce((select sum(i.total_paise) from public.invoices i where i.resident_id = p_resident_id and i.status = 'issued'), 0),
      'paid_paise', coalesce((select sum(i.paid_paise) from public.invoices i where i.resident_id = p_resident_id and i.status = 'issued'), 0),
      'outstanding_paise', coalesce((select sum(i.total_paise - i.paid_paise) from public.invoices i where i.resident_id = p_resident_id and i.status = 'issued'), 0),
      'overdue_paise', coalesce((select sum(i.total_paise - i.paid_paise) from public.invoices i where i.resident_id = p_resident_id and i.status = 'issued' and i.due_date < v_today), 0),
      'credit_paise', coalesce((
        select sum(p.amount_paise - coalesce((select sum(a.amount_paise) from public.payment_allocations a where a.payment_id = p.id and a.voided_at is null), 0))
          from public.payments p where p.resident_id = p_resident_id and p.status in ('recorded', 'succeeded')), 0)
    ) end,
    'invoices', case when v_fin then coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'invoice_number', i.invoice_number, 'kind', i.kind, 'period_start', i.period_start,
               'period_end', i.period_end, 'issue_date', i.issue_date, 'due_date', i.due_date, 'status', i.status,
               'total_paise', i.total_paise, 'paid_paise', i.paid_paise, 'balance_paise', i.total_paise - i.paid_paise,
               'payment_status', private.invoice_payment_status(i.status, i.total_paise, i.paid_paise, i.due_date)
             ) order by i.due_date desc, i.created_at desc)
        from public.invoices i where i.resident_id = p_resident_id), '[]'::jsonb) else '[]'::jsonb end,
    'payments', case when v_fin then coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'receipt_number', p.receipt_number, 'amount_paise', p.amount_paise, 'paid_on', p.paid_on,
               'method', p.method, 'source', p.source, 'status', p.status, 'reference', p.reference
             ) order by p.paid_on desc, p.created_at desc)
        from public.payments p where p.resident_id = p_resident_id), '[]'::jsonb) else '[]'::jsonb end,
    'deposit', case when v_fin then jsonb_build_object(
      'agreed_paise', coalesce((
        select a.deposit_paise from public.rent_agreements a join public.stays s on s.id = a.stay_id
         where s.resident_id = p_resident_id
         order by (s.status = 'active') desc, a.effective_from desc limit 1), 0),
      'collected_paise', coalesce((select sum(d.amount_paise) from public.deposit_transactions d where d.resident_id = p_resident_id and d.kind = 'collected'), 0),
      'refunded_paise', coalesce((select sum(d.amount_paise) from public.deposit_transactions d where d.resident_id = p_resident_id and d.kind = 'refunded'), 0),
      'deducted_paise', coalesce((select sum(d.amount_paise) from public.deposit_transactions d where d.resident_id = p_resident_id and d.kind = 'deducted'), 0),
      'transactions', coalesce((
        select jsonb_agg(to_jsonb(d) - 'idempotency_key' order by d.txn_date desc, d.created_at desc)
          from public.deposit_transactions d where d.resident_id = p_resident_id), '[]'::jsonb)
    ) end,
    'has_app_account', exists (select 1 from public.resident_user_links l where l.resident_id = p_resident_id),
    'pending_invitation', (
      select jsonb_build_object('id', i.id, 'email', i.email, 'expires_at', i.expires_at)
        from public.invitations i
       where i.resident_id = p_resident_id and i.accepted_at is null and i.revoked_at is null and i.expires_at > now()
       order by i.created_at desc limit 1)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Invoices and payments
-- -----------------------------------------------------------------------------
-- p_params: { property_id?, status?: open|paid|pending|partially_paid|overdue|void|all,
--             month?, resident_id?, search?, limit?, offset? }
create or replace function public.list_invoices(p_tenant_id uuid, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_property uuid := (private.clean_text(p_params ->> 'property_id'))::uuid;
  v_resident uuid := (private.clean_text(p_params ->> 'resident_id'))::uuid;
  v_status text := coalesce(private.clean_text(p_params ->> 'status'), 'all');
  v_month date := date_trunc('month', (private.clean_text(p_params ->> 'month'))::date)::date;
  v_search text := lower(private.clean_text(p_params ->> 'search'));
  v_limit integer := least(greatest(coalesce((p_params ->> 'limit')::integer, 50), 1), 500);
  v_offset integer := greatest(coalesce((p_params ->> 'offset')::integer, 0), 0);
  v_result jsonb;
begin
  perform private.require_role(p_tenant_id, private.r_finance());
  with base as (
    select i.*, private.invoice_payment_status(i.status, i.total_paise, i.paid_paise, i.due_date) as payment_status,
           r.full_name as resident_name, r.phone as resident_phone, p.name as property_name
      from public.invoices i
      join public.residents r on r.id = i.resident_id
      join public.properties p on p.id = i.property_id
     where i.tenant_id = p_tenant_id
       and (v_property is null or i.property_id = v_property)
       and (v_resident is null or i.resident_id = v_resident)
       and (v_month is null or (i.due_date >= v_month and i.due_date < v_month + interval '1 month'))
       and (v_search is null or lower(i.invoice_number) like '%' || v_search || '%' or lower(r.full_name) like '%' || v_search || '%')
  ),
  filtered as (
    select * from base
     where case v_status
             when 'all' then true
             when 'open' then payment_status in ('pending', 'partially_paid', 'overdue')
             else payment_status = v_status
           end
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'totals', (select jsonb_build_object(
                 'total_paise', coalesce(sum(total_paise) filter (where status = 'issued'), 0),
                 'paid_paise', coalesce(sum(paid_paise) filter (where status = 'issued'), 0),
                 'balance_paise', coalesce(sum(total_paise - paid_paise) filter (where status = 'issued'), 0))
               from filtered),
    'rows', coalesce((
      select jsonb_agg(x order by (x ->> 'due_date') desc, x ->> 'invoice_number' desc)
        from (
          select to_jsonb(f) - 'created_by' - 'voided_by' || jsonb_build_object('balance_paise', f.total_paise - f.paid_paise) as x
            from filtered f
           order by f.due_date desc, f.invoice_number desc
           limit v_limit offset v_offset
        ) q), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function private.business_details(p_tenant_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  -- Business letterhead for receipts. Only called after the caller's access to
  -- a document of this tenant has been verified.
  select jsonb_build_object(
    'name', t.name, 'address_line', t.address_line, 'city', t.city, 'state', t.state,
    'postal_code', t.postal_code, 'contact_phone', t.contact_phone, 'contact_email', t.contact_email,
    'gstin', t.gstin, 'logo_path', t.logo_path,
    'receipt_footer', s.receipt_footer, 'upi_id', s.upi_id)
    from public.tenants t
    join public.tenant_settings s on s.tenant_id = t.id
   where t.id = p_tenant_id;
$$;

create or replace function public.get_invoice(p_invoice_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_invoice public.invoices;
begin
  -- RLS limits this to finance roles of the tenant or the resident themselves.
  select * into v_invoice from public.invoices i where i.id = p_invoice_id;
  if v_invoice.id is null then
    perform private.fail('Invoice not found', 'not_found', 'P0002');
  end if;
  return to_jsonb(v_invoice) - 'created_by' - 'voided_by' || jsonb_build_object(
    'balance_paise', v_invoice.total_paise - v_invoice.paid_paise,
    'payment_status', private.invoice_payment_status(v_invoice.status, v_invoice.total_paise, v_invoice.paid_paise, v_invoice.due_date),
    'items', coalesce((select jsonb_agg(to_jsonb(it) order by it.sort_order) from public.invoice_items it where it.invoice_id = p_invoice_id), '[]'::jsonb),
    'allocations', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'payment_id', a.payment_id, 'receipt_number', p.receipt_number, 'paid_on', p.paid_on,
               'method', p.method, 'amount_paise', a.amount_paise, 'voided_at', a.voided_at
             ) order by p.paid_on, a.created_at)
        from public.payment_allocations a
        join public.payments p on p.id = a.payment_id
       where a.invoice_id = p_invoice_id), '[]'::jsonb),
    'resident', (select jsonb_build_object('id', r.id, 'full_name', r.full_name, 'phone', r.phone, 'email', r.email)
                   from public.residents r where r.id = v_invoice.resident_id),
    'property', (select jsonb_build_object('id', p.id, 'name', p.name, 'address_line1', p.address_line1, 'city', p.city)
                   from public.properties p where p.id = v_invoice.property_id),
    'business', private.business_details(v_invoice.tenant_id)
  );
end;
$$;

-- p_params: { property_id?, from?, to?, method?, status?: live|voided|all, resident_id?, search?, limit?, offset? }
create or replace function public.list_payments(p_tenant_id uuid, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_property uuid := (private.clean_text(p_params ->> 'property_id'))::uuid;
  v_resident uuid := (private.clean_text(p_params ->> 'resident_id'))::uuid;
  v_from date := (private.clean_text(p_params ->> 'from'))::date;
  v_to date := (private.clean_text(p_params ->> 'to'))::date;
  v_method text := private.clean_text(p_params ->> 'method');
  v_status text := coalesce(private.clean_text(p_params ->> 'status'), 'live');
  v_search text := lower(private.clean_text(p_params ->> 'search'));
  v_limit integer := least(greatest(coalesce((p_params ->> 'limit')::integer, 50), 1), 500);
  v_offset integer := greatest(coalesce((p_params ->> 'offset')::integer, 0), 0);
  v_result jsonb;
begin
  perform private.require_role(p_tenant_id, private.r_finance());
  with filtered as (
    select p.id, p.receipt_number, p.resident_id, p.property_id, p.amount_paise, p.paid_on, p.method, p.source,
           p.status, p.reference, p.notes, p.created_at, p.voided_at, p.void_reason,
           r.full_name as resident_name, pr.name as property_name,
           coalesce((select sum(a.amount_paise) from public.payment_allocations a where a.payment_id = p.id and a.voided_at is null), 0) as allocated_paise
      from public.payments p
      join public.residents r on r.id = p.resident_id
      left join public.properties pr on pr.id = p.property_id
     where p.tenant_id = p_tenant_id
       and (v_property is null or p.property_id = v_property)
       and (v_resident is null or p.resident_id = v_resident)
       and (v_from is null or p.paid_on >= v_from)
       and (v_to is null or p.paid_on <= v_to)
       and (v_method is null or p.method::text = v_method)
       and case v_status
             when 'live' then p.status in ('recorded', 'succeeded')
             when 'voided' then p.status = 'voided'
             else true
           end
       and (v_search is null
            or lower(p.receipt_number) like '%' || v_search || '%'
            or lower(coalesce(p.reference, '')) like '%' || v_search || '%'
            or lower(r.full_name) like '%' || v_search || '%')
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'totals', jsonb_build_object(
      'amount_paise', (select coalesce(sum(amount_paise) filter (where status in ('recorded', 'succeeded')), 0) from filtered)),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.paid_on desc, q.created_at desc)
        from (select * from filtered order by paid_on desc, created_at desc limit v_limit offset v_offset) q), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.get_payment(p_payment_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_payment public.payments;
begin
  select * into v_payment from public.payments p where p.id = p_payment_id;
  if v_payment.id is null then
    perform private.fail('Payment not found', 'not_found', 'P0002');
  end if;
  return to_jsonb(v_payment) - 'idempotency_key' || jsonb_build_object(
    'allocations', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'invoice_id', a.invoice_id, 'invoice_number', i.invoice_number, 'period_start', i.period_start,
               'due_date', i.due_date, 'amount_paise', a.amount_paise, 'voided_at', a.voided_at
             ) order by i.due_date)
        from public.payment_allocations a
        join public.invoices i on i.id = a.invoice_id
       where a.payment_id = p_payment_id), '[]'::jsonb),
    'allocated_paise', coalesce((select sum(a.amount_paise) from public.payment_allocations a where a.payment_id = p_payment_id and a.voided_at is null), 0),
    'resident', (select jsonb_build_object('id', r.id, 'full_name', r.full_name, 'phone', r.phone, 'email', r.email)
                   from public.residents r where r.id = v_payment.resident_id),
    'property', (select jsonb_build_object('id', p.id, 'name', p.name, 'address_line1', p.address_line1, 'city', p.city)
                   from public.properties p where p.id = v_payment.property_id),
    'recorded_by_name', (select pr.full_name from public.profiles pr where pr.id = v_payment.recorded_by),
    'business', private.business_details(v_payment.tenant_id)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Deposits, expenses, charges
-- -----------------------------------------------------------------------------
-- p_params: { search?, property_id?, filter?: all|held|due }
create or replace function public.list_deposits(p_tenant_id uuid, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_search text := lower(private.clean_text(p_params ->> 'search'));
  v_property uuid := (private.clean_text(p_params ->> 'property_id'))::uuid;
  v_filter text := coalesce(private.clean_text(p_params ->> 'filter'), 'all');
  v_result jsonb;
begin
  perform private.require_role(p_tenant_id, private.r_finance());
  with latest_stay as (
    select distinct on (s.resident_id) s.resident_id, s.id as stay_id, s.status, s.property_id
      from public.stays s
     where s.tenant_id = p_tenant_id
     order by s.resident_id, (s.status = 'active') desc, s.move_in_date desc
  ),
  agreed as (
    select distinct on (a.stay_id) a.stay_id, a.deposit_paise
      from public.rent_agreements a
     where a.tenant_id = p_tenant_id
     order by a.stay_id, a.effective_from desc
  ),
  txn as (
    select d.resident_id,
           sum(d.amount_paise) filter (where d.kind = 'collected') as collected,
           sum(d.amount_paise) filter (where d.kind = 'refunded') as refunded,
           sum(d.amount_paise) filter (where d.kind = 'deducted') as deducted
      from public.deposit_transactions d
     where d.tenant_id = p_tenant_id
     group by d.resident_id
  ),
  rows as (
    select r.id as resident_id, r.full_name, ls.status as stay_status, ls.property_id, p.name as property_name,
           coalesce(ag.deposit_paise, 0) as agreed_paise,
           coalesce(t.collected, 0) as collected_paise,
           coalesce(t.refunded, 0) as refunded_paise,
           coalesce(t.deducted, 0) as deducted_paise,
           coalesce(t.collected, 0) - coalesce(t.refunded, 0) - coalesce(t.deducted, 0) as held_paise,
           greatest(coalesce(ag.deposit_paise, 0) - coalesce(t.collected, 0), 0) as due_paise
      from public.residents r
      left join latest_stay ls on ls.resident_id = r.id
      left join agreed ag on ag.stay_id = ls.stay_id
      left join txn t on t.resident_id = r.id
      left join public.properties p on p.id = ls.property_id
     where r.tenant_id = p_tenant_id
       and (coalesce(ag.deposit_paise, 0) > 0 or t.resident_id is not null)
       and (v_property is null or ls.property_id = v_property)
       and (v_search is null or lower(r.full_name) like '%' || v_search || '%')
  )
  select jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.held_paise desc, x.full_name)
        from rows x
       where case v_filter
               when 'held' then x.held_paise > 0
               when 'due' then x.due_paise > 0 and x.stay_status = 'active'
               else true
             end), '[]'::jsonb),
    'totals', (select jsonb_build_object(
                 'held_paise', coalesce(sum(held_paise), 0),
                 'due_paise', coalesce(sum(due_paise) filter (where stay_status = 'active'), 0),
                 'refunded_paise', coalesce(sum(refunded_paise), 0),
                 'deducted_paise', coalesce(sum(deducted_paise), 0))
               from rows),
    'recent_transactions', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.txn_date desc, q.created_at desc)
        from (
          select d.id, d.resident_id, r.full_name, d.kind, d.amount_paise, d.txn_date, d.method, d.reference, d.notes, d.created_at
            from public.deposit_transactions d
            join public.residents r on r.id = d.resident_id
           where d.tenant_id = p_tenant_id
           order by d.txn_date desc, d.created_at desc
           limit 25
        ) q), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

-- p_params: { property_id?, from?, to?, category?, search?, limit?, offset? }
create or replace function public.list_expenses(p_tenant_id uuid, p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_property uuid := (private.clean_text(p_params ->> 'property_id'))::uuid;
  v_from date := (private.clean_text(p_params ->> 'from'))::date;
  v_to date := (private.clean_text(p_params ->> 'to'))::date;
  v_category text := private.clean_text(p_params ->> 'category');
  v_search text := lower(private.clean_text(p_params ->> 'search'));
  v_limit integer := least(greatest(coalesce((p_params ->> 'limit')::integer, 50), 1), 500);
  v_offset integer := greatest(coalesce((p_params ->> 'offset')::integer, 0), 0);
  v_result jsonb;
begin
  perform private.require_role(p_tenant_id, private.r_finance());
  with filtered as (
    select e.*, p.name as property_name
      from public.expenses e
      left join public.properties p on p.id = e.property_id
     where e.tenant_id = p_tenant_id
       and (v_property is null or e.property_id = v_property)
       and (v_from is null or e.expense_date >= v_from)
       and (v_to is null or e.expense_date <= v_to)
       and (v_category is null or e.category = v_category)
       and (v_search is null or lower(coalesce(e.payee, '')) like '%' || v_search || '%'
            or lower(coalesce(e.notes, '')) like '%' || v_search || '%'
            or lower(e.category) like '%' || v_search || '%')
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'totals', jsonb_build_object('amount_paise', (select coalesce(sum(amount_paise), 0) from filtered)),
    'by_category', coalesce((
      select jsonb_agg(jsonb_build_object('category', category, 'amount_paise', amount) order by amount desc)
        from (select category, sum(amount_paise) as amount from filtered group by category) c), '[]'::jsonb),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(q) - 'created_by' order by q.expense_date desc, q.created_at desc)
        from (select * from filtered order by expense_date desc, created_at desc limit v_limit offset v_offset) q), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.list_charge_templates(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform private.require_role(p_tenant_id, private.r_all());
  return coalesce((
    select jsonb_agg(to_jsonb(c) || jsonb_build_object('property_name', p.name) order by c.is_active desc, c.name)
      from public.charge_templates c
      left join public.properties p on p.id = c.property_id
     where c.tenant_id = p_tenant_id), '[]'::jsonb);
end;
$$;

-- -----------------------------------------------------------------------------
-- Dashboard and reports — every figure is computed from stored records.
-- -----------------------------------------------------------------------------
create or replace function public.dashboard_summary(p_tenant_id uuid, p_property_id uuid default null, p_month date default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_role public.tenant_role := private.require_role(p_tenant_id, private.r_all());
  v_fin boolean := v_role = any (private.r_finance());
  v_today date := private.today();
  v_start date := date_trunc('month', coalesce(p_month, private.today()))::date;
  v_end date := (date_trunc('month', coalesce(p_month, private.today())) + interval '1 month - 1 day')::date;
  v_occupancy jsonb;
  v_finance jsonb;
begin
  select jsonb_build_object(
           'total_beds', count(*),
           'occupied', count(*) filter (where s.id is not null),
           'unavailable', count(*) filter (where b.is_unavailable and s.id is null),
           'vacant', count(*) filter (where not b.is_unavailable and s.id is null))
    into v_occupancy
    from public.beds b
    join public.rooms r on r.id = b.room_id and r.is_active
    join public.properties p on p.id = b.property_id and p.status = 'active'
    left join public.stays s on s.bed_id = b.id and s.status = 'active'
   where b.tenant_id = p_tenant_id
     and (p_property_id is null or b.property_id = p_property_id);

  if v_fin then
    select jsonb_build_object(
      'billed_paise', coalesce((
        select sum(i.total_paise) from public.invoices i
         where i.tenant_id = p_tenant_id and i.status = 'issued' and i.due_date between v_start and v_end
           and (p_property_id is null or i.property_id = p_property_id)), 0),
      'billed_collected_paise', coalesce((
        select sum(i.paid_paise) from public.invoices i
         where i.tenant_id = p_tenant_id and i.status = 'issued' and i.due_date between v_start and v_end
           and (p_property_id is null or i.property_id = p_property_id)), 0),
      'collected_paise', coalesce((
        select sum(p.amount_paise) from public.payments p
         where p.tenant_id = p_tenant_id and p.status in ('recorded', 'succeeded') and p.paid_on between v_start and v_end
           and (p_property_id is null or p.property_id = p_property_id)), 0),
      'outstanding_paise', coalesce((
        select sum(i.total_paise - i.paid_paise) from public.invoices i
         where i.tenant_id = p_tenant_id and i.status = 'issued'
           and (p_property_id is null or i.property_id = p_property_id)), 0),
      'overdue_paise', coalesce((
        select sum(i.total_paise - i.paid_paise) from public.invoices i
         where i.tenant_id = p_tenant_id and i.status = 'issued' and i.due_date < v_today
           and (p_property_id is null or i.property_id = p_property_id)), 0),
      'projected_rent_paise', coalesce((
        select sum(a.monthly_rent_paise) from public.rent_agreements a
          join public.stays s on s.id = a.stay_id and s.status = 'active'
         where a.tenant_id = p_tenant_id and a.effective_to is null
           and (p_property_id is null or s.property_id = p_property_id)), 0),
      'expenses_paise', coalesce((
        select sum(e.amount_paise) from public.expenses e
         where e.tenant_id = p_tenant_id and e.expense_date between v_start and v_end
           and (p_property_id is null or e.property_id = p_property_id)), 0),
      'stays_without_invoice', (
        select count(*) from public.stays s
         where s.tenant_id = p_tenant_id and s.status = 'active' and s.move_in_date <= v_end
           and (p_property_id is null or s.property_id = p_property_id)
           and not exists (select 1 from public.invoices i where i.stay_id = s.id and i.kind = 'rent'
                            and i.status = 'issued' and i.period_start = v_start)),
      'series', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'month', m.month::date,
                 'billed_paise', coalesce((select sum(i.total_paise) from public.invoices i
                    where i.tenant_id = p_tenant_id and i.status = 'issued'
                      and i.due_date >= m.month and i.due_date < m.month + interval '1 month'
                      and (p_property_id is null or i.property_id = p_property_id)), 0),
                 'collected_paise', coalesce((select sum(p.amount_paise) from public.payments p
                    where p.tenant_id = p_tenant_id and p.status in ('recorded', 'succeeded')
                      and p.paid_on >= m.month and p.paid_on < m.month + interval '1 month'
                      and (p_property_id is null or p.property_id = p_property_id)), 0),
                 'expenses_paise', coalesce((select sum(e.amount_paise) from public.expenses e
                    where e.tenant_id = p_tenant_id
                      and e.expense_date >= m.month and e.expense_date < m.month + interval '1 month'
                      and (p_property_id is null or e.property_id = p_property_id)), 0)
               ) order by m.month), '[]'::jsonb)
          from generate_series(v_start - interval '5 months', v_start::timestamp, interval '1 month') as m(month)),
      'recent_payments', (
        select coalesce(jsonb_agg(to_jsonb(q) order by q.paid_on desc, q.created_at desc), '[]'::jsonb)
          from (
            select p.id, p.receipt_number, p.resident_id, r.full_name as resident_name, p.amount_paise, p.paid_on, p.method, p.created_at
              from public.payments p join public.residents r on r.id = p.resident_id
             where p.tenant_id = p_tenant_id and p.status in ('recorded', 'succeeded')
               and (p_property_id is null or p.property_id = p_property_id)
             order by p.paid_on desc, p.created_at desc limit 6) q),
      'top_outstanding', (
        select coalesce(jsonb_agg(to_jsonb(q) order by q.balance_paise desc), '[]'::jsonb)
          from (
            select i.resident_id, r.full_name, min(pr.name) as property_name,
                   sum(i.total_paise - i.paid_paise) as balance_paise,
                   coalesce(sum(i.total_paise - i.paid_paise) filter (where i.due_date < v_today), 0) as overdue_paise,
                   min(i.due_date) as oldest_due_date
              from public.invoices i
              join public.residents r on r.id = i.resident_id
              join public.properties pr on pr.id = i.property_id
             where i.tenant_id = p_tenant_id and i.status = 'issued' and i.paid_paise < i.total_paise
               and (p_property_id is null or i.property_id = p_property_id)
             group by i.resident_id, r.full_name
             order by sum(i.total_paise - i.paid_paise) desc
             limit 6) q)
    ) into v_finance;
  end if;

  return jsonb_build_object(
    'month', v_start,
    'today', v_today,
    'finance_visible', v_fin,
    'occupancy', v_occupancy,
    'finance', v_finance,
    'recent_checkins', (
      select coalesce(jsonb_agg(to_jsonb(q) order by q.move_in_date desc, q.created_at desc), '[]'::jsonb)
        from (
          select s.id as stay_id, s.resident_id, r.full_name, p.name as property_name, rm.name as room_name,
                 b.label as bed_label, s.move_in_date, s.created_at
            from public.stays s
            join public.residents r on r.id = s.resident_id
            join public.properties p on p.id = s.property_id
            join public.beds b on b.id = s.bed_id
            join public.rooms rm on rm.id = b.room_id
           where s.tenant_id = p_tenant_id
             and (p_property_id is null or s.property_id = p_property_id)
           order by s.move_in_date desc, s.created_at desc limit 6) q),
    'upcoming_move_outs', (
      select coalesce(jsonb_agg(to_jsonb(q) order by q.expected_move_out_date), '[]'::jsonb)
        from (
          select s.id as stay_id, s.resident_id, r.full_name, p.name as property_name, s.expected_move_out_date
            from public.stays s
            join public.residents r on r.id = s.resident_id
            join public.properties p on p.id = s.property_id
           where s.tenant_id = p_tenant_id and s.status = 'active'
             and s.expected_move_out_date between v_today and v_today + 30
             and (p_property_id is null or s.property_id = p_property_id)
           order by s.expected_move_out_date limit 6) q),
    'properties', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.name,
               'beds', (select count(*) from public.beds b join public.rooms r on r.id = b.room_id and r.is_active where b.property_id = p.id),
               'occupied', (select count(*) from public.stays s where s.property_id = p.id and s.status = 'active'),
               'unavailable', (select count(*) from public.beds b where b.property_id = p.id and b.is_unavailable)
             ) order by p.name), '[]'::jsonb)
        from public.properties p
       where p.tenant_id = p_tenant_id and p.status = 'active'
         and (p_property_id is null or p.id = p_property_id)),
    'checklist', jsonb_build_object(
      'has_property', exists (select 1 from public.properties p where p.tenant_id = p_tenant_id),
      'has_rooms', exists (select 1 from public.rooms r where r.tenant_id = p_tenant_id),
      'has_residents', exists (select 1 from public.residents r where r.tenant_id = p_tenant_id),
      'has_assignments', exists (select 1 from public.stays s where s.tenant_id = p_tenant_id),
      'has_invoices', v_fin and exists (select 1 from public.invoices i where i.tenant_id = p_tenant_id),
      'has_payments', v_fin and exists (select 1 from public.payments p where p.tenant_id = p_tenant_id),
      'has_team', exists (select 1 from public.tenant_memberships m where m.tenant_id = p_tenant_id and m.role <> 'owner')
    )
  );
end;
$$;

create or replace function public.financial_report(p_tenant_id uuid, p_from date, p_to date, p_property_id uuid default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_today date := private.today();
  v_from date := date_trunc('month', p_from)::date;
  v_to date := (date_trunc('month', p_to) + interval '1 month - 1 day')::date;
begin
  perform private.require_role(p_tenant_id, private.r_finance());
  if p_from is null or p_to is null or p_from > p_to then
    perform private.fail('Choose a valid date range');
  end if;
  if v_to - v_from > 731 then
    perform private.fail('Reports can cover at most 24 months');
  end if;

  return jsonb_build_object(
    'from', v_from,
    'to', v_to,
    'totals', jsonb_build_object(
      'billed_paise', coalesce((select sum(i.total_paise) from public.invoices i
        where i.tenant_id = p_tenant_id and i.status = 'issued' and i.due_date between v_from and v_to
          and (p_property_id is null or i.property_id = p_property_id)), 0),
      'collected_paise', coalesce((select sum(p.amount_paise) from public.payments p
        where p.tenant_id = p_tenant_id and p.status in ('recorded', 'succeeded') and p.paid_on between v_from and v_to
          and (p_property_id is null or p.property_id = p_property_id)), 0),
      'expenses_paise', coalesce((select sum(e.amount_paise) from public.expenses e
        where e.tenant_id = p_tenant_id and e.expense_date between v_from and v_to
          and (p_property_id is null or e.property_id = p_property_id)), 0),
      'outstanding_paise', coalesce((select sum(i.total_paise - i.paid_paise) from public.invoices i
        where i.tenant_id = p_tenant_id and i.status = 'issued'
          and (p_property_id is null or i.property_id = p_property_id)), 0),
      'overdue_paise', coalesce((select sum(i.total_paise - i.paid_paise) from public.invoices i
        where i.tenant_id = p_tenant_id and i.status = 'issued' and i.due_date < v_today
          and (p_property_id is null or i.property_id = p_property_id)), 0)
    ),
    'monthly', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'month', m.month::date,
               'billed_paise', coalesce((select sum(i.total_paise) from public.invoices i
                  where i.tenant_id = p_tenant_id and i.status = 'issued'
                    and i.due_date >= m.month and i.due_date < m.month + interval '1 month'
                    and (p_property_id is null or i.property_id = p_property_id)), 0),
               'collected_paise', coalesce((select sum(p.amount_paise) from public.payments p
                  where p.tenant_id = p_tenant_id and p.status in ('recorded', 'succeeded')
                    and p.paid_on >= m.month and p.paid_on < m.month + interval '1 month'
                    and (p_property_id is null or p.property_id = p_property_id)), 0),
               'expenses_paise', coalesce((select sum(e.amount_paise) from public.expenses e
                  where e.tenant_id = p_tenant_id
                    and e.expense_date >= m.month and e.expense_date < m.month + interval '1 month'
                    and (p_property_id is null or e.property_id = p_property_id)), 0)
             ) order by m.month), '[]'::jsonb)
        from generate_series(v_from::timestamp, v_to::timestamp, interval '1 month') as m(month)),
    'by_property', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'property_id', p.id,
               'name', p.name,
               'beds', (select count(*) from public.beds b where b.property_id = p.id),
               'occupied', (select count(*) from public.stays s where s.property_id = p.id and s.status = 'active'),
               'billed_paise', coalesce((select sum(i.total_paise) from public.invoices i
                  where i.property_id = p.id and i.status = 'issued' and i.due_date between v_from and v_to), 0),
               'collected_paise', coalesce((select sum(pm.amount_paise) from public.payments pm
                  where pm.property_id = p.id and pm.status in ('recorded', 'succeeded') and pm.paid_on between v_from and v_to), 0),
               'expenses_paise', coalesce((select sum(e.amount_paise) from public.expenses e
                  where e.property_id = p.id and e.expense_date between v_from and v_to), 0),
               'outstanding_paise', coalesce((select sum(i.total_paise - i.paid_paise) from public.invoices i
                  where i.property_id = p.id and i.status = 'issued'), 0)
             ) order by p.name), '[]'::jsonb)
        from public.properties p
       where p.tenant_id = p_tenant_id and (p_property_id is null or p.id = p_property_id)),
    'expenses_by_category', (
      select coalesce(jsonb_agg(jsonb_build_object('category', c.category, 'amount_paise', c.amount) order by c.amount desc), '[]'::jsonb)
        from (
          select e.category, sum(e.amount_paise) as amount from public.expenses e
           where e.tenant_id = p_tenant_id and e.expense_date between v_from and v_to
             and (p_property_id is null or e.property_id = p_property_id)
           group by e.category) c),
    'collection_by_method', (
      select coalesce(jsonb_agg(jsonb_build_object('method', c.method, 'amount_paise', c.amount, 'count', c.n) order by c.amount desc), '[]'::jsonb)
        from (
          select p.method, sum(p.amount_paise) as amount, count(*) as n from public.payments p
           where p.tenant_id = p_tenant_id and p.status in ('recorded', 'succeeded') and p.paid_on between v_from and v_to
             and (p_property_id is null or p.property_id = p_property_id)
           group by p.method) c),
    'outstanding', (
      select coalesce(jsonb_agg(to_jsonb(q) order by q.balance_paise desc), '[]'::jsonb)
        from (
          select i.resident_id, r.full_name, r.phone, min(pr.name) as property_name,
                 count(*) as open_invoices,
                 sum(i.total_paise - i.paid_paise) as balance_paise,
                 coalesce(sum(i.total_paise - i.paid_paise) filter (where i.due_date < v_today), 0) as overdue_paise,
                 min(i.due_date) as oldest_due_date
            from public.invoices i
            join public.residents r on r.id = i.resident_id
            join public.properties pr on pr.id = i.property_id
           where i.tenant_id = p_tenant_id and i.status = 'issued' and i.paid_paise < i.total_paise
             and (p_property_id is null or i.property_id = p_property_id)
           group by i.resident_id, r.full_name, r.phone
           limit 500) q)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Team and audit
-- -----------------------------------------------------------------------------
create or replace function public.list_members(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_role public.tenant_role := private.require_role(p_tenant_id, private.r_all());
begin
  return jsonb_build_object(
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', m.id, 'user_id', m.user_id, 'role', m.role, 'status', m.status, 'created_at', m.created_at,
               'full_name', p.full_name, 'email', p.email, 'is_me', m.user_id = auth.uid()
             ) order by (m.role = 'owner') desc, p.full_name)
        from public.tenant_memberships m
        left join public.profiles p on p.id = m.user_id
       where m.tenant_id = p_tenant_id), '[]'::jsonb),
    'invitations', case when v_role = 'owner' then coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', i.id, 'kind', i.kind, 'email', i.email, 'role', i.role, 'resident_id', i.resident_id,
               'expires_at', i.expires_at, 'created_at', i.created_at
             ) order by i.created_at desc)
        from public.invitations i
       where i.tenant_id = p_tenant_id and i.accepted_at is null and i.revoked_at is null and i.expires_at > now()), '[]'::jsonb)
      else '[]'::jsonb end
  );
end;
$$;

create or replace function public.list_audit_logs(p_tenant_id uuid, p_limit integer default 50, p_before_id bigint default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform private.require_role(p_tenant_id, private.r_ops());
  return coalesce((
    select jsonb_agg(to_jsonb(q) order by q.id desc)
      from (
        select a.id, a.action, a.entity_type, a.entity_id, a.details, a.created_at, a.actor_id, p.full_name as actor_name
          from public.audit_logs a
          left join public.profiles p on p.id = a.actor_id
         where a.tenant_id = p_tenant_id and (p_before_id is null or a.id < p_before_id)
         order by a.id desc
         limit least(greatest(coalesce(p_limit, 50), 1), 200)) q), '[]'::jsonb);
end;
$$;
