-- =============================================================================
-- Owner invitations from the super-admin console.
--
-- A platform admin invites an owner by email (optionally with business name and
-- plan) and shares the sign-up link. When that person signs up with the same
-- email and creates their workspace, the invite is marked accepted and its plan
-- is used. With "Allow new sign-ups" turned off in Platform settings, only
-- invited emails can create a workspace (invite-only mode).
-- =============================================================================

create type public.owner_invite_status as enum ('pending', 'accepted', 'revoked');

create table public.owner_invites (
  id uuid primary key default gen_random_uuid(),
  email text not null check (char_length(email) between 3 and 254),
  business_name text check (char_length(business_name) between 2 and 120),
  owner_name text check (char_length(owner_name) <= 120),
  phone text check (char_length(phone) <= 20),
  plan_id uuid references public.plans (id) on delete set null,
  note text check (char_length(note) <= 500),
  status public.owner_invite_status not null default 'pending',
  tenant_id uuid references public.tenants (id) on delete set null,
  invited_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  accepted_at timestamptz,
  revoked_at timestamptz
);
-- One pending invite per email.
create unique index owner_invites_pending_email_idx on public.owner_invites (lower(email)) where status = 'pending';
create index owner_invites_created_idx on public.owner_invites (created_at desc);

alter table public.owner_invites enable row level security;
-- No policies: only the functions below (platform admins, or the invitee
-- reading their own) can see invites.
revoke all on public.owner_invites from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Super admin
-- ---------------------------------------------------------------------------
create or replace function public.admin_invite_owner(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(private.check_email(p_data ->> 'email'));
  v_plan uuid := nullif(p_data ->> 'plan_id', '')::uuid;
  v_id uuid;
begin
  perform private.require_platform_admin();
  if v_email is null then
    perform private.fail('Enter the owner’s email address.');
  end if;
  if v_plan is not null and not exists (select 1 from public.plans p where p.id = v_plan and p.is_active) then
    perform private.fail('Choose an active plan.', 'not_found', 'P0002');
  end if;
  if exists (
    select 1 from public.tenants t join auth.users u on u.id = t.created_by
     where lower(u.email) = v_email and t.status not in ('cancelled')
  ) and not coalesce((p_data ->> 'allow_existing')::boolean, false) then
    perform private.fail('This email already has a business on PG Sathi.', 'duplicate');
  end if;

  select i.id into v_id from public.owner_invites i where lower(i.email) = v_email and i.status = 'pending';
  if v_id is null then
    insert into public.owner_invites (email, business_name, owner_name, phone, plan_id, note, invited_by)
    values (
      v_email,
      left(private.clean_text(p_data ->> 'business_name'), 120),
      left(private.clean_text(p_data ->> 'owner_name'), 120),
      private.check_phone(p_data ->> 'phone'),
      v_plan,
      left(private.clean_text(p_data ->> 'note'), 500),
      auth.uid()
    )
    returning id into v_id;
  else
    -- Inviting the same email again refreshes the pending invite.
    update public.owner_invites i set
      business_name = left(private.clean_text(p_data ->> 'business_name'), 120),
      owner_name = left(private.clean_text(p_data ->> 'owner_name'), 120),
      phone = private.check_phone(p_data ->> 'phone'),
      plan_id = v_plan,
      note = left(private.clean_text(p_data ->> 'note'), 500),
      invited_by = auth.uid(),
      updated_at = now()
    where i.id = v_id;
  end if;
  perform private.audit(null, 'admin.owner_invited', 'owner_invite', v_id, jsonb_build_object('email', v_email, 'plan_id', v_plan));
  return jsonb_build_object('id', v_id, 'email', v_email);
exception
  when check_violation then
    perform private.fail('Some details are too long. Business name must be 2 to 120 characters.');
  when invalid_text_representation then
    perform private.fail('Plan not found', 'not_found', 'P0002');
end;
$$;

create or replace function public.admin_list_owner_invites(p_status text default 'all')
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', i.id, 'email', i.email, 'business_name', i.business_name, 'owner_name', i.owner_name,
      'phone', i.phone, 'note', i.note, 'status', i.status,
      'plan_id', i.plan_id, 'plan_name', p.name,
      'tenant_id', i.tenant_id, 'tenant_name', t.name,
      'created_at', i.created_at, 'accepted_at', i.accepted_at, 'revoked_at', i.revoked_at,
      -- Has this person created a login yet (but maybe not a workspace)?
      'has_account', exists (select 1 from auth.users u where lower(u.email) = lower(i.email))
    ) order by i.created_at desc)
    from public.owner_invites i
    left join public.plans p on p.id = i.plan_id
    left join public.tenants t on t.id = i.tenant_id
    where p_status = 'all' or i.status::text = p_status), '[]'::jsonb);
