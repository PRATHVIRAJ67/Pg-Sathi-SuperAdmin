import { createAdminService, createDataService, createSupabaseBackend } from '@pg/api-client';
import { unavailableStorage, type Backend } from '@pg/api-client/react';

export type BootResult = { ok: true; backend: Backend } | { ok: false; message: string };

/**
 * Same rule as the owner dashboard: Supabase when configured; demo mode only
 * without Supabase (and in production builds only with VITE_ENABLE_DEMO=true).
 */
export async function bootBackend(onProgress: (m: string) => void): Promise<BootResult> {
  const url = (import.meta.env.VITE_SUPABASE_URL as string | undefined)?.trim();
  const key = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined)?.trim();
  try {
    if (url && key) {
      const sb = createSupabaseBackend({ url, anonKey: key });
      return { ok: true, backend: { mode: 'supabase', data: createDataService(sb.transport), admin: createAdminService(sb.transport), auth: sb.auth, storage: sb.storage } };
    }
    if (import.meta.env.PROD && import.meta.env.VITE_ENABLE_DEMO !== 'true') {
      return { ok: false, message: 'This deployment is missing VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY.' };
    }
    const [{ createDemoBackend }, { default: seedSql }] = await Promise.all([import('@pg/demo-db'), import('../supabase/seed.sql?raw')]);
    const modules = import.meta.glob('../supabase/migrations/*.sql', { query: '?raw', import: 'default', eager: true }) as Record<string, string>;
    const migrations = Object.entries(modules)
      .map(([path, sql]) => ({ name: path.split('/').pop()!, sql }))
      .sort((a, b) => a.name.localeCompare(b.name));
    const demo = await createDemoBackend({
      migrations,
      seeds: [{ name: 'seed.sql', sql: seedSql }],
      databaseName: 'pg-saas-admin-demo',
      storage: window.localStorage,
      withPlatformAdmin: true,
      onProgress,
    });
    return {
      ok: true,
      backend: {
        mode: 'demo',
        data: demo.data,
        admin: demo.admin,
        auth: demo.auth,
        storage: unavailableStorage,
        demo: {
          description: 'Demo mode: fictional businesses in an in-browser database.',
          sampleAccount: demo.sampleAccount,
          reset: async () => {
            await demo.reset();
            window.location.assign('/');
          },
        },
      },
    };
  } catch (error) {
    return { ok: false, message: error instanceof Error ? error.message : String(error) };
  }
}
