import { PGlite } from '@electric-sql/pglite';
import { AppError, toAppError, type AuthAdapter, type AuthSession, type RpcTransport } from '@pg/api-client';
import { SUPABASE_SHIM_SQL } from './shim';

export interface SqlFile {
  name: string;
  sql: string;
}

export interface OpenDatabaseOptions {
  migrations: SqlFile[];
  seeds?: SqlFile[];
  /** e.g. "idb://pg-saas-demo" in browsers; omit for in-memory. */
  dataDir?: string;
}

/** Opens PGlite and applies the shim, migrations and seeds that have not been applied yet. */
export async function openDatabase(options: OpenDatabaseOptions): Promise<PGlite> {
  const db = options.dataDir ? new PGlite(options.dataDir) : new PGlite();
  await db.waitReady;
  await db.exec(SUPABASE_SHIM_SQL);
  const applied = new Set(
    (await db.query<{ name: string }>('select name from demo_meta.applied')).rows.map((r) => r.name),
  );
  const files = [...options.migrations].sort((a, b) => a.name.localeCompare(b.name));
  for (const file of [...files, ...(options.seeds ?? [])]) {
    if (applied.has(file.name)) continue;
    try {
      await db.exec(file.sql);
    } catch (error) {
      const e = error as Error;
      throw new Error(`Failed to apply ${file.name}: ${e.message}`);
    }
    await db.query('insert into demo_meta.applied (name) values ($1)', [file.name]);
  }
  return db;
}

const FN_NAME = /^[a-z_][a-z0-9_]*$/;

function serialize(value: unknown): unknown {
  if (value === undefined || value === null) return null;
  if (typeof value === 'object' && !(value instanceof Date)) return JSON.stringify(value);
  return value;
}

/**
 * Calls database functions exactly like PostgREST: one transaction per call,
 * role switched to authenticated (or anon) and JWT claims set for auth.uid().
 */
export function createPgliteTransport(db: PGlite, getUserId: () => string | null): RpcTransport {
  return {
    kind: 'pglite',
    async call<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
      if (!FN_NAME.test(fn)) throw new AppError('validation', `Invalid function name: ${fn}`);
      const keys = Object.keys(args).filter((k) => args[k] !== undefined);
      for (const k of keys) if (!FN_NAME.test(k)) throw new AppError('validation', `Invalid argument name: ${k}`);
      const params = keys.map((k) => serialize(args[k]));
      const sql = `select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as result`;
      const userId = getUserId();
      try {
        return await db.transaction(async (tx) => {
          await tx.query("select set_config('role', $1, true), set_config('request.jwt.claims', $2, true)", [
            userId ? 'authenticated' : 'anon',
            JSON.stringify(userId ? { sub: userId, role: 'authenticated' } : { role: 'anon' }),
          ]);
          const result = await tx.query<{ result: T }>(sql, params);
          return (result.rows[0]?.result ?? null) as T;
        });
      } catch (error) {
        throw toAppError(error);
      }
    },
  };
}

export interface KeyValueStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

export function memoryStorage(): KeyValueStorage {
  const map = new Map<string, string>();
  return {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => void map.set(k, v),
    removeItem: (k) => void map.delete(k),
  };
}

const SESSION_KEY = 'pg-saas-demo-session';

export interface DemoAuth extends AuthAdapter {
  currentUserId(): string | null;
  /** Test/demo helper: creates a confirmed (or unconfirmed) user and returns its id. */
  createUser(input: { email: string; password: string; fullName?: string; confirmed?: boolean }): Promise<string>;
  /** Switches the active session without a password (tests and the demo account switcher). */
  impersonate(userId: string | null): void;
}

/**
 * Demo-mode authentication backed by auth.users inside PGlite. Email
 * verification is simulated (accounts are confirmed immediately) and this is
 * labelled as such in the UI. Passwords are hashed, but this is not a
 * production auth system — production uses Supabase Auth.
 */
