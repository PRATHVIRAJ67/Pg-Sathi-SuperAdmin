-- =============================================================================
-- Platform configuration seed. Safe for production: it creates the initial
-- subscription plans (editable later from the super-admin dashboard) and sets
-- the default plan for new sign-ups. It creates NO tenants, residents or
-- financial records — those only ever come from real users.
-- =============================================================================
insert into public.plans (code, name, description, price_paise, billing_interval, max_properties, max_residents, max_staff, features, trial_days, sort_order)
values
  ('starter', 'Starter', 'For a single PG getting organised.', 0, 'month', 1, 30, 1,
    array['Rent tracking', 'Manual payments', 'Receipts', 'Expenses'], 0, 10),
  ('growth', 'Growth', 'For growing PGs with a small team.', 99900, 'month', 3, 150, 5,
    array['Everything in Starter', 'Multiple properties', 'Team roles', 'Reports export'], 14, 20),
  ('scale', 'Scale', 'For operators running many properties.', 249900, 'month', null, null, null,
    array['Everything in Growth', 'Unlimited properties', 'Unlimited residents', 'Priority support'], 14, 30)
on conflict (code) do nothing;

update public.platform_settings
   set default_plan_id = (select id from public.plans where code = 'starter')
 where id and default_plan_id is null;
