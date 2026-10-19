-- =============================================================================
-- Platform administration API. Requires a row in platform_admins (inserted by
-- an operator with SQL — see docs/OPERATIONS.md). Admin functions return
-- aggregate counts and business-level metadata only: no resident personal
-- data and no financial records. Every change is audited.
-- =============================================================================

create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_admin();
  return jsonb_build_object(
    'tenants_total', (select count(*) from public.tenants),
    'tenants_by_status', coalesce((
      select jsonb_object_agg(s.status, s.n) from (select t.status, count(*) as n from public.tenants t group by t.status) s), '{}'::jsonb),
    'new_tenants_30d', (select count(*) from public.tenants t where t.created_at > now() - interval '30 days'),
    'onboarding_incomplete', (select count(*) from public.tenants t where t.onboarding_completed_at is null),
    'subscriptions_by_plan', coalesce((
      select jsonb_agg(jsonb_build_object('plan_id', p.id, 'code', p.code, 'name', p.name, 'count', (
               select count(*) from public.subscriptions s where s.plan_id = p.id)) order by p.sort_order)
        from public.plans p), '[]'::jsonb),
    'trials_ending_7d', (select count(*) from public.subscriptions s where s.status = 'trialing' and s.trial_ends_at between now() and now() + interval '7 days'),
    'usage', jsonb_build_object(
      'properties', (select count(*) from public.properties p where p.status = 'active'),
      'beds', (select count(*) from public.beds),
      'active_stays', (select count(*) from public.stays s where s.status = 'active'),
      'residents', (select count(*) from public.residents r where r.archived_at is null),
      'team_members', (select count(*) from public.tenant_memberships m where m.status = 'active')
    ),
    'signups_by_month', coalesce((
      select jsonb_agg(jsonb_build_object('month', m.month::date, 'count', (
               select count(*) from public.tenants t where t.created_at >= m.month and t.created_at < m.month + interval '1 month')) order by m.month)
        from generate_series(date_trunc('month', now()) - interval '5 months', date_trunc('month', now()), interval '1 month') m(month)), '[]'::jsonb),
    'recent_tenants', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.created_at desc)
        from (
          select t.id, t.name, t.status, t.city, t.created_at, t.onboarding_completed_at, p.name as plan_name
            from public.tenants t
            left join public.subscriptions s on s.tenant_id = t.id
            left join public.plans p on p.id = s.plan_id
           order by t.created_at desc limit 8) q), '[]'::jsonb)
  );
end;
$$;

-- p_params: { search?, status?, plan_id?, limit?, offset? }
create or replace function public.admin_list_tenants(p_params jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_search text := lower(private.clean_text(p_params ->> 'search'));
  v_status text := private.clean_text(p_params ->> 'status');
  v_plan uuid := (private.clean_text(p_params ->> 'plan_id'))::uuid;
  v_limit integer := least(greatest(coalesce((p_params ->> 'limit')::integer, 50), 1), 200);
  v_offset integer := greatest(coalesce((p_params ->> 'offset')::integer, 0), 0);
  v_result jsonb;
begin
  perform private.require_platform_admin();
  with filtered as (
    select t.id, t.name, t.status, t.city, t.state, t.contact_name, t.contact_email, t.contact_phone,
           t.created_at, t.onboarding_completed_at, t.onboarding_step,
           s.status as subscription_status, s.trial_ends_at, p.id as plan_id, p.name as plan_name,
           (select count(*) from public.properties x where x.tenant_id = t.id and x.status = 'active') as property_count,
           (select count(*) from public.residents x where x.tenant_id = t.id and x.archived_at is null) as resident_count,
           (select count(*) from public.tenant_memberships x where x.tenant_id = t.id and x.status = 'active') as member_count
      from public.tenants t
      left join public.subscriptions s on s.tenant_id = t.id
      left join public.plans p on p.id = s.plan_id
     where (v_search is null or lower(t.name) like '%' || v_search || '%'
            or lower(coalesce(t.contact_email, '')) like '%' || v_search || '%'
            or lower(coalesce(t.city, '')) like '%' || v_search || '%')
       and (v_status is null or t.status::text = v_status)
       and (v_plan is null or p.id = v_plan)
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(q) order by q.created_at desc)
        from (select * from filtered order by created_at desc limit v_limit offset v_offset) q), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function public.admin_get_tenant(p_tenant_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant public.tenants;
begin
  perform private.require_platform_admin();
  select * into v_tenant from public.tenants t where t.id = p_tenant_id;
  if v_tenant.id is null then
    perform private.fail('Tenant not found', 'not_found', 'P0002');
  end if;
  return jsonb_build_object(
    'tenant', to_jsonb(v_tenant) - 'provision_request_id',
    'subscription', (select to_jsonb(s) from public.subscriptions s where s.tenant_id = p_tenant_id),
    'plan', (select to_jsonb(p) from public.subscriptions s join public.plans p on p.id = s.plan_id where s.tenant_id = p_tenant_id),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object('role', m.role, 'status', m.status, 'full_name', pr.full_name, 'email', pr.email, 'created_at', m.created_at)
               order by (m.role = 'owner') desc, m.created_at)
        from public.tenant_memberships m left join public.profiles pr on pr.id = m.user_id
       where m.tenant_id = p_tenant_id), '[]'::jsonb),
    'usage', jsonb_build_object(
      'properties', (select count(*) from public.properties x where x.tenant_id = p_tenant_id and x.status = 'active'),
      'rooms', (select count(*) from public.rooms x where x.tenant_id = p_tenant_id),
      'beds', (select count(*) from public.beds x where x.tenant_id = p_tenant_id),
      'active_stays', (select count(*) from public.stays x where x.tenant_id = p_tenant_id and x.status = 'active'),
      'residents', (select count(*) from public.residents x where x.tenant_id = p_tenant_id and x.archived_at is null),
      'invoices', (select count(*) from public.invoices x where x.tenant_id = p_tenant_id),
      'payments', (select count(*) from public.payments x where x.tenant_id = p_tenant_id)
    ),
    'admin_activity', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'action', a.action, 'details', a.details, 'created_at', a.created_at,
                                          'actor_name', pr.full_name) order by a.id desc)
        from (select * from public.audit_logs a
               where a.tenant_id = p_tenant_id and (a.action like 'admin.%' or a.action like 'workspace.%')
               order by a.id desc limit 30) a
        left join public.profiles pr on pr.id = a.actor_id), '[]'::jsonb)
  );
