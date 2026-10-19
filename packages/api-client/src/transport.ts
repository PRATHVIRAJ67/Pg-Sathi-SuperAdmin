/**
 * The whole application talks to the backend through named database functions
 * (RPC). A transport only knows how to invoke one. Implementations:
 *   - Supabase (production): supabase.rpc()
 *   - PGlite (demo/tests): the same SQL functions running in WASM Postgres
 *   - Snapshot (mobile demo): read-only recorded responses
 */
export type BackendKind = 'supabase' | 'pglite' | 'snapshot';

export interface RpcTransport {
  readonly kind: BackendKind;
  call<T>(fn: string, args?: Record<string, unknown>): Promise<T>;
}

export interface AuthSession {
  userId: string;
  email: string | null;
  emailConfirmed: boolean;
}

export interface SignUpResult {
  session: AuthSession | null;
  /** True when the user must confirm their email before signing in. */
  needsVerification: boolean;
}

export interface AuthAdapter {
  readonly kind: BackendKind;
  getSession(): Promise<AuthSession | null>;
  onChange(listener: (session: AuthSession | null) => void): () => void;
  signUp(input: { email: string; password: string; fullName?: string; redirectTo?: string }): Promise<SignUpResult>;
  signIn(input: { email: string; password: string }): Promise<AuthSession>;
  sendEmailOtp(email: string, redirectTo?: string): Promise<void>;
  verifyEmailOtp(email: string, token: string): Promise<AuthSession>;
  resendVerification(email: string, redirectTo?: string): Promise<void>;
  requestPasswordReset(email: string, redirectTo?: string): Promise<void>;
  updatePassword(password: string): Promise<void>;
  signOut(): Promise<void>;
}

export interface FileStorage {
  readonly available: boolean;
  upload(bucket: 'tenant-assets' | 'tenant-documents', path: string, file: Blob, contentType?: string): Promise<string>;
  signedUrl(bucket: 'tenant-assets' | 'tenant-documents', path: string, expiresInSeconds?: number): Promise<string>;
  remove(bucket: 'tenant-assets' | 'tenant-documents', path: string): Promise<void>;
}
