import { StrictMode, useEffect, useState, type ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter, Navigate, NavLink, Outlet, Route, Routes } from 'react-router';
import { QueryClient, QueryClientProvider, useQuery, useQueryClient } from '@tanstack/react-query';
import { Toaster } from 'sonner';
import { Activity, Building2, FlaskConical, Gauge, Layers, LogOut, Settings2, ShieldAlert, ShieldCheck } from 'lucide-react';
import { AppError, type AuthSession } from '@pg/api-client';
import { BackendProvider, useBackend } from '@pg/api-client/react';
import { Button } from '@pg/ui-web/ui/button';
import { Input } from '@pg/ui-web/ui/form-controls';
import { TooltipProvider } from '@pg/ui-web/ui/overlays';
import { EmptyState, Field, InlineError } from '@pg/ui-web/common';
import { cn } from '@pg/ui-web/utils';
import '@fontsource-variable/inter';
import './index.css';
import { bootBackend, type BootResult } from './backend';
import { OverviewPage } from './pages/overview';
import { TenantDetailPage, TenantsPage } from './pages/tenants';
import { PlansPage } from './pages/plans';
import { AuditPage, PlatformSettingsPage } from './pages/audit-settings';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: (count, error) => !(error instanceof AppError && error.code !== 'network' && error.code !== 'unknown') && count < 2,
    },
  },
});

function Mark() {
  return (
    <span className="flex size-8 items-center justify-center rounded-lg bg-navy-900 text-white">
      <ShieldCheck className="size-4" aria-hidden />
    </span>
  );
}

function Splash({ message }: { message: string }) {
  return (
    <div className="flex min-h-dvh flex-col items-center justify-center gap-3 text-[13px] text-gray-500" role="status">
      <Mark />
      {message}
    </div>
  );
}

function useSession() {
  const { auth } = useBackend();
  const client = useQueryClient();
  const [session, setSession] = useState<AuthSession | null | undefined>(undefined);
  useEffect(() => {
    void auth.getSession().then(setSession, () => setSession(null));
    return auth.onChange((s) => {
      client.clear();
      setSession(s);
    });
  }, [auth, client]);
  return session;
}

function SignIn() {
  const { auth, demo } = useBackend();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  const submit = async (e?: { preventDefault(): void }, creds?: { email: string; password: string }) => {
    e?.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await auth.signIn(creds ?? { email, password });
    } catch (err) {
      setError(err);
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="flex min-h-dvh items-center justify-center bg-navy-950 p-6">
      <div className="w-full max-w-sm rounded-xl bg-white p-8 shadow-lg">
        <div className="flex items-center gap-2.5">
          <Mark />
          <span className="text-[15px] font-semibold text-gray-900">Staywise Admin</span>
        </div>
        <h1 className="mt-8 text-xl font-semibold text-gray-900">Platform operator sign-in</h1>
        <p className="mt-1 text-[13px] text-gray-500">Access is limited to accounts granted platform-admin rights by an operator.</p>
        {demo?.sampleAccount && (
          <Button variant="secondary" className="mt-6 w-full" onClick={() => void submit(undefined, demo.sampleAccount)}>
            <FlaskConical /> Use the demo operator account
          </Button>
        )}
        <form className="mt-6 space-y-4" onSubmit={(e) => void submit(e)}>
          <Field label="Email" htmlFor="a-email">
            <Input id="a-email" type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} />
          </Field>
          <Field label="Password" htmlFor="a-pass">
            <Input id="a-pass" type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
          </Field>
          <InlineError error={error} />
          <Button type="submit" className="w-full" loading={busy}>
            Sign in
          </Button>
        </form>
      </div>
    </div>
  );
}

const NAV = [
  { to: '/', label: 'Overview', icon: Gauge, end: true },
  { to: '/tenants', label: 'Tenants', icon: Building2 },
  { to: '/plans', label: 'Plans', icon: Layers },
  { to: '/audit', label: 'Audit log', icon: Activity },
  { to: '/settings', label: 'Platform settings', icon: Settings2 },
];

