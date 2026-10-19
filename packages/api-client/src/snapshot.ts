import { AppError } from './errors';
import type { AuthAdapter, AuthSession, RpcTransport } from './transport';

/**
 * Read-only demo backend for environments that cannot run PGlite (React
 * Native). The snapshot is recorded by scripts/build-demo-snapshot.ts from the
 * same seeded demo database the web apps use. Every write is refused with a
 * clear message — no fake success is ever returned.
 */
export interface DemoSnapshot {
  generated_at: string;
  today: string;
  user_id: string;
  email: string;
  calls: { fn: string; args: Record<string, unknown>; result: unknown }[];
}

const READ_FUNCTIONS = new Set([
  'my_context',
  'get_workspace',
  'list_plans',
  'list_properties',
  'get_property',
  'list_rooms',
  'list_residents',
  'get_resident',
  'list_invoices',
  'get_invoice',
  'list_payments',
  'get_payment',
  'list_deposits',
  'list_expenses',
  'list_charge_templates',
  'dashboard_summary',
  'financial_report',
  'list_members',
  'list_audit_logs',
  'am_i_platform_admin',
]);

type Row = Record<string, unknown>;
type Params = Record<string, unknown>;

function same(a: unknown, b: unknown): boolean {
  return JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
}

function text(...values: unknown[]): string {
  return values.filter((v) => typeof v === 'string').join(' ').toLowerCase();
}

function page<T>(rows: T[], params: Params) {
  const offset = Number(params.offset ?? 0);
  const limit = Number(params.limit ?? 50);
  return rows.slice(offset, offset + limit);
}

