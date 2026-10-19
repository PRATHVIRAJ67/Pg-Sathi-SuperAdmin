-- =============================================================================
-- Authorization: helper functions, Row Level Security and grants.
--
-- Model
--   * Tenant access comes only from tenant_memberships rows tied to auth.uid().
--     A tenant id supplied by a client is never trusted on its own.
--   * Residents with app accounts see only their own records through
--     resident_user_links.
--   * Clients get SELECT on tables (filtered by RLS). Every INSERT/UPDATE/DELETE
--     goes through SECURITY DEFINER functions that check roles explicitly and
--     write audit logs. No table grants INSERT/UPDATE/DELETE to client roles.
--   * Platform admins are a separate mechanism (platform_admins) and do NOT get
--     blanket read access to resident or financial records.
-- =============================================================================

-- Role groups ---------------------------------------------------------------
-- owner      : everything, including settings, team and plan
-- manager    : operations + finance, no settings/team
-- accountant : finance (invoices, payments, deposits, expenses, reports)
-- staff      : read properties/rooms/residents, maintenance tickets

create or replace function private.tenant_ids_with_role(p_roles public.tenant_role[])
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.tenant_id
    from public.tenant_memberships m
   where m.user_id = auth.uid()
     and m.status = 'active'
     and m.role = any (p_roles);
$$;

create or replace function private.member_tenant_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.tenant_id
    from public.tenant_memberships m
   where m.user_id = auth.uid()
     and m.status = 'active';
$$;

create or replace function private.finance_tenant_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select private.tenant_ids_with_role(array['owner', 'manager', 'accountant']::public.tenant_role[]);
$$;

create or replace function private.my_resident_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select l.resident_id from public.resident_user_links l where l.user_id = auth.uid();
$$;

create or replace function private.my_resident_tenant_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select l.tenant_id from public.resident_user_links l where l.user_id = auth.uid();
$$;

create or replace function private.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.platform_admins a where a.user_id = auth.uid());
$$;

create or replace function private.member_role(p_tenant_id uuid)
returns public.tenant_role
language sql
stable
security definer
set search_path = ''
as $$
  select m.role
    from public.tenant_memberships m
   where m.tenant_id = p_tenant_id
     and m.user_id = auth.uid()
     and m.status = 'active';
$$;

create or replace function private.require_auth()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Sign in to continue' using errcode = '28000', hint = 'not_authenticated';
  end if;
  return v_uid;
end;
$$;

-- Raises unless the caller holds one of p_roles in p_tenant_id.
create or replace function private.require_role(p_tenant_id uuid, p_roles public.tenant_role[])
returns public.tenant_role
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.tenant_role;
begin
  perform private.require_auth();
  if p_tenant_id is null then
    raise exception 'Record not found' using errcode = 'P0002', hint = 'not_found';
  end if;
  v_role := private.member_role(p_tenant_id);
  if v_role is null then
    -- Do not reveal whether the tenant exists.
    raise exception 'Record not found' using errcode = 'P0002', hint = 'not_found';
  end if;
  if not (v_role = any (p_roles)) then
    raise exception 'Your role (%) is not allowed to perform this action', v_role
      using errcode = '42501', hint = 'forbidden';
  end if;
  return v_role;
end;
$$;

-- Like require_role, but also blocks writes for suspended/cancelled tenants.
create or replace function private.require_write(p_tenant_id uuid, p_roles public.tenant_role[])
returns public.tenant_role
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.tenant_role;
  v_status public.tenant_status;
begin
  v_role := private.require_role(p_tenant_id, p_roles);
  select t.status into v_status from public.tenants t where t.id = p_tenant_id;
  if v_status in ('suspended', 'cancelled') then
    raise exception 'This workspace is %. Contact support to restore access.', v_status
      using errcode = '42501', hint = 'tenant_inactive';
  end if;
  return v_role;
end;
$$;

create or replace function private.require_platform_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_auth();
begin
  if not private.is_platform_admin() then
    raise exception 'Platform administrator access required' using errcode = '42501', hint = 'forbidden';
  end if;
  return v_uid;
end;
$$;

