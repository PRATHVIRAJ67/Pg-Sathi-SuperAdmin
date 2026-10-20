import { AppError, createAdminService, createDataService, type ResidentAccessService } from '@pg/api-client';
import { createDemoAuth, createPgliteTransport, openDatabase, type KeyValueStorage, type SqlFile } from './database';
import { DEMO_ACCOUNT, DEMO_ADMIN_ACCOUNT, seedDemoPlatformAdmin, seedDemoWorkspace } from './demo-seed';

export interface DemoBackendOptions {
  migrations: SqlFile[];
  seeds: SqlFile[];
  /** IndexedDB name for persistence in the browser, e.g. "pg-saas-demo". */
  databaseName?: string;
  storage: KeyValueStorage;
  /** Also create a demo platform-admin account (super-admin app). */
  withPlatformAdmin?: boolean;
  onProgress?: (message: string) => void;
}

function hashSchema(files: SqlFile[]): string {
  // FNV-1a over all migration text: a changed schema resets demo data.
  let h = 0x811c9dc5;
  for (const f of files) {
    const s = f.name + f.sql;
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 0x01000193);
    }
  }
  return (h >>> 0).toString(16);
}

async function deleteIndexedDb(name: string) {
  if (typeof indexedDB === 'undefined') return;
  await new Promise<void>((resolve) => {
    const req = indexedDB.deleteDatabase(`/pglite/${name}`);
    req.onsuccess = req.onerror = req.onblocked = () => resolve();
  });
}

/**
 * Demo backend: the real Supabase migrations running in PGlite, persisted in
 * the browser. Data never leaves the device and is never mixed with
 * production data — the apps only use this when Supabase is not configured.
 */
export async function createDemoBackend(options: DemoBackendOptions) {
  const schemaHash = hashSchema([...options.migrations, ...options.seeds]);
  const hashKey = `pg-saas-demo-schema:${options.databaseName ?? 'memory'}`;
  if (options.databaseName && options.storage.getItem(hashKey) !== schemaHash) {
    options.onProgress?.('Updating demo database…');
    await deleteIndexedDb(options.databaseName);
    options.storage.removeItem('pg-saas-demo-session');
  }

  options.onProgress?.('Starting the in-browser database…');
  const db = await openDatabase({
    migrations: options.migrations,
    seeds: options.seeds,
    dataDir: options.databaseName ? `idb://${options.databaseName}` : undefined,
  });
  if (options.databaseName) options.storage.setItem(hashKey, schemaHash);

  const auth = createDemoAuth(db, options.storage);
  options.onProgress?.('Preparing sample workspace…');
  await seedDemoWorkspace(db, auth);
  if (options.withPlatformAdmin) await seedDemoPlatformAdmin(db, auth);

  const transport = createPgliteTransport(db, () => auth.currentUserId());

  // Demo stand-in for the server-side app-login service: same checks, run
  // directly against the in-browser database.
  async function authorize(residentId: string) {
    const caller = auth.currentUserId();
    if (!caller) throw new AppError('not_authenticated', 'Sign in to continue.');
    const res = await db.query<{ tenant_id: string; role: string | null }>(
      `select r.tenant_id, m.role
         from public.residents r
         left join public.tenant_memberships m
           on m.tenant_id = r.tenant_id and m.user_id = $2 and m.status = 'active'
        where r.id = $1`,
      [residentId, caller],
    );
    const row = res.rows[0];
    if (!row || !row.role) throw new AppError('not_found', 'Resident not found.');
    if (row.role !== 'owner' && row.role !== 'manager') throw new AppError('forbidden', 'Only the owner or a manager can manage resident app logins.');
    const link = await db.query<{ user_id: string }>('select user_id from public.resident_user_links where resident_id = $1', [residentId]);
    return { tenantId: row.tenant_id, caller, linkedUser: link.rows[0]?.user_id ?? null };
  }
  const residentAccess: ResidentAccessService = {
    available: true,
    async create(residentId, email, password) {
      const { tenantId, linkedUser } = await authorize(residentId);
      if (linkedUser) throw new AppError('duplicate', 'This resident already has an app login. Use "Reset password" instead.');
      const normalized = email.trim().toLowerCase();
      const userId = await auth.createUser({ email: normalized, password, confirmed: true });
      await db.query('insert into public.resident_user_links (tenant_id, resident_id, user_id) values ($1, $2, $3)', [tenantId, residentId, userId]);
      await db.query('update public.residents set email = $2 where id = $1', [residentId, normalized]);
      return { email: normalized };
    },
    async resetPassword(residentId, password) {
      const { linkedUser } = await authorize(residentId);
      if (!linkedUser) throw new AppError('no_access', 'This resident does not have an app login yet.');
      if (password.length < 8) throw new AppError('validation', 'Password must be at least 8 characters.');
      await db.query(
        `update auth.users set encrypted_password = encode(sha256(convert_to(email || ':' || $2, 'UTF8')), 'hex') where id = $1`,
        [linkedUser, password],
      );
    },
    async revoke(residentId) {
      await authorize(residentId);
      await db.query('delete from public.resident_user_links where resident_id = $1', [residentId]);
    },
  };

  return {
    db,
    auth,
    transport,
    data: createDataService(transport),
    admin: createAdminService(transport),
    residentAccess,
    sampleAccount: options.withPlatformAdmin ? DEMO_ADMIN_ACCOUNT : DEMO_ACCOUNT,
    async reset() {
      await db.close();
      if (options.databaseName) await deleteIndexedDb(options.databaseName);
      options.storage.removeItem(hashKey);
      options.storage.removeItem('pg-saas-demo-session');
    },
  };
}
