import { createClient, type SupabaseClient, type Session, type SupportedStorage } from '@supabase/supabase-js';
import { AppError, toAppError } from './errors';
import type { AuthAdapter, AuthSession, FileStorage, RpcTransport } from './transport';

export interface SupabaseConfig {
  url: string;
  /** Publishable (anon) key. Never pass the service-role key to a client. */
  anonKey: string;
  storage?: SupportedStorage;
  /** Web uses URL session detection for email links; native apps do not. */
  detectSessionInUrl?: boolean;
}

function toSession(session: Session | null): AuthSession | null {
  if (!session?.user) return null;
  return {
    userId: session.user.id,
    email: session.user.email ?? null,
    emailConfirmed: Boolean(session.user.email_confirmed_at ?? session.user.confirmed_at),
  };
}

export function createSupabaseBackend(config: SupabaseConfig) {
  if (isPrivilegedKey(config.anonKey)) {
    // Defensive check: a secret/service-role key must never ship to clients.
    throw new Error('Refusing to start: a secret (service-role) key was supplied to a client application.');
  }
  const client: SupabaseClient = createClient(config.url, config.anonKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: config.detectSessionInUrl ?? true,
      storage: config.storage,
      flowType: 'pkce',
    },
  });

  const transport: RpcTransport = {
    kind: 'supabase',
    async call<T>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
      const { data, error } = await client.rpc(fn, args);
      if (error) throw toAppError(error);
      return data as T;
    },
  };

  const auth: AuthAdapter = {
    kind: 'supabase',
    async getSession() {
      const { data, error } = await client.auth.getSession();
      if (error) throw toAppError(error);
      return toSession(data.session);
    },
    onChange(listener) {
      const { data } = client.auth.onAuthStateChange((_event, session) => listener(toSession(session)));
      return () => data.subscription.unsubscribe();
    },
    async signUp({ email, password, fullName, redirectTo }) {
      const { data, error } = await client.auth.signUp({
        email,
        password,
        options: { data: fullName ? { full_name: fullName } : undefined, emailRedirectTo: redirectTo },
      });
      if (error) throw authError(error);
      const session = toSession(data.session);
      return { session, needsVerification: !session };
    },
    async signIn({ email, password }) {
      const { data, error } = await client.auth.signInWithPassword({ email, password });
      if (error) throw authError(error);
      const session = toSession(data.session);
      if (!session) throw new AppError('not_authenticated', 'Sign-in failed. Please try again.');
      return session;
    },
    async sendEmailOtp(email, redirectTo) {
      const { error } = await client.auth.signInWithOtp({ email, options: { emailRedirectTo: redirectTo, shouldCreateUser: true } });
      if (error) throw authError(error);
    },
    async verifyEmailOtp(email, token, type = 'email') {
      const { data, error } = await client.auth.verifyOtp({ email, token, type });
      if (error) throw authError(error);
      const session = toSession(data.session);
      if (!session) throw new AppError('not_authenticated', 'The code could not be verified.');
      return session;
    },
    async resendVerification(email, redirectTo) {
      const { error } = await client.auth.resend({ type: 'signup', email, options: { emailRedirectTo: redirectTo } });
      if (error) throw authError(error);
    },
    async requestPasswordReset(email, redirectTo) {
      const { error } = await client.auth.resetPasswordForEmail(email, { redirectTo });
      if (error) throw authError(error);
    },
    async updatePassword(password) {
      const { error } = await client.auth.updateUser({ password });
      if (error) throw authError(error);
    },
    async signOut() {
      const { error } = await client.auth.signOut();
      if (error) throw authError(error);
    },
  };

  const storage: FileStorage = {
    available: true,
    async upload(bucket, path, file, contentType) {
      const { data, error } = await client.storage.from(bucket).upload(path, file, { upsert: true, contentType });
      if (error) throw new AppError('validation', error.message, { cause: error });
      return data.path;
    },
    async signedUrl(bucket, path, expiresInSeconds = 300) {
      const { data, error } = await client.storage.from(bucket).createSignedUrl(path, expiresInSeconds);
      if (error) throw new AppError('not_found', 'File not found', { cause: error });
      return data.signedUrl;
    },
    async remove(bucket, path) {
      const { error } = await client.storage.from(bucket).remove([path]);
      if (error) throw new AppError('validation', error.message, { cause: error });
    },
  };

  return { client, transport, auth, storage };
}

/** Detects new-style secret keys and legacy JWT keys whose role is service_role. */
export function isPrivilegedKey(key: string): boolean {
  if (key.startsWith('sb_secret_')) return true;
  const parts = key.split('.');
  if (parts.length !== 3) return false;
  try {
    const base64 = parts[1]!.replace(/-/g, '+').replace(/_/g, '/');
    const json = typeof atob === 'function' ? atob(base64.padEnd(Math.ceil(base64.length / 4) * 4, '=')) : '';
    return /"role"\s*:\s*"service_role"/.test(json);
  } catch {
    return false;
  }
}

function authError(error: { message: string; status?: number; code?: string }): AppError {
  const msg = error.message || 'Authentication failed';
  if (/invalid login credentials/i.test(msg)) return new AppError('not_authenticated', 'Incorrect email or password.', { cause: error });
  if (/email not confirmed/i.test(msg)) return new AppError('not_verified', 'Confirm your email address first. Check your inbox for the link.', { cause: error });
  if (/already registered|already exists/i.test(msg)) return new AppError('duplicate', 'An account with this email already exists. Sign in instead.', { cause: error });
  if (/rate limit|too many/i.test(msg)) return new AppError('rate_limited', 'Too many attempts. Please wait a minute and try again.', { cause: error });
  if (/password/i.test(msg)) return new AppError('validation', msg, { cause: error });
  return new AppError('unknown', msg, { cause: error });
}