export function createSnapshotTransport(snapshot: DemoSnapshot): RpcTransport {
  const byFn = new Map<string, DemoSnapshot['calls']>();
  for (const c of snapshot.calls) byFn.set(c.fn, [...(byFn.get(c.fn) ?? []), c]);

  const exact = (fn: string, args: Record<string, unknown>) => byFn.get(fn)?.find((c) => same(c.args, args))?.result;
  const firstWhere = (fn: string, pred: (args: Record<string, unknown>) => boolean) => byFn.get(fn)?.find((c) => pred(c.args))?.result;

  return {
    kind: 'snapshot',
    async call<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
      if (!READ_FUNCTIONS.has(fn)) {
        throw new AppError('demo_read_only', 'The mobile demo is read-only. Connect a Supabase project (see README) to add or change records.');
      }
      const hit = exact(fn, args);
      if (hit !== undefined) return hit as T;
      const params = (args.p_params ?? {}) as Params;

      switch (fn) {
        case 'list_residents': {
          const base = firstWhere(fn, (a) => (a.p_params as Params)?.status === (params.status ?? 'current')) as { rows: Row[] } | undefined;
          if (!base) break;
          const q = String(params.search ?? '').toLowerCase();
          const rows = base.rows.filter(
            (r) =>
              (!q || text(r.full_name, r.phone, r.email).includes(q)) &&
              (!params.property_id || (r.stay as Row | null)?.property_id === params.property_id),
          );
          return { total: rows.length, rows: page(rows, params) } as T;
        }
        case 'list_payments': {
          const base = firstWhere(fn, (a) => (a.p_params as Params)?.status === (params.status ?? 'live')) as { rows: Row[] } | undefined;
          if (!base) break;
          const q = String(params.search ?? '').toLowerCase();
          const rows = base.rows.filter(
            (r) =>
              (!params.resident_id || r.resident_id === params.resident_id) &&
              (!params.property_id || r.property_id === params.property_id) &&
              (!params.method || r.method === params.method) &&
              (!params.from || String(r.paid_on) >= String(params.from)) &&
              (!params.to || String(r.paid_on) <= String(params.to)) &&
              (!q || text(r.resident_name, r.receipt_number, r.reference).includes(q)),
          );
          const amount = rows.filter((r) => r.status === 'recorded' || r.status === 'succeeded').reduce((n, r) => n + Number(r.amount_paise), 0);
          return { total: rows.length, totals: { amount_paise: amount }, rows: page(rows, params) } as T;
        }
        case 'list_invoices': {
          const base = firstWhere(fn, () => true) as { rows: Row[] } | undefined;
          if (!base) break;
          const status = String(params.status ?? 'all');
          const q = String(params.search ?? '').toLowerCase();
          const month = params.month ? String(params.month).slice(0, 7) : null;
          const rows = base.rows.filter(
            (r) =>
              (status === 'all' || (status === 'open' ? ['pending', 'partially_paid', 'overdue'].includes(String(r.payment_status)) : r.payment_status === status)) &&
              (!params.resident_id || r.resident_id === params.resident_id) &&
              (!params.property_id || r.property_id === params.property_id) &&
              (!month || String(r.due_date).startsWith(month)) &&
              (!q || text(r.resident_name, r.invoice_number).includes(q)),
          );
          const issued = rows.filter((r) => r.status === 'issued');
          const sum = (k: string) => issued.reduce((n, r) => n + Number(r[k]), 0);
          return { total: rows.length, totals: { total_paise: sum('total_paise'), paid_paise: sum('paid_paise'), balance_paise: sum('balance_paise') }, rows: page(rows, params) } as T;
        }
        case 'list_expenses': {
          const base = firstWhere(fn, () => true) as { rows: Row[] } | undefined;
          if (!base) break;
          const rows = base.rows.filter(
            (r) =>
              (!params.property_id || r.property_id === params.property_id) &&
              (!params.from || String(r.expense_date) >= String(params.from)) &&
              (!params.to || String(r.expense_date) <= String(params.to)) &&
              (!params.category || r.category === params.category),
          );
          const byCat = new Map<string, number>();
          for (const r of rows) byCat.set(String(r.category), (byCat.get(String(r.category)) ?? 0) + Number(r.amount_paise));
          return {
            total: rows.length,
            totals: { amount_paise: rows.reduce((n, r) => n + Number(r.amount_paise), 0) },
            by_category: [...byCat].map(([category, amount_paise]) => ({ category, amount_paise })).sort((a, b) => b.amount_paise - a.amount_paise),
            rows: page(rows, params),
          } as T;
        }
        case 'dashboard_summary': {
          const r = firstWhere(fn, (a) => same(a.p_property_id, args.p_property_id));
          if (r !== undefined) return r as T;
          break;
        }
        case 'list_rooms': {
          const all = firstWhere(fn, (a) => a.p_property_id === null) as Row[] | undefined;
          if (all) return all.filter((r) => !args.p_property_id || r.property_id === args.p_property_id) as T;
          break;
        }
        default:
          break;
      }
      throw new AppError('not_supported', 'This view isn’t included in the offline demo snapshot.');
    },
  };
}

/** Auth for the read-only demo: a single sample owner, no network. */
export function createSnapshotAuth(snapshot: DemoSnapshot, persisted: { load(): Promise<boolean>; save(signedIn: boolean): Promise<void> }): AuthAdapter {
  const session: AuthSession = { userId: snapshot.user_id, email: snapshot.email, emailConfirmed: true };
  let current: AuthSession | null = null;
  const listeners = new Set<(s: AuthSession | null) => void>();
  const set = (s: AuthSession | null) => {
    current = s;
    void persisted.save(Boolean(s));
    for (const l of listeners) l(s);
  };
  const readOnly = () => {
    throw new AppError('demo_read_only', 'Creating accounts needs a Supabase project. In the demo, open the sample workspace instead.');
  };
  return {
    kind: 'snapshot',
    async getSession() {
      if (!current && (await persisted.load())) current = session;
      return current;
    },
    onChange(l) {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    async signUp() {
      return readOnly();
    },
    async signIn() {
      set(session);
      return session;
    },
    async sendEmailOtp() {
      readOnly();
    },
    async verifyEmailOtp() {
      return readOnly();
    },
    async resendVerification() {},
    async requestPasswordReset() {
      readOnly();
    },
    async updatePassword() {
      readOnly();
    },
    async signOut() {
      set(null);
    },
  };
}