end;
$$;

create or replace function public.admin_set_tenant_status(p_tenant_id uuid, p_status public.tenant_status, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.tenant_status;
begin
  perform private.require_platform_admin();
  select t.status into v_old from public.tenants t where t.id = p_tenant_id for update;
  if v_old is null then
    perform private.fail('Tenant not found', 'not_found', 'P0002');
  end if;
  if char_length(coalesce(private.clean_text(p_reason), '')) < 3 then
    perform private.fail('Give a reason for this change');
  end if;
  update public.tenants set status = p_status, status_reason = private.clean_text(p_reason) where id = p_tenant_id;
  perform private.audit(p_tenant_id, 'admin.tenant_status_changed', 'tenant', p_tenant_id,
    jsonb_build_object('from', v_old, 'to', p_status, 'reason', private.clean_text(p_reason)));
end;
$$;

create or replace function public.admin_list_plans()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_admin();
  return coalesce((
    select jsonb_agg(to_jsonb(p) || jsonb_build_object(
             'subscriber_count', (select count(*) from public.subscriptions s where s.plan_id = p.id),
             'is_default', p.id = (select ps.default_plan_id from public.platform_settings ps where ps.id))
           order by p.sort_order, p.price_paise)
      from public.plans p), '[]'::jsonb);
end;
$$;

create or replace function public.admin_save_plan(p_plan_id uuid, p_data jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := p_plan_id;
begin
  perform private.require_platform_admin();
  if v_id is null then
    insert into public.plans (code, name, description, price_paise, billing_interval, max_properties, max_residents,
                              max_staff, features, trial_days, is_public, is_active, sort_order)
    values (
      lower(private.clean_text(p_data ->> 'code')),
      private.clean_text(p_data ->> 'name'),
      private.clean_text(p_data ->> 'description'),
      coalesce(private.to_paise(p_data -> 'price_paise', 'Price'), 0),
      coalesce(private.clean_text(p_data ->> 'billing_interval'), 'month'),
      (p_data ->> 'max_properties')::integer,
      (p_data ->> 'max_residents')::integer,
      (p_data ->> 'max_staff')::integer,
      private.text_array(p_data -> 'features', 'Features'),
      coalesce((p_data ->> 'trial_days')::integer, 0),
      coalesce((p_data ->> 'is_public')::boolean, true),
      coalesce((p_data ->> 'is_active')::boolean, true),
      coalesce((p_data ->> 'sort_order')::integer, 0)
    )
    returning id into v_id;
  else
    update public.plans p set
      name = case when p_data ? 'name' then private.clean_text(p_data ->> 'name') else p.name end,
      description = case when p_data ? 'description' then private.clean_text(p_data ->> 'description') else p.description end,
      price_paise = case when p_data ? 'price_paise' then coalesce(private.to_paise(p_data -> 'price_paise', 'Price'), 0) else p.price_paise end,
      billing_interval = case when p_data ? 'billing_interval' then private.clean_text(p_data ->> 'billing_interval') else p.billing_interval end,
      max_properties = case when p_data ? 'max_properties' then (p_data ->> 'max_properties')::integer else p.max_properties end,
      max_residents = case when p_data ? 'max_residents' then (p_data ->> 'max_residents')::integer else p.max_residents end,
      max_staff = case when p_data ? 'max_staff' then (p_data ->> 'max_staff')::integer else p.max_staff end,
      features = case when p_data ? 'features' then private.text_array(p_data -> 'features', 'Features') else p.features end,
      trial_days = case when p_data ? 'trial_days' then coalesce((p_data ->> 'trial_days')::integer, 0) else p.trial_days end,
      is_public = case when p_data ? 'is_public' then (p_data ->> 'is_public')::boolean else p.is_public end,
      is_active = case when p_data ? 'is_active' then (p_data ->> 'is_active')::boolean else p.is_active end,
      sort_order = case when p_data ? 'sort_order' then coalesce((p_data ->> 'sort_order')::integer, 0) else p.sort_order end
    where p.id = v_id;
    if not found then
      perform private.fail('Plan not found', 'not_found', 'P0002');
    end if;
  end if;
  perform private.audit(null, 'admin.plan_saved', 'plan', v_id, p_data);
  return v_id;
exception
  when unique_violation then
    perform private.fail('A plan with this code already exists', 'duplicate');
  when check_violation or not_null_violation then
    perform private.fail('Check the plan code (lowercase letters, digits, - or _), name, limits and trial days');
end;
$$;

create or replace function public.admin_assign_plan(p_tenant_id uuid, p_plan_id uuid, p_status public.subscription_status, p_trial_ends_at timestamptz default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb;
begin
  perform private.require_platform_admin();
  if not exists (select 1 from public.plans p where p.id = p_plan_id) then
    perform private.fail('Plan not found', 'not_found', 'P0002');
  end if;
  select to_jsonb(s) into v_old from public.subscriptions s where s.tenant_id = p_tenant_id;
  if v_old is null then
    perform private.fail('Tenant subscription not found', 'not_found', 'P0002');
  end if;
  -- Manual assignment by an admin. No payment is implied; billing-provider
  -- integration is a later phase.
  update public.subscriptions
     set plan_id = p_plan_id,
         status = p_status,
         trial_ends_at = case when p_status = 'trialing' then coalesce(p_trial_ends_at, trial_ends_at) else trial_ends_at end
   where tenant_id = p_tenant_id;
  perform private.audit(p_tenant_id, 'admin.subscription_changed', 'subscription', (v_old ->> 'id')::uuid,
    jsonb_build_object('from_plan', v_old ->> 'plan_id', 'to_plan', p_plan_id, 'from_status', v_old ->> 'status', 'to_status', p_status));
end;
$$;

create or replace function public.admin_list_audit(p_limit integer default 50, p_before_id bigint default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_admin();
  return coalesce((
    select jsonb_agg(to_jsonb(q) order by q.id desc)
      from (
        select a.id, a.tenant_id, t.name as tenant_name, a.action, a.entity_type, a.entity_id, a.details, a.created_at,
               pr.full_name as actor_name, pr.email as actor_email
          from public.audit_logs a
          left join public.tenants t on t.id = a.tenant_id
          left join public.profiles pr on pr.id = a.actor_id
         where (a.tenant_id is null or a.action like 'admin.%' or a.action like 'workspace.%')
           and (p_before_id is null or a.id < p_before_id)
         order by a.id desc
         limit least(greatest(coalesce(p_limit, 50), 1), 200)) q), '[]'::jsonb);
end;
$$;

create or replace function public.admin_get_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_admin();
  return (select to_jsonb(s) from public.platform_settings s where s.id);
end;
$$;

create or replace function public.admin_update_settings(p_data jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_admin();
  update public.platform_settings s set
    default_plan_id = case when p_data ? 'default_plan_id' then (private.clean_text(p_data ->> 'default_plan_id'))::uuid else s.default_plan_id end,
    signup_enabled = case when p_data ? 'signup_enabled' then (p_data ->> 'signup_enabled')::boolean else s.signup_enabled end,
    support_email = case when p_data ? 'support_email' then private.check_email(p_data ->> 'support_email') else s.support_email end,
    updated_at = now(),
    updated_by = auth.uid()
  where s.id;
  perform private.audit(null, 'admin.settings_updated', 'platform_settings', null, p_data);
exception
  when foreign_key_violation then
    perform private.fail('Plan not found', 'not_found', 'P0002');
end;
$$;

create or replace function public.am_i_platform_admin()
returns boolean
language sql
stable
set search_path = ''
as $$
  select private.is_platform_admin();
$$;

-- =============================================================================
-- Final grants: only authenticated users may call the API. Nothing is callable
-- anonymously. Internal helpers remain non-executable except those needed by
-- RLS policies and SECURITY INVOKER read functions.
-- =============================================================================
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;

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
  private.require_role(uuid, public.tenant_role[]),
  private.r_all(),
  private.r_ops(),
  private.r_finance(),
  private.r_owner(),
  private.fail(text, text, text),
  private.business_details(uuid)
to authenticated;

alter default privileges in schema private revoke execute on functions from public;