export function createDemoAuth(db: PGlite, storage: KeyValueStorage = memoryStorage()): DemoAuth {
  let current: AuthSession | null = null;
  const listeners = new Set<(s: AuthSession | null) => void>();

  const raw = storage.getItem(SESSION_KEY);
  if (raw) {
    try {
      current = JSON.parse(raw) as AuthSession;
    } catch {
      storage.removeItem(SESSION_KEY);
    }
  }

  function setSession(session: AuthSession | null) {
    current = session;
    if (session) storage.setItem(SESSION_KEY, JSON.stringify(session));
    else storage.removeItem(SESSION_KEY);
    for (const l of listeners) l(session);
  }

  async function createUser(input: { email: string; password: string; fullName?: string; confirmed?: boolean }) {
    const email = input.email.trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new AppError('validation', 'Enter a valid email address.');
    if (input.password.length < 8) throw new AppError('validation', 'Password must be at least 8 characters.');
    const exists = await db.query('select 1 from auth.users where email = $1', [email]);
    if (exists.rows.length) throw new AppError('duplicate', 'An account with this email already exists. Sign in instead.');
    const res = await db.query<{ id: string }>(
      `insert into auth.users (email, encrypted_password, email_confirmed_at, confirmed_at, raw_user_meta_data)
       values ($1, encode(sha256(convert_to($1 || ':' || $2, 'UTF8')), 'hex'),
               case when $3 then now() end, case when $3 then now() end, $4::jsonb)
       returning id`,
      [email, input.password, input.confirmed ?? true, JSON.stringify(input.fullName ? { full_name: input.fullName } : {})],
    );
    return res.rows[0]!.id;
  }

  async function sessionFor(userId: string): Promise<AuthSession> {
    const res = await db.query<{ email: string; email_confirmed_at: string | null }>(
      'select email, email_confirmed_at from auth.users where id = $1',
      [userId],
    );
    const row = res.rows[0];
    if (!row) throw new AppError('not_authenticated', 'Account not found.');
    return { userId, email: row.email, emailConfirmed: Boolean(row.email_confirmed_at) };
  }

  return {
    kind: 'pglite',
    currentUserId: () => current?.userId ?? null,
    createUser,
    impersonate(userId) {
      if (!userId) return setSession(null);
      void sessionFor(userId).then(setSession);
    },
    async getSession() {
      if (!current) return null;
      // Drop sessions for users that no longer exist (e.g. after a demo reset).
      const res = await db.query('select 1 from auth.users where id = $1', [current.userId]);
      if (!res.rows.length) {
        setSession(null);
        return null;
      }
      return current;
    },
    onChange(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    async signUp({ email, password, fullName }) {
      const userId = await createUser({ email, password, fullName, confirmed: true });
      const session = await sessionFor(userId);
      setSession(session);
      return { session, needsVerification: false };
    },
    async signIn({ email, password }) {
      const res = await db.query<{ id: string }>(
        `select id from auth.users
          where email = lower($1) and encrypted_password = encode(sha256(convert_to(lower($1) || ':' || $2, 'UTF8')), 'hex')`,
        [email.trim(), password],
      );
      const id = res.rows[0]?.id;
      if (!id) throw new AppError('not_authenticated', 'Incorrect email or password.');
      const session = await sessionFor(id);
      setSession(session);
      return session;
    },
    async sendEmailOtp() {
      throw new AppError('not_supported', 'Email codes are not available in demo mode. Use email and password.');
    },
    async verifyEmailOtp() {
      throw new AppError('not_supported', 'Email codes are not available in demo mode. Use email and password.');
    },
    async resendVerification() {
      // Demo accounts are confirmed immediately.
    },
    async requestPasswordReset() {
      throw new AppError('not_supported', 'Password reset emails are not available in demo mode.');
    },
    async updatePassword(password) {
      if (!current) throw new AppError('not_authenticated', 'Sign in first.');
      if (password.length < 8) throw new AppError('validation', 'Password must be at least 8 characters.');
      await db.query(
        `update auth.users set encrypted_password = encode(sha256(convert_to(email || ':' || $2, 'UTF8')), 'hex') where id = $1`,
        [current.userId, password],
      );
    },
    async signOut() {
      setSession(null);
    },
  };
}
