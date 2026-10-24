-- =============================================================================
-- Sales-led onboarding.
--
-- The marketing website no longer lets anyone sign up. Owners fill in a "Book a
-- demo" form (submit_lead, callable without an account); the request appears in
-- Super admin → Leads. After the owner has paid, the platform admin invites them
-- (Tenants → Invite owner, prefilled from the lead), and only invited owners can
-- create a business once sign-ups are switched to invite-only in
-- Super admin → Platform settings.
-- =============================================================================

create type public.lead_status as enum ('new', 'contacted', 'invited', 'won', 'lost');

create table public.leads (
  id uuid primary key default gen_random_uuid(),
  business_name text not null check (char_length(business_name) between 2 and 120),
  owner_name text not null check (char_length(owner_name) between 2 and 120),
  phone text not null check (char_length(phone) between 6 and 20),
  email text check (char_length(email) <= 254),
  city text check (char_length(city) <= 80),
  beds text check (char_length(beds) <= 40),
  message text check (char_length(message) <= 1000),
  status public.lead_status not null default 'new',
  admin_note text check (char_length(admin_note) <= 1000),
  invite_id uuid references public.owner_invites (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index leads_created_idx on public.leads (created_at desc);
create index leads_phone_idx on public.leads (phone, created_at desc);

alter table public.leads enable row level security;
-- No policies: only the functions below can read or write leads.
revoke all on public.leads from anon, authenticated;

/** Public "Book a demo" form on the marketing website. */
create or replace function public.submit_lead(p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_business text := private.clean_text(p_data ->> 'business_name');
  v_owner text := private.clean_text(p_data ->> 'owner_name');
  v_phone text := private.check_phone(p_data ->> 'phone');
  v_existing uuid;
begin
  if v_business is null or char_length(v_business) < 2 then
    perform private.fail('Enter your PG’s name.');
  end if;
  if v_owner is null or char_length(v_owner) < 2 then
    perform private.fail('Enter your name.');
  end if;
  if v_phone is null then
    perform private.fail('Enter your phone number so we can call you.');
  end if;
  -- Simple abuse limit for a public form.
  if (select count(*) from public.leads l where l.created_at > now() - interval '10 minutes') >= 30 then
    perform private.fail('Too many requests right now. Please try again in a few minutes.', 'rate_limited');
  end if;

  -- The same phone again within a week updates the open request.
  select l.id into v_existing from public.leads l
   where l.phone = v_phone and l.status in ('new', 'contacted') and l.created_at > now() - interval '7 days'
   order by l.created_at desc limit 1;
  if v_existing is null then
    insert into public.leads (business_name, owner_name, phone, email, city, beds, message)
    values (
      left(v_business, 120), left(v_owner, 120), v_phone,
      private.check_email(p_data ->> 'email'),
      left(private.clean_text(p_data ->> 'city'), 80),
      left(private.clean_text(p_data ->> 'beds'), 40),
      left(private.clean_text(p_data ->> 'message'), 1000)
    );
  else
    update public.leads l set
      business_name = left(v_business, 120), owner_name = left(v_owner, 120),
      email = coalesce(private.check_email(p_data ->> 'email'), l.email),
      city = coalesce(left(private.clean_text(p_data ->> 'city'), 80), l.city),
      beds = coalesce(left(private.clean_text(p_data ->> 'beds'), 40), l.beds),
      message = coalesce(left(private.clean_text(p_data ->> 'message'), 1000), l.message),
      updated_at = now()
    where l.id = v_existing;
  end if;
  return jsonb_build_object('ok', true);
exception
  when check_violation then
    perform private.fail('Some details are too long. Please shorten them and try again.');
end;
$$;

create or replace function public.admin_list_leads(p_status text default 'open')
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
      'id', l.id, 'business_name', l.business_name, 'owner_name', l.owner_name, 'phone', l.phone,
      'email', l.email, 'city', l.city, 'beds', l.beds, 'message', l.message, 'status', l.status,
      'admin_note', l.admin_note, 'invite_id', l.invite_id, 'created_at', l.created_at, 'updated_at', l.updated_at
    ) order by l.created_at desc)
    from public.leads l
    where p_status = 'all'
       or (p_status = 'open' and l.status in ('new', 'contacted'))
       or l.status::text = p_status), '[]'::jsonb);
end;
$$;

create or replace function public.admin_update_lead(p_lead_id uuid, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_platform_admin();
  update public.leads l set
    status = case when p_data ? 'status' then (p_data ->> 'status')::public.lead_status else l.status end,
    admin_note = case when p_data ? 'admin_note' then left(private.clean_text(p_data ->> 'admin_note'), 1000) else l.admin_note end,
    invite_id = case when p_data ? 'invite_id' then nullif(p_data ->> 'invite_id', '')::uuid else l.invite_id end,
    updated_at = now()
  where l.id = p_lead_id;
  if not found then
    perform private.fail('Lead not found', 'not_found', 'P0002');
  end if;
  perform private.audit(null, 'admin.lead_updated', 'lead', p_lead_id, p_data - 'admin_note');
exception
  when invalid_text_representation then
    perform private.fail('Unknown lead status');
end;
$$;

revoke execute on function public.submit_lead(jsonb), public.admin_list_leads(text), public.admin_update_lead(uuid, jsonb) from public;
grant execute on function public.submit_lead(jsonb) to anon, authenticated;
grant execute on function public.admin_list_leads(text), public.admin_update_lead(uuid, jsonb) to authenticated;
