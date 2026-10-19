# Pg Sathi Super Admin

The platform operator console for Pg Sathi. It covers every business that has
signed up, their plans and usage, suspending or reactivating a business (with
a required, audited reason), the plan editor, the platform audit log and
sign-up settings.

It deliberately shows totals only. Resident details, bills and payments stay
private to each business.

Built with React 19, Vite, TypeScript, Tailwind CSS, Radix UI, TanStack Query
and Supabase.

## Run it

Requires Node 20.19 or newer.

```bash
npm install
npm run dev        # http://localhost:5174
```

Without Supabase settings it runs in **demo mode** with fictional businesses
in an in-browser database. Sign in with `admin@demo.pgsaas.local` /
`demo-admin-2026`.

## Connect Supabase

Use the **same Supabase project** as the Pg Sathi owner dashboard.

1. Apply `supabase/migrations` in order and run `supabase/seed.sql`, if not
   already done for the owner dashboard.
2. Copy `.env.example` to `.env`:

   ```bash
   VITE_SUPABASE_URL=https://<project-ref>.supabase.co
   VITE_SUPABASE_ANON_KEY=<publishable/anon key>
   ```

3. Grant yourself access. This is only possible with SQL, never through the
   app. Run it in the Supabase SQL editor:

   ```sql
   insert into public.platform_admins (user_id, note)
   select id, 'Founder' from auth.users where email = 'you@example.com';
   ```

   Any other account that signs in sees "No platform access".

## Build

```bash
npm run build      # type-check and production build into dist/
```

## Layout

| Path | Contents |
| --- | --- |
| `src/` | The admin console (`src/pages/*`) |
| `packages/` | Shared code: types, validation, API client, UI kit, design tokens, demo database |
| `supabase/` | Database migrations and the plans seed (identical to the owner dashboard's) |
