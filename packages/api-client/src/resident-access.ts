import { AppError } from './errors';

/**
 * Owner-side management of resident app logins. Creating a login for someone
 * else needs Supabase's admin API, so in production this calls a small
 * server-side service (apps/resident-api) that holds the secret key and
 * checks the caller is an owner or manager of the resident's business.
 */
export interface ResidentAccessService {
  readonly available: boolean;
  create(residentId: string, email: string, password: string): Promise<{ email: string }>;
  resetPassword(residentId: string, password: string): Promise<void>;
  revoke(residentId: string): Promise<void>;
}

export const unavailableResidentAccess: ResidentAccessService = {
  available: false,
  async create() {
    throw new AppError('not_supported', 'Resident app logins are not configured. Set VITE_RESIDENT_API_URL (see README).');
  },
  async resetPassword() {
    throw new AppError('not_supported', 'Resident app logins are not configured. Set VITE_RESIDENT_API_URL (see README).');
  },
  async revoke() {
    throw new AppError('not_supported', 'Resident app logins are not configured. Set VITE_RESIDENT_API_URL (see README).');
  },
};

export function createResidentAccessClient(baseUrl: string, getAccessToken: () => Promise<string | null>): ResidentAccessService {
  const endpoint = `${baseUrl.replace(/\/$/, '')}/resident-access`;
  async function post<T>(body: object): Promise<T> {
    const token = await getAccessToken();
    if (!token) throw new AppError('not_authenticated', 'Your session has expired. Please sign in again.');
    let res: Response;
    try {
      res = await fetch(endpoint, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
    } catch (error) {
      throw new AppError('network', 'Could not reach the app-login service. Check your connection and try again.', { cause: error });
    }
    const json = (await res.json().catch(() => ({}))) as { error?: { code: string; message: string } } & T;
    if (!res.ok || json.error) throw new AppError(json.error?.code ?? 'unknown', json.error?.message ?? 'Something went wrong. Please try again.');
    return json;
  }
  return {
    available: true,
    create: (residentId, email, password) => post<{ email: string }>({ action: 'create', resident_id: residentId, email, password }),
    resetPassword: async (residentId, password) => {
      await post({ action: 'reset', resident_id: residentId, password });
    },
    revoke: async (residentId) => {
      await post({ action: 'revoke', resident_id: residentId });
    },
  };
}

/** Readable random password for sharing with a resident, e.g. "Ps-7kQm-x2Rt-p9Lw". */
export function generateResidentPassword(): string {
  const alphabet = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = new Uint8Array(12);
  (globalThis as { crypto: Crypto }).crypto.getRandomValues(bytes);
  const s = Array.from(bytes, (b) => alphabet[b % alphabet.length]).join('');
  return `Ps-${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8)}`;
}
