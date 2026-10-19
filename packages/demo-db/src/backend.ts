import { createAdminService, createDataService } from '@pg/api-client';
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

  return {
    db,
    auth,
    transport,
    data: createDataService(transport),
    admin: createAdminService(transport),
    sampleAccount: options.withPlatformAdmin ? DEMO_ADMIN_ACCOUNT : DEMO_ACCOUNT,
    async reset() {
      await db.close();
      if (options.databaseName) await deleteIndexedDb(options.databaseName);
      options.storage.removeItem(hashKey);
      options.storage.removeItem('pg-saas-demo-session');
    },
  };
}