-- ---------------------------------------------------------------------------
-- Plan limits — enforced on the server for every insert path.
-- ---------------------------------------------------------------------------
create or replace function private.tenant_plan(p_tenant_id uuid)
returns public.plans
language sql
stable
security definer
set search_path = ''
as $$
  select p.*
    from public.subscriptions s
    join public.plans p on p.id = s.plan_id
   where s.tenant_id = p_tenant_id;
$$;

create or replace function private.enforce_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan public.plans;
  v_limit integer;
  v_count integer;
  v_label text;
begin
  v_plan := private.tenant_plan(new.tenant_id);
  if v_plan.id is null then
    return new; -- no subscription row yet (provisioning creates it first)
  end if;

  if tg_table_name = 'properties' then
    v_limit := v_plan.max_properties;
    v_label := 'properties';
    select count(*) into v_count from public.properties
     where tenant_id = new.tenant_id and status = 'active';
  elsif tg_table_name = 'residents' then
    v_limit := v_plan.max_residents;
    v_label := 'residents';
    select count(*) into v_count from public.residents
     where tenant_id = new.tenant_id and archived_at is null;
  elsif tg_table_name = 'tenant_memberships' then
    if new.role = 'owner' then
      return new;
    end if;
    v_limit := v_plan.max_staff;
    v_label := 'team members';
    select count(*) into v_count from public.tenant_memberships
     where tenant_id = new.tenant_id and role <> 'owner' and status = 'active';
  else
    return new;
  end if;

  if v_limit is not null and v_count >= v_limit then
    raise exception 'Your % plan allows up to % %. Upgrade your plan to add more.', v_plan.name, v_limit, v_label
      using errcode = 'P0001', hint = 'plan_limit', detail = v_label;
  end if;
  return new;
end;
$$;

create trigger properties_plan_limit before insert on public.properties
  for each row execute function private.enforce_plan_limit();
create trigger residents_plan_limit before insert on public.residents
  for each row execute function private.enforce_plan_limit();
create trigger memberships_plan_limit before insert on public.tenant_memberships
  for each row execute function private.enforce_plan_limit();

-- Tenant ownership of a row can never change after insert.
create or replace function private.prevent_tenant_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.tenant_id is distinct from old.tenant_id then
    raise exception 'tenant_id is immutable' using errcode = '42501', hint = 'forbidden';
  end if;
  return new;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array[
    'tenant_settings', 'subscriptions', 'tenant_memberships', 'properties', 'property_settings',
    'rooms', 'beds', 'residents', 'resident_user_links', 'stays', 'charge_templates',
    'maintenance_tickets', 'invitations', 'invoices', 'invoice_items', 'payments',
    'payment_allocations', 'deposit_transactions', 'expenses', 'audit_logs'
  ] loop
    execute format(
      'create trigger %I before update on public.%I for each row execute function private.prevent_tenant_change()',
      t || '_tenant_immutable', t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.platform_admins enable row level security;
alter table public.plans enable row level security;
alter table public.platform_settings enable row level security;
alter table public.tenants enable row level security;
alter table public.tenant_settings enable row level security;
alter table public.subscriptions enable row level security;
alter table public.tenant_memberships enable row level security;
alter table public.audit_logs enable row level security;
alter table public.properties enable row level security;
alter table public.property_settings enable row level security;
alter table public.rooms enable row level security;
alter table public.beds enable row level security;
alter table public.residents enable row level security;
alter table public.resident_user_links enable row level security;
alter table public.stays enable row level security;
alter table public.rent_agreements enable row level security;
alter table public.charge_templates enable row level security;
alter table public.maintenance_tickets enable row level security;
alter table public.invitations enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.payments enable row level security;
alter table public.payment_allocations enable row level security;
alter table public.deposit_transactions enable row level security;
alter table public.expenses enable row level security;

-- profiles: yourself, and colleagues in tenants you belong to.
create policy profiles_select on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or id in (
      select m.user_id from public.tenant_memberships m
       where m.tenant_id in (select private.member_tenant_ids())
    )
  );

-- platform_admins: no client access at all (checked via private.is_platform_admin()).

-- plans: everyone signed in can read active public plans; members can read their own plan.
create policy plans_select on public.plans for select to authenticated
  using (
    (is_active and is_public)
    or id in (select s.plan_id from public.subscriptions s where s.tenant_id in (select private.member_tenant_ids()))
    or (select private.is_platform_admin())
  );