function Shell({ email, children }: { email: string | null; children: ReactNode }) {
  const { auth, mode, demo } = useBackend();
  return (
    <div className="flex min-h-dvh flex-col">
      {mode !== 'supabase' && (
        <div className="flex items-center justify-center gap-2 bg-accent-700 px-4 py-1.5 text-xs text-white">
          <FlaskConical className="size-3.5" aria-hidden /> Demo mode — fictional data in this browser only.
          {demo?.reset && (
            <button className="underline" onClick={() => void demo.reset?.()}>
              Reset
            </button>
          )}
        </div>
      )}
      <div className="flex flex-1 flex-col lg:flex-row">
        <aside className="flex shrink-0 flex-col bg-navy-950 text-white lg:sticky lg:top-0 lg:h-dvh lg:w-60">
          <div className="flex h-14 items-center gap-2.5 px-5">
            <Mark />
            <span className="text-[15px] font-semibold">Staywise Admin</span>
          </div>
          <nav className="flex gap-1 overflow-x-auto px-3 pb-3 lg:flex-1 lg:flex-col lg:pb-0 lg:pt-4" aria-label="Main">
            {NAV.map((n) => (
              <NavLink
                key={n.to}
                to={n.to}
                end={n.end}
                className={({ isActive }) => cn('flex h-9 shrink-0 items-center gap-2.5 rounded-md px-3 text-[13px] font-medium text-white/70 hover:bg-white/10 hover:text-white', isActive && 'bg-white/10 text-white')}
              >
                <n.icon className="size-4" aria-hidden /> {n.label}
              </NavLink>
            ))}
          </nav>
          <div className="hidden border-t border-white/10 p-4 lg:block">
            <p className="truncate text-xs text-white/60">{email}</p>
            <button onClick={() => void auth.signOut()} className="mt-2 inline-flex items-center gap-1.5 text-xs text-white/80 hover:text-white">
              <LogOut className="size-3.5" /> Sign out
            </button>
          </div>
        </aside>
        <main className="mx-auto w-full max-w-[1300px] flex-1 px-4 py-6 sm:px-8">{children}</main>
      </div>
    </div>
  );
}

function AdminGate({ session }: { session: AuthSession }) {
  const { admin, auth } = useBackend();
  // The server decides; this is the same check every admin function performs.
  const check = useQuery({ queryKey: ['admin', 'me', session.userId], queryFn: () => admin.amIPlatformAdmin() });
  if (check.isPending) return <Splash message="Checking access…" />;
  if (!check.data) {
    return (
      <div className="flex min-h-dvh items-center justify-center">
        <EmptyState
          icon={ShieldAlert}
          title="No platform access"
          description={`${session.email ?? 'This account'} is not a platform administrator. Owner accounts use the owner dashboard.`}
          action={<Button variant="secondary" onClick={() => void auth.signOut()}>Sign out</Button>}
        />
      </div>
    );
  }
  return (
    <Shell email={session.email}>
      <Outlet />
    </Shell>
  );
}

function App() {
  const session = useSession();
  if (session === undefined) return <Splash message="Loading…" />;
  if (!session) return <SignIn />;
  return (
    <Routes>
      <Route element={<AdminGate session={session} />}>
        <Route index element={<OverviewPage />} />
        <Route path="tenants" element={<TenantsPage />} />
        <Route path="tenants/:tenantId" element={<TenantDetailPage />} />
        <Route path="plans" element={<PlansPage />} />
        <Route path="audit" element={<AuditPage />} />
        <Route path="settings" element={<PlatformSettingsPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

function Root() {
  const [boot, setBoot] = useState<BootResult | null>(null);
  const [progress, setProgress] = useState('Starting…');
  useEffect(() => void bootBackend(setProgress).then(setBoot), []);
  if (!boot) return <Splash message={progress} />;
  if (!boot.ok) return <Splash message={boot.message} />;
  return (
    <BackendProvider backend={boot.backend}>
      <QueryClientProvider client={queryClient}>
        <TooltipProvider>
          <BrowserRouter>
            <App />
          </BrowserRouter>
          <Toaster position="bottom-right" richColors closeButton />
        </TooltipProvider>
      </QueryClientProvider>
    </BackendProvider>
  );
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Root />
  </StrictMode>,
);