end;
$$;

create or replace function public.admin_revoke_owner_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_admin();
  update public.owner_invites i set status = 'revoked', revoked_at = now(), updated_at = now()
   where i.id = p_invite_id and i.status = 'pending';
  if not found then
    perform private.fail('Only pending invitations can be cancelled.');
  end if;
  perform private.audit(null, 'admin.owner_invite_revoked', 'owner_invite', p_invite_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Owner sign-up and onboarding
-- ---------------------------------------------------------------------------

/** Public: is sign-up open, or invite-only? (The sign-up page shows a notice.) */
create or replace function public.signup_status()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('open', coalesce((select s.signup_enabled from public.platform_settings s where s.id), false));
$$;

/** The signed-in person's pending invite, to prefill onboarding. */
create or replace function public.my_owner_invite()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_email text;
begin
  perform private.require_auth();
  select lower(u.email) into v_email from auth.users u where u.id = auth.uid();
  return (
    select jsonb_build_object('business_name', i.business_name, 'owner_name', i.owner_name, 'phone', i.phone, 'plan_name', p.name)
      from public.owner_invites i left join public.plans p on p.id = i.plan_id
     where lower(i.email) = v_email and i.status = 'pending'
     limit 1
  );
end;
$$;

/** Same as before, plus: invite-only mode, and the invite's plan is used. */
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
  v_email text;
  v_email_confirmed timestamptz;
  v_phone_confirmed timestamptz;
  v_tenant_id uuid;
  v_settings public.platform_settings;
  v_plan public.plans;
  v_invite public.owner_invites;
  v_name text := private.clean_text(p_business_name);
begin
  if p_request_id is null then
    perform private.fail('A provisioning request id is required');
  end if;

  select lower(u.email), u.email_confirmed_at, u.phone_confirmed_at
    into v_email, v_email_confirmed, v_phone_confirmed
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
  select * into v_invite from public.owner_invites i
   where lower(i.email) = v_email and i.status = 'pending'
   order by i.created_at desc limit 1
   for update;
  if not coalesce(v_settings.signup_enabled, false) and v_invite.id is null then
    perform private.fail('PG Sathi is invite-only right now. Ask us for an invitation to create your business.', 'signup_disabled', '42501');
  end if;

  v_name := coalesce(v_name, v_invite.business_name);
  if v_name is null or char_length(v_name) < 2 or char_length(v_name) > 120 then
    perform private.fail('Business name must be between 2 and 120 characters');
  end if;

  if (select count(*) from public.tenants t where t.created_by = v_uid) >= 5 then
    perform private.fail('You have reached the maximum number of workspaces for one account', 'workspace_limit');
  end if;

  -- The invite's plan if it has one, else the platform default, else the first public plan.
  if v_invite.plan_id is not null then
    select * into v_plan from public.plans p where p.id = v_invite.plan_id and p.is_active;
  end if;
  if v_plan.id is null then
    select * into v_plan from public.plans p where p.id = v_settings.default_plan_id and p.is_active;
  end if;
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
    left(coalesce(private.clean_text(p_owner_name), v_invite.owner_name), 120),
    private.check_phone(coalesce(p_contact_phone, v_invite.phone)),
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

  if v_invite.id is not null then
    update public.owner_invites i set status = 'accepted', tenant_id = v_tenant_id, accepted_at = now(), updated_at = now()
     where i.id = v_invite.id;
  end if;

  perform private.audit(v_tenant_id, 'workspace.provisioned', 'tenant', v_tenant_id,
    jsonb_build_object('plan', v_plan.code, 'invited', v_invite.id is not null));
  return v_tenant_id;
end;
$$;

revoke execute on function public.admin_invite_owner(jsonb), public.admin_list_owner_invites(text),
  public.admin_revoke_owner_invite(uuid), public.my_owner_invite(), public.signup_status() from public, anon;
grant execute on function public.admin_invite_owner(jsonb), public.admin_list_owner_invites(text),
  public.admin_revoke_owner_invite(uuid), public.my_owner_invite(), public.signup_status() to authenticated;
grant execute on function public.signup_status() to anon;