create policy platform_settings_select on public.platform_settings for select to authenticated
  using ((select private.is_platform_admin()));

create policy tenants_select on public.tenants for select to authenticated
  using (
    id in (select private.member_tenant_ids())
    or id in (select private.my_resident_tenant_ids())
  );

create policy tenant_settings_select on public.tenant_settings for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()));

create policy subscriptions_select on public.subscriptions for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()));

create policy tenant_memberships_select on public.tenant_memberships for select to authenticated
  using (user_id = (select auth.uid()) or tenant_id in (select private.member_tenant_ids()));

create policy audit_logs_select on public.audit_logs for select to authenticated
  using (tenant_id in (select private.tenant_ids_with_role(array['owner', 'manager']::public.tenant_role[])));

create policy properties_select on public.properties for select to authenticated
  using (
    tenant_id in (select private.member_tenant_ids())
    or id in (select s.property_id from public.stays s where s.resident_id in (select private.my_resident_ids()))
  );

create policy property_settings_select on public.property_settings for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()));

create policy rooms_select on public.rooms for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()));

create policy beds_select on public.beds for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()));

create policy residents_select on public.residents for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()) or id in (select private.my_resident_ids()));

create policy resident_user_links_select on public.resident_user_links for select to authenticated
  using (
    user_id = (select auth.uid())
    or tenant_id in (select private.tenant_ids_with_role(array['owner', 'manager']::public.tenant_role[]))
  );

create policy stays_select on public.stays for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()) or resident_id in (select private.my_resident_ids()));

create policy rent_agreements_select on public.rent_agreements for select to authenticated
  using (tenant_id in (select private.finance_tenant_ids()) or resident_id in (select private.my_resident_ids()));

create policy charge_templates_select on public.charge_templates for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()));

create policy maintenance_tickets_select on public.maintenance_tickets for select to authenticated
  using (tenant_id in (select private.member_tenant_ids()) or resident_id in (select private.my_resident_ids()));

create policy invitations_select on public.invitations for select to authenticated
  using (tenant_id in (select private.tenant_ids_with_role(array['owner']::public.tenant_role[])));

create policy invoices_select on public.invoices for select to authenticated
  using (tenant_id in (select private.finance_tenant_ids()) or resident_id in (select private.my_resident_ids()));

create policy invoice_items_select on public.invoice_items for select to authenticated
  using (
    tenant_id in (select private.finance_tenant_ids())
    or invoice_id in (select i.id from public.invoices i where i.resident_id in (select private.my_resident_ids()))
  );

create policy payments_select on public.payments for select to authenticated
  using (tenant_id in (select private.finance_tenant_ids()) or resident_id in (select private.my_resident_ids()));

create policy payment_allocations_select on public.payment_allocations for select to authenticated
  using (tenant_id in (select private.finance_tenant_ids()) or resident_id in (select private.my_resident_ids()));

create policy deposit_transactions_select on public.deposit_transactions for select to authenticated
  using (tenant_id in (select private.finance_tenant_ids()) or resident_id in (select private.my_resident_ids()));

create policy expenses_select on public.expenses for select to authenticated
  using (tenant_id in (select private.finance_tenant_ids()));

-- ---------------------------------------------------------------------------
-- Grants. Supabase grants broad default privileges on the public schema; we
-- reset them explicitly so the model above is the only path.
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
grant select on all tables in schema public to authenticated;
revoke select on public.platform_admins from authenticated;

-- The private schema is not exposed by the Data API, but grant only what RLS
-- policies and SECURITY INVOKER read functions actually need, nothing more.
grant usage on schema private to authenticated;
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function
  private.today(),
  private.clean_text(text),
  private.invoice_payment_status(public.invoice_status, bigint, bigint, date),
  private.tenant_ids_with_role(public.tenant_role[]),
  private.member_tenant_ids(),
  private.finance_tenant_ids(),
  private.my_resident_ids(),
  private.my_resident_tenant_ids(),
  private.is_platform_admin(),
  private.member_role(uuid),
  private.require_auth(),
  private.require_role(uuid, public.tenant_role[])
to authenticated;

alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon;
