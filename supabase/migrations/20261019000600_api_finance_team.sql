-- =============================================================================
-- Write API, part 2: invoices, manual payments, deposits, expenses, team and
-- invitations. Rent invoices are created only by explicit user action —
-- there is no scheduler, cron job or background billing.
-- =============================================================================

-- Allocates a payment's unallocated amount to the resident's open invoices,
-- oldest due date first. Returns the amount allocated.
create or replace function private.allocate_payment(p_payment_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments;
  v_available bigint;
  v_amount bigint;
  v_applied bigint := 0;
  v_invoice record;
begin
  select * into v_payment from public.payments p where p.id = p_payment_id for update;
  if v_payment.status not in ('recorded', 'succeeded') then
    return 0;
  end if;
  v_available := v_payment.amount_paise - coalesce((
    select sum(a.amount_paise) from public.payment_allocations a
     where a.payment_id = p_payment_id and a.voided_at is null), 0);

  for v_invoice in
    select i.id, i.total_paise - i.paid_paise as balance
      from public.invoices i
     where i.tenant_id = v_payment.tenant_id
       and i.resident_id = v_payment.resident_id
       and i.status = 'issued'
       and i.paid_paise < i.total_paise
     order by i.due_date, i.created_at
       for update
  loop
    exit when v_available <= 0;
    v_amount := least(v_available, v_invoice.balance);
    insert into public.payment_allocations (tenant_id, resident_id, payment_id, invoice_id, amount_paise)
    values (v_payment.tenant_id, v_payment.resident_id, p_payment_id, v_invoice.id, v_amount);
    v_available := v_available - v_amount;
    v_applied := v_applied + v_amount;
  end loop;
  return v_applied;
end;
$$;

-- Applies any advance/credit (unallocated payment amounts) to open invoices.
create or replace function private.apply_resident_credit(p_tenant_id uuid, p_resident_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment_id uuid;
  v_total bigint := 0;
begin
  for v_payment_id in
    select p.id
      from public.payments p
     where p.tenant_id = p_tenant_id
       and p.resident_id = p_resident_id
       and p.status in ('recorded', 'succeeded')
       and p.amount_paise > coalesce((
         select sum(a.amount_paise) from public.payment_allocations a
          where a.payment_id = p.id and a.voided_at is null), 0)
     order by p.paid_on, p.created_at
  loop
    v_total := v_total + private.allocate_payment(v_payment_id);
  end loop;
  return v_total;
end;
$$;

-- Inserts an invoice and its items. Items: [{ kind?, description, amount_paise }]
create or replace function private.insert_invoice(
  p_tenant_id uuid,
  p_resident_id uuid,
  p_property_id uuid,
  p_stay_id uuid,
  p_kind public.invoice_kind,
  p_period_start date,
  p_period_end date,
  p_issue_date date,
  p_due_date date,
  p_items jsonb,
  p_notes text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_total bigint := 0;
  v_item jsonb;
  v_amount bigint;
  v_desc text;
  v_ord integer := 0;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    perform private.fail('Add at least one line item');
  end if;
  if jsonb_array_length(p_items) > 50 then
    perform private.fail('An invoice can have at most 50 line items');
  end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_amount := private.to_paise(v_item -> 'amount_paise', 'Line item amount');
    if v_amount is null then
      perform private.fail('Every line item needs an amount');
    end if;
    if private.clean_text(v_item ->> 'description') is null then
      perform private.fail('Every line item needs a description');
    end if;
    v_total := v_total + v_amount;
  end loop;
  if v_total <= 0 then
    perform private.fail('Invoice total must be greater than zero');
  end if;
  if p_due_date < p_issue_date then
    perform private.fail('Due date cannot be before the issue date');
  end if;

  insert into public.invoices (
    tenant_id, resident_id, property_id, stay_id, invoice_number, kind,
    period_start, period_end, issue_date, due_date, total_paise, notes, created_by
  ) values (
    p_tenant_id, p_resident_id, p_property_id, p_stay_id,
    private.next_document_number(p_tenant_id, 'invoice'),
    p_kind, p_period_start, p_period_end, p_issue_date, p_due_date, v_total,
    private.clean_text(p_notes), auth.uid()
  )
  returning id into v_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_ord := v_ord + 1;
    v_desc := left(private.clean_text(v_item ->> 'description'), 200);
    insert into public.invoice_items (tenant_id, invoice_id, kind, description, amount_paise, sort_order)
    values (
      p_tenant_id, v_id,
      coalesce((v_item ->> 'kind')::public.invoice_item_kind, 'other'),
      v_desc,
      private.to_paise(v_item -> 'amount_paise', 'Line item amount'),
      v_ord
    );
  end loop;

  perform private.apply_resident_credit(p_tenant_id, p_resident_id);
  perform private.audit(p_tenant_id, 'invoice.issued', 'invoice', v_id,
    jsonb_build_object('resident_id', p_resident_id, 'total_paise', v_total, 'kind', p_kind));
  return v_id;
end;
$$;

-- p_data: { kind?, property_id?, period_start?, period_end?, issue_date?, due_date?, items[], notes? }
create or replace function public.create_invoice(p_resident_id uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_resident public.residents;
  v_stay public.stays;
  v_property_id uuid;
  v_issue date := coalesce((private.clean_text(p_data ->> 'issue_date'))::date, private.today());
  v_due date;
  v_due_days smallint;
  v_kind public.invoice_kind := coalesce((p_data ->> 'kind')::public.invoice_kind, 'other');
  v_period_start date := (private.clean_text(p_data ->> 'period_start'))::date;
begin
  select * into v_resident from public.residents r where r.id = p_resident_id;
  perform private.require_write(v_resident.tenant_id, private.r_finance());

  select * into v_stay from public.stays s where s.resident_id = p_resident_id and s.status = 'active';
  v_property_id := coalesce((private.clean_text(p_data ->> 'property_id'))::uuid, v_stay.property_id,
    (select s.property_id from public.stays s where s.resident_id = p_resident_id order by s.move_in_date desc limit 1));
  if v_property_id is null then
    perform private.fail('Assign the resident to a bed or choose a property for this invoice');
  end if;
  if not exists (select 1 from public.properties p where p.id = v_property_id and p.tenant_id = v_resident.tenant_id) then
    perform private.fail('Property not found', 'not_found', 'P0002');
  end if;
  select coalesce(ps.payment_due_days, ts.payment_due_days)
    into v_due_days
    from public.tenant_settings ts
    left join public.property_settings ps on ps.property_id = v_property_id
   where ts.tenant_id = v_resident.tenant_id;
  v_due := coalesce((private.clean_text(p_data ->> 'due_date'))::date, v_issue + coalesce(v_due_days, 0));
  if v_kind = 'rent' and v_period_start is null then
    v_period_start := date_trunc('month', v_issue)::date;
  end if;

  begin
    return private.insert_invoice(
      v_resident.tenant_id, p_resident_id, v_property_id,
      case when v_stay.property_id = v_property_id then v_stay.id end,
      v_kind,
      v_period_start,
      coalesce((private.clean_text(p_data ->> 'period_end'))::date,
               case when v_period_start is not null then (v_period_start + interval '1 month - 1 day')::date end),
      v_issue, v_due, p_data -> 'items', p_data ->> 'notes');
  exception when unique_violation then
    perform private.fail('A rent invoice already exists for this resident and period', 'duplicate');
  end;
exception
  when invalid_datetime_format or datetime_field_overflow then
    perform private.fail('One of the dates is not valid');
end;
$$;

-- Explicit, owner-triggered rent run for one month. Safe to run repeatedly:
-- stays that already have a live rent invoice for the period are skipped.
create or replace function public.generate_rent_invoices(p_tenant_id uuid, p_month date, p_property_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_days integer;
  v_settings public.tenant_settings;
  v_stay record;
  v_agreement public.rent_agreements;
  v_rent bigint;
  v_items jsonb;
  v_desc text;
  v_issue date;
  v_due_days smallint;
  v_created integer := 0;
  v_skipped integer := 0;
  v_total bigint := 0;
  v_charge record;
begin
  perform private.require_write(p_tenant_id, private.r_finance());
  if p_month is null then
    perform private.fail('Choose a month');
  end if;
  if v_start > date_trunc('month', private.today())::date + interval '1 month' then
    perform private.fail('You can generate rent at most one month ahead');
  end if;
  v_days := v_end - v_start + 1;
  select * into v_settings from public.tenant_settings s where s.tenant_id = p_tenant_id;

  for v_stay in
    select s.id, s.resident_id, s.property_id, s.move_in_date, r.full_name
      from public.stays s
      join public.residents r on r.id = s.resident_id
      join public.properties p on p.id = s.property_id
     where s.tenant_id = p_tenant_id
       and s.status = 'active'
       and s.move_in_date <= v_end
       and (p_property_id is null or s.property_id = p_property_id)
     order by p.name, r.full_name
  loop
    if exists (
      select 1 from public.invoices i
       where i.stay_id = v_stay.id and i.period_start = v_start and i.kind = 'rent' and i.status = 'issued'
    ) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    select * into v_agreement
      from public.rent_agreements a
     where a.stay_id = v_stay.id
       and a.effective_from <= greatest(v_start, v_stay.move_in_date)
       and (a.effective_to is null or a.effective_to > greatest(v_start, v_stay.move_in_date))
     order by a.effective_from desc
     limit 1;
    if v_agreement.id is null then
      select * into v_agreement from public.rent_agreements a
       where a.stay_id = v_stay.id order by a.effective_from desc limit 1;
    end if;

    v_rent := v_agreement.monthly_rent_paise;
    v_desc := 'Rent for ' || to_char(v_start, 'FMMonth YYYY');
    if v_settings.prorate_first_month and v_stay.move_in_date > v_start then
      -- Rounded to whole rupees, as PG bills normally are.
      v_rent := (round(v_rent::numeric * (v_end - v_stay.move_in_date + 1) / v_days / 100) * 100)::bigint;
      v_desc := v_desc || ' (prorated from ' || to_char(v_stay.move_in_date, 'FMDD Mon') || ')';
    end if;

    v_items := '[]'::jsonb;
    if v_rent > 0 then
      v_items := v_items || jsonb_build_object('kind', 'rent', 'description', v_desc, 'amount_paise', v_rent);
    end if;
    for v_charge in
      select c.name, c.amount_paise from public.charge_templates c
       where c.tenant_id = p_tenant_id and c.is_active and c.apply_by_default and c.frequency = 'monthly'
         and (c.property_id is null or c.property_id = v_stay.property_id)
       order by c.name
    loop
      v_items := v_items || jsonb_build_object('kind', 'charge', 'description', v_charge.name, 'amount_paise', v_charge.amount_paise);
    end loop;

    if jsonb_array_length(v_items) = 0 then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    select coalesce(ps.payment_due_days, v_settings.payment_due_days) into v_due_days
      from public.property_settings ps where ps.property_id = v_stay.property_id;
    v_due_days := coalesce(v_due_days, v_settings.payment_due_days);
    v_issue := greatest(v_start + (v_agreement.billing_day - 1), v_stay.move_in_date);
    if v_issue > v_end then
      v_issue := v_end;
    end if;

    perform private.insert_invoice(
      p_tenant_id, v_stay.resident_id, v_stay.property_id, v_stay.id, 'rent',
      v_start, v_end, v_issue, v_issue + v_due_days, v_items, null);
    v_created := v_created + 1;
    v_total := v_total + (select sum((e ->> 'amount_paise')::bigint) from jsonb_array_elements(v_items) e);
  end loop;

  perform private.audit(p_tenant_id, 'rent.generated', 'tenant', p_tenant_id,
    jsonb_build_object('month', v_start, 'property_id', p_property_id, 'created', v_created, 'skipped', v_skipped, 'total_paise', v_total));
  return jsonb_build_object('created', v_created, 'skipped', v_skipped, 'total_paise', v_total, 'month', v_start);
end;
$$;

create or replace function public.void_invoice(p_invoice_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invoice public.invoices;
  v_released bigint;
begin
  select * into v_invoice from public.invoices i where i.id = p_invoice_id for update;
  perform private.require_write(v_invoice.tenant_id, private.r_ops());
  if v_invoice.status = 'void' then
    perform private.fail('This invoice is already void');
  end if;
  if char_length(coalesce(private.clean_text(p_reason), '')) < 3 then
    perform private.fail('Give a reason for voiding this invoice');
  end if;
  v_released := v_invoice.paid_paise;
  -- Payments stay recorded; their amounts become credit for other invoices.
  update public.payment_allocations set voided_at = now() where invoice_id = p_invoice_id and voided_at is null;
  update public.invoices
     set status = 'void', voided_at = now(), voided_by = auth.uid(), void_reason = private.clean_text(p_reason)
   where id = p_invoice_id;
  perform private.apply_resident_credit(v_invoice.tenant_id, v_invoice.resident_id);
  perform private.audit(v_invoice.tenant_id, 'invoice.voided', 'invoice', p_invoice_id,
    jsonb_build_object('reason', private.clean_text(p_reason), 'total_paise', v_invoice.total_paise, 'released_paise', v_released));
end;
$$;

-- p_data: { amount_paise, paid_on, method, reference?, notes?, idempotency_key,
--           allocations?: [{ invoice_id, amount_paise }], allow_duplicate? }
create or replace function public.record_payment(p_resident_id uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_resident public.residents;
  v_settings public.tenant_settings;
  v_key uuid;
  v_existing public.payments;
  v_amount bigint := private.to_paise(p_data -> 'amount_paise', 'Amount');
  v_paid_on date := coalesce((private.clean_text(p_data ->> 'paid_on'))::date, private.today());
  v_method public.payment_method;
  v_reference text := left(private.clean_text(p_data ->> 'reference'), 100);
  v_property_id uuid;
  v_payment_id uuid;
  v_alloc jsonb;
  v_alloc_amount bigint;
  v_invoice public.invoices;
begin
  select * into v_resident from public.residents r where r.id = p_resident_id;
  perform private.require_write(v_resident.tenant_id, private.r_finance());

  begin
    v_key := (p_data ->> 'idempotency_key')::uuid;
  exception when invalid_text_representation then
    perform private.fail('Invalid idempotency key');
  end;
  if v_key is null then
    perform private.fail('An idempotency key is required');
  end if;

  -- Retrying the same request returns the original payment.
  select * into v_existing from public.payments p where p.tenant_id = v_resident.tenant_id and p.idempotency_key = v_key;
  if found then
    if v_existing.resident_id <> p_resident_id or v_existing.amount_paise <> v_amount then
      perform private.fail('This request key was already used for a different payment', 'idempotency_conflict');
    end if;
    return v_existing.id;
  end if;

  if v_amount is null or v_amount <= 0 then
    perform private.fail('Payment amount must be greater than zero');
  end if;
  if v_paid_on > private.today() then
    perform private.fail('Payment date cannot be in the future');
  end if;
  begin
    v_method := (p_data ->> 'method')::public.payment_method;
  exception when invalid_text_representation then
    perform private.fail('Unknown payment method');
  end;
  select * into v_settings from public.tenant_settings s where s.tenant_id = v_resident.tenant_id;
  if v_method is null or not (v_method = any (v_settings.payment_methods)) then
    perform private.fail('This payment method is not enabled in your settings');
  end if;

  -- Guard against accidental double entry of the same transaction.
  if not coalesce((p_data ->> 'allow_duplicate')::boolean, false) and exists (
    select 1 from public.payments p
     where p.tenant_id = v_resident.tenant_id
       and p.resident_id = p_resident_id
       and p.status in ('recorded', 'succeeded')
       and p.amount_paise = v_amount
       and p.paid_on = v_paid_on
       and p.method = v_method
       and (v_reference is null or p.reference = v_reference)
       and p.created_at > now() - interval '10 minutes'
  ) then
    perform private.fail('A matching payment was recorded moments ago. Confirm to record it again.', 'possible_duplicate');
  end if;

  select s.property_id into v_property_id from public.stays s where s.resident_id = p_resident_id and s.status = 'active';
  if v_property_id is null then
    select s.property_id into v_property_id from public.stays s where s.resident_id = p_resident_id order by s.move_in_date desc limit 1;
  end if;

  begin
    insert into public.payments (
      tenant_id, resident_id, property_id, receipt_number, amount_paise, paid_on, method,
      source, status, reference, notes, idempotency_key, recorded_by
    ) values (
      v_resident.tenant_id, p_resident_id, v_property_id,
      private.next_document_number(v_resident.tenant_id, 'receipt'),
      v_amount, v_paid_on, v_method, 'manual', 'recorded', v_reference,
      left(private.clean_text(p_data ->> 'notes'), 1000), v_key, auth.uid()
    )
    returning id into v_payment_id;
  exception when unique_violation then
    -- A concurrent retry with the same key won; return its payment.
    select p.id into v_payment_id from public.payments p where p.tenant_id = v_resident.tenant_id and p.idempotency_key = v_key;
    if v_payment_id is null then
      raise;
    end if;
    return v_payment_id;
  end;

  if jsonb_typeof(p_data -> 'allocations') = 'array' and jsonb_array_length(p_data -> 'allocations') > 0 then
    for v_alloc in select * from jsonb_array_elements(p_data -> 'allocations') loop
      v_alloc_amount := private.to_paise(v_alloc -> 'amount_paise', 'Allocation amount');
      continue when coalesce(v_alloc_amount, 0) = 0;
      select * into v_invoice from public.invoices i
       where i.id = (v_alloc ->> 'invoice_id')::uuid
         and i.tenant_id = v_resident.tenant_id
         and i.resident_id = p_resident_id
       for update;
      if v_invoice.id is null then
        perform private.fail('Invoice not found for this resident', 'not_found', 'P0002');
      end if;
      if v_invoice.status <> 'issued' then
        perform private.fail(format('Invoice %s is void', v_invoice.invoice_number));
      end if;
      if v_alloc_amount < 0 or v_alloc_amount > v_invoice.total_paise - v_invoice.paid_paise then
        perform private.fail(format('Amount for %s exceeds its balance', v_invoice.invoice_number), 'over_allocated');
      end if;
      insert into public.payment_allocations (tenant_id, resident_id, payment_id, invoice_id, amount_paise)
      values (v_resident.tenant_id, p_resident_id, v_payment_id, v_invoice.id, v_alloc_amount);
    end loop;
  else
    perform private.allocate_payment(v_payment_id);
  end if;

  perform private.audit(v_resident.tenant_id, 'payment.recorded', 'payment', v_payment_id,
    jsonb_build_object('resident_id', p_resident_id, 'amount_paise', v_amount, 'method', v_method, 'paid_on', v_paid_on));
  return v_payment_id;
exception
  when invalid_datetime_format or datetime_field_overflow then
    perform private.fail('Payment date is not valid');
end;
$$;

create or replace function public.void_payment(p_payment_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments;
begin
  select * into v_payment from public.payments p where p.id = p_payment_id for update;
  perform private.require_write(v_payment.tenant_id, private.r_ops());
  if v_payment.source <> 'manual' then
    perform private.fail('Gateway payments must be refunded through the payment provider');
  end if;
  if v_payment.status = 'voided' then
    perform private.fail('This payment is already void');
  end if;
  if char_length(coalesce(private.clean_text(p_reason), '')) < 3 then
    perform private.fail('Give a reason for voiding this payment');
  end if;
  update public.payment_allocations set voided_at = now() where payment_id = p_payment_id and voided_at is null;
  update public.payments
     set status = 'voided', voided_at = now(), voided_by = auth.uid(), void_reason = private.clean_text(p_reason)
   where id = p_payment_id;
  perform private.audit(v_payment.tenant_id, 'payment.voided', 'payment', p_payment_id,
    jsonb_build_object('reason', private.clean_text(p_reason), 'amount_paise', v_payment.amount_paise,
                       'receipt_number', v_payment.receipt_number, 'resident_id', v_payment.resident_id));
end;
$$;

-- Deposit ledger. p_data: { kind, amount_paise, txn_date?, method?, reference?, notes?, stay_id?, idempotency_key }
create or replace function public.record_deposit(p_resident_id uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_resident public.residents;
  v_kind public.deposit_txn_kind;
  v_amount bigint := private.to_paise(p_data -> 'amount_paise', 'Amount');
  v_key uuid := (p_data ->> 'idempotency_key')::uuid;
  v_held bigint;
  v_existing uuid;
  v_id uuid;
  v_stay_id uuid := (private.clean_text(p_data ->> 'stay_id'))::uuid;
begin
  select * into v_resident from public.residents r where r.id = p_resident_id;
  perform private.require_write(v_resident.tenant_id, private.r_finance());
  if v_key is null then
    perform private.fail('An idempotency key is required');
  end if;
  select d.id into v_existing from public.deposit_transactions d
   where d.tenant_id = v_resident.tenant_id and d.idempotency_key = v_key;
  if found then
    return v_existing;
  end if;
  begin
    v_kind := (p_data ->> 'kind')::public.deposit_txn_kind;
  exception when invalid_text_representation then
    perform private.fail('Unknown deposit transaction type');
  end;
  if v_kind is null then
    perform private.fail('Choose collected, refunded or deducted');
  end if;
  if v_amount is null or v_amount <= 0 then
    perform private.fail('Amount must be greater than zero');
  end if;

  perform pg_advisory_xact_lock(hashtextextended('deposit:' || p_resident_id::text, 0));
  if v_kind in ('refunded', 'deducted') then
    select coalesce(sum(case when d.kind = 'collected' then d.amount_paise else -d.amount_paise end), 0)
      into v_held
      from public.deposit_transactions d where d.resident_id = p_resident_id;
    if v_amount > v_held then
      perform private.fail('Amount exceeds the deposit currently held', 'exceeds_deposit_held');
    end if;
    if v_kind = 'deducted' and private.clean_text(p_data ->> 'notes') is null then
      perform private.fail('Add a note explaining the deduction');
    end if;
  end if;

  if v_stay_id is null then
    select s.id into v_stay_id from public.stays s where s.resident_id = p_resident_id order by (s.status = 'active') desc, s.move_in_date desc limit 1;
  end if;

  insert into public.deposit_transactions (tenant_id, resident_id, stay_id, kind, amount_paise, txn_date, method, reference, notes, idempotency_key, recorded_by)
  values (
    v_resident.tenant_id, p_resident_id, v_stay_id, v_kind, v_amount,
    coalesce((private.clean_text(p_data ->> 'txn_date'))::date, private.today()),
    (private.clean_text(p_data ->> 'method'))::public.payment_method,
    left(private.clean_text(p_data ->> 'reference'), 100),
    left(private.clean_text(p_data ->> 'notes'), 1000),
    v_key, auth.uid()
  )
  returning id into v_id;

  perform private.audit(v_resident.tenant_id, 'deposit.' || v_kind, 'resident', p_resident_id,
    jsonb_build_object('amount_paise', v_amount, 'deposit_transaction_id', v_id));
  return v_id;
exception
  when foreign_key_violation then
    perform private.fail('Stay not found for this resident', 'not_found', 'P0002');
end;
$$;

-- =============================================================================
-- Expenses
-- =============================================================================
create or replace function public.save_expense(p_tenant_id uuid, p_expense_id uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := p_tenant_id;
  v_id uuid := p_expense_id;
  v_property uuid := (private.clean_text(p_data ->> 'property_id'))::uuid;
begin
  if v_id is not null then
    select e.tenant_id into v_tenant_id from public.expenses e where e.id = v_id;
  end if;
  perform private.require_write(v_tenant_id, private.r_finance());
  if v_property is not null and not exists (select 1 from public.properties p where p.id = v_property and p.tenant_id = v_tenant_id) then
    perform private.fail('Property not found', 'not_found', 'P0002');
  end if;

  if v_id is null then
    insert into public.expenses (tenant_id, property_id, category, amount_paise, expense_date, payee, method, reference, notes, receipt_path, created_by)
    values (
      v_tenant_id, v_property,
      private.clean_text(p_data ->> 'category'),
      private.to_paise(p_data -> 'amount_paise', 'Amount'),
      coalesce((private.clean_text(p_data ->> 'expense_date'))::date, private.today()),
      private.clean_text(p_data ->> 'payee'),
      (private.clean_text(p_data ->> 'method'))::public.payment_method,
      private.clean_text(p_data ->> 'reference'),
      private.clean_text(p_data ->> 'notes'),
      private.clean_text(p_data ->> 'receipt_path'),
      auth.uid()
    )
    returning id into v_id;
    perform private.audit(v_tenant_id, 'expense.created', 'expense', v_id,
      jsonb_build_object('amount_paise', private.to_paise(p_data -> 'amount_paise', 'Amount'), 'category', private.clean_text(p_data ->> 'category')));
  else
    update public.expenses e set
      property_id = case when p_data ? 'property_id' then v_property else e.property_id end,
      category = case when p_data ? 'category' then private.clean_text(p_data ->> 'category') else e.category end,
      amount_paise = case when p_data ? 'amount_paise' then private.to_paise(p_data -> 'amount_paise', 'Amount') else e.amount_paise end,
      expense_date = case when p_data ? 'expense_date' then (private.clean_text(p_data ->> 'expense_date'))::date else e.expense_date end,
      payee = case when p_data ? 'payee' then private.clean_text(p_data ->> 'payee') else e.payee end,
      method = case when p_data ? 'method' then (private.clean_text(p_data ->> 'method'))::public.payment_method else e.method end,
      reference = case when p_data ? 'reference' then private.clean_text(p_data ->> 'reference') else e.reference end,
      notes = case when p_data ? 'notes' then private.clean_text(p_data ->> 'notes') else e.notes end,
      receipt_path = case when p_data ? 'receipt_path' then private.clean_text(p_data ->> 'receipt_path') else e.receipt_path end
    where e.id = v_id;
    perform private.audit(v_tenant_id, 'expense.updated', 'expense', v_id, p_data - 'notes');
  end if;
  return v_id;
exception
  when not_null_violation or check_violation then
    perform private.fail('Category, a positive amount and a date are required');
  when invalid_text_representation then
    perform private.fail('Unknown payment method');
end;
$$;

create or replace function public.delete_expense(p_expense_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expense public.expenses;
begin
  select * into v_expense from public.expenses e where e.id = p_expense_id;
  perform private.require_write(v_expense.tenant_id, private.r_ops());
  delete from public.expenses where id = p_expense_id;
  -- The audit log keeps a full snapshot so the deletion is traceable.
  perform private.audit(v_expense.tenant_id, 'expense.deleted', 'expense', p_expense_id, to_jsonb(v_expense));
end;
$$;

-- =============================================================================
-- Team members and invitations
-- =============================================================================
create or replace function private.new_invitation_token()
returns text
language sql
volatile
set search_path = ''
as $$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
$$;

create or replace function private.hash_token(p_token text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
$$;

create or replace function private.check_invitation_rate(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.invitations i where i.tenant_id = p_tenant_id and i.created_at > now() - interval '1 hour') >= 30 then
    perform private.fail('Too many invitations sent in the last hour. Try again later.', 'rate_limited');
  end if;
end;
$$;

create or replace function public.invite_member(p_tenant_id uuid, p_email text, p_role public.tenant_role)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := private.check_email(p_email);
  v_token text := private.new_invitation_token();
  v_id uuid;
  v_expires timestamptz := now() + interval '7 days';
  v_plan public.plans;
begin
  perform private.require_write(p_tenant_id, private.r_owner());
  if v_email is null then
    perform private.fail('Email is required');
  end if;
  if p_role is null or p_role = 'owner' then
    perform private.fail('Choose manager, accountant or staff');
  end if;
  perform private.check_invitation_rate(p_tenant_id);
  if exists (
    select 1 from public.tenant_memberships m join auth.users u on u.id = m.user_id
     where m.tenant_id = p_tenant_id and lower(u.email) = v_email
  ) then
    perform private.fail('This person is already a member of your team', 'duplicate');
  end if;
  v_plan := private.tenant_plan(p_tenant_id);
  if v_plan.max_staff is not null and (
    select count(*) from public.tenant_memberships m where m.tenant_id = p_tenant_id and m.role <> 'owner' and m.status = 'active'
  ) >= v_plan.max_staff then
    perform private.fail(format('Your %s plan allows up to %s team members. Upgrade your plan to add more.', v_plan.name, v_plan.max_staff), 'plan_limit');
  end if;

  update public.invitations set revoked_at = now()
   where tenant_id = p_tenant_id and email = v_email and kind = 'member' and accepted_at is null and revoked_at is null;
  insert into public.invitations (tenant_id, kind, email, role, token_hash, invited_by, expires_at)
  values (p_tenant_id, 'member', v_email, p_role, private.hash_token(v_token), auth.uid(), v_expires)
  returning id into v_id;
  perform private.audit(p_tenant_id, 'invitation.created', 'invitation', v_id, jsonb_build_object('role', p_role));
  -- The plain token is returned once so the owner can share the link.
  return jsonb_build_object('id', v_id, 'token', v_token, 'expires_at', v_expires);
end;
$$;

create or replace function public.invite_resident(p_resident_id uuid, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_resident public.residents;
  v_email text := private.check_email(p_email);
  v_token text := private.new_invitation_token();
  v_id uuid;
  v_expires timestamptz := now() + interval '7 days';
begin
  select * into v_resident from public.residents r where r.id = p_resident_id;
  perform private.require_write(v_resident.tenant_id, private.r_ops());
  v_email := coalesce(v_email, v_resident.email);
  if v_email is null then
    perform private.fail('Add an email address for this resident first');
  end if;
  if exists (select 1 from public.resident_user_links l where l.resident_id = p_resident_id) then
    perform private.fail('This resident already has an app account linked', 'duplicate');
  end if;
  perform private.check_invitation_rate(v_resident.tenant_id);
  update public.invitations set revoked_at = now()
   where resident_id = p_resident_id and accepted_at is null and revoked_at is null;
  insert into public.invitations (tenant_id, kind, email, resident_id, token_hash, invited_by, expires_at)
  values (v_resident.tenant_id, 'resident', v_email, p_resident_id, private.hash_token(v_token), auth.uid(), v_expires)
  returning id into v_id;
  perform private.audit(v_resident.tenant_id, 'invitation.created', 'invitation', v_id, jsonb_build_object('kind', 'resident'));
  return jsonb_build_object('id', v_id, 'token', v_token, 'expires_at', v_expires);
end;
$$;

create or replace function public.revoke_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  select i.tenant_id into v_tenant_id from public.invitations i where i.id = p_invitation_id;
  perform private.require_write(v_tenant_id, private.r_ops());
  update public.invitations set revoked_at = now() where id = p_invitation_id and accepted_at is null and revoked_at is null;
  perform private.audit(v_tenant_id, 'invitation.revoked', 'invitation', p_invitation_id);
end;
$$;

create or replace function public.accept_invitation(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_auth();
  v_inv public.invitations;
  v_email text;
  v_confirmed timestamptz;
begin
  if p_token is null or char_length(p_token) <> 64 then
    perform private.fail('This invitation link is invalid', 'invalid_invitation');
  end if;
  select * into v_inv from public.invitations i where i.token_hash = private.hash_token(p_token) for update;
  if v_inv.id is null or v_inv.revoked_at is not null then
    perform private.fail('This invitation link is invalid or has been revoked', 'invalid_invitation');
  end if;
  if v_inv.accepted_at is not null then
    if v_inv.accepted_by = v_uid then
      return jsonb_build_object('tenant_id', v_inv.tenant_id, 'kind', v_inv.kind);
    end if;
    perform private.fail('This invitation has already been used', 'invalid_invitation');
  end if;
  if v_inv.expires_at < now() then
    perform private.fail('This invitation has expired. Ask for a new one.', 'invitation_expired');
  end if;

  select lower(u.email), u.email_confirmed_at into v_email, v_confirmed from auth.users u where u.id = v_uid;
  if v_email is distinct from v_inv.email then
    perform private.fail('This invitation was sent to a different email address', 'email_mismatch', '42501');
  end if;
  if v_confirmed is null then
    perform private.fail('Verify your email address before accepting', 'not_verified', '42501');
  end if;

  if v_inv.kind = 'member' then
    insert into public.tenant_memberships (tenant_id, user_id, role, invited_by)
    values (v_inv.tenant_id, v_uid, v_inv.role, v_inv.invited_by)
    on conflict (tenant_id, user_id) do nothing;
  else
    if exists (select 1 from public.resident_user_links l where l.tenant_id = v_inv.tenant_id and l.user_id = v_uid) then
      perform private.fail('Your account is already linked to a resident in this business', 'duplicate');
    end if;
    insert into public.resident_user_links (tenant_id, resident_id, user_id)
    values (v_inv.tenant_id, v_inv.resident_id, v_uid);
  end if;

  update public.invitations set accepted_at = now(), accepted_by = v_uid where id = v_inv.id;
  perform private.audit(v_inv.tenant_id, 'invitation.accepted', 'invitation', v_inv.id, jsonb_build_object('kind', v_inv.kind));
  return jsonb_build_object('tenant_id', v_inv.tenant_id, 'kind', v_inv.kind);
end;
$$;

create or replace function public.update_member(p_membership_id uuid, p_role public.tenant_role, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.tenant_memberships;
begin
  select * into v_member from public.tenant_memberships m where m.id = p_membership_id for update;
  perform private.require_write(v_member.tenant_id, private.r_owner());
  if p_status not in ('active', 'suspended') then
    perform private.fail('Unknown member status');
  end if;
  if v_member.role = 'owner' and (p_role <> 'owner' or p_status <> 'active') and (
    select count(*) from public.tenant_memberships m
     where m.tenant_id = v_member.tenant_id and m.role = 'owner' and m.status = 'active'
  ) <= 1 then
    perform private.fail('A workspace must keep at least one active owner', 'last_owner');
  end if;
  update public.tenant_memberships set role = p_role, status = p_status where id = p_membership_id;
  perform private.audit(v_member.tenant_id, 'member.updated', 'membership', p_membership_id,
    jsonb_build_object('role', p_role, 'status', p_status, 'previous_role', v_member.role));
end;
$$;

create or replace function public.remove_member(p_membership_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.tenant_memberships;
begin
  select * into v_member from public.tenant_memberships m where m.id = p_membership_id for update;
  perform private.require_write(v_member.tenant_id, private.r_owner());
  if v_member.role = 'owner' and (
    select count(*) from public.tenant_memberships m
     where m.tenant_id = v_member.tenant_id and m.role = 'owner' and m.status = 'active'
  ) <= 1 then
    perform private.fail('A workspace must keep at least one active owner', 'last_owner');
  end if;
  delete from public.tenant_memberships where id = p_membership_id;
  perform private.audit(v_member.tenant_id, 'member.removed', 'membership', p_membership_id,
    jsonb_build_object('user_id', v_member.user_id, 'role', v_member.role));
end;
$$;
