/**
 * Normalised application error. Database functions raise errors with a
 * human-readable message and a machine-readable `hint` (e.g. "plan_limit",
 * "bed_occupied"); both Supabase (PostgREST) and PGlite surface those fields.
 */
export type AppErrorCode =
  | 'not_authenticated'
  | 'not_verified'
  | 'forbidden'
  | 'not_found'
  | 'validation'
  | 'duplicate'
  | 'possible_duplicate'
  | 'plan_limit'
  | 'tenant_inactive'
  | 'bed_occupied'
  | 'bed_unavailable'
  | 'resident_has_active_stay'
  | 'idempotency_conflict'
  | 'over_allocated'
  | 'exceeds_deposit_held'
  | 'rate_limited'
  | 'invalid_invitation'
  | 'invitation_expired'
  | 'email_mismatch'
  | 'network'
  | 'demo_read_only'
  | 'not_supported'
  | 'unknown'
  | (string & {});

export class AppError extends Error {
  readonly code: AppErrorCode;
  readonly detail?: string;
  readonly sqlState?: string;

  constructor(code: AppErrorCode, message: string, options: { detail?: string; sqlState?: string; cause?: unknown } = {}) {
    super(message);
    this.name = 'AppError';
    this.code = code;
    this.detail = options.detail;
    this.sqlState = options.sqlState;
    if (options.cause !== undefined) (this as { cause?: unknown }).cause = options.cause;
  }

  /** True for errors the user can fix by changing input. */
  get isUserFacing(): boolean {
    return this.code !== 'unknown' && this.code !== 'network';
  }
}

interface DbErrorLike {
  code?: string;
  message?: string;
  hint?: string | null;
  details?: string | null;
  detail?: string | null;
}

const GENERIC_BY_SQLSTATE: Record<string, [AppErrorCode, string]> = {
  '28000': ['not_authenticated', 'Please sign in again.'],
  '42501': ['forbidden', 'You do not have permission to do that.'],
  P0002: ['not_found', 'That record could not be found.'],
  '23505': ['duplicate', 'This record already exists.'],
  '23503': ['validation', 'This record is linked to other records and cannot be changed that way.'],
  '23514': ['validation', 'Some values are outside the allowed range.'],
  '23502': ['validation', 'A required value is missing.'],
  '22P02': ['validation', 'Some values are not in the expected format.'],
  '22007': ['validation', 'A date is not valid.'],
  '22008': ['validation', 'A date is not valid.'],
  '22003': ['validation', 'A number is too large.'],
  PGRST301: ['not_authenticated', 'Your session has expired. Please sign in again.'],
  PGRST303: ['not_authenticated', 'Your session has expired. Please sign in again.'],
};

export function toAppError(error: unknown): AppError {
  if (error instanceof AppError) return error;

  if (error && typeof error === 'object') {
    const e = error as DbErrorLike;
    const sqlState = typeof e.code === 'string' ? e.code : undefined;
    const hint = typeof e.hint === 'string' && /^[a-z_]+$/.test(e.hint) ? e.hint : undefined;
    const detail = (e.details ?? e.detail) || undefined;

    // Errors raised deliberately by our database functions carry a hint and a
    // message written for end users.
    if (hint && e.message) {
      return new AppError(hint, e.message, { detail, sqlState, cause: error });
    }
    if (sqlState && GENERIC_BY_SQLSTATE[sqlState]) {
      const [code, message] = GENERIC_BY_SQLSTATE[sqlState];
      // Our own P0002/42501 messages are already user-facing.
      const useOwn = (sqlState === 'P0002' || sqlState === '42501' || sqlState === '28000') && e.message;
      return new AppError(code, useOwn ? e.message! : message, { detail, sqlState, cause: error });
    }
    if (error instanceof TypeError && /fetch|network/i.test(error.message)) {
      return new AppError('network', 'Could not reach the server. Check your connection and try again.', { cause: error });
    }
    if (error instanceof Error) {
      return new AppError('unknown', 'Something went wrong. Please try again.', { cause: error, sqlState });
    }
  }
  return new AppError('unknown', 'Something went wrong. Please try again.', { cause: error });
}

export function errorMessage(error: unknown): string {
  return toAppError(error).message;
}
