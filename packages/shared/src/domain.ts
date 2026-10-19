import type {
  BedStatus,
  DepositTxnKind,
  GenderPolicy,
  InvoiceItemKind,
  InvoicePaymentStatus,
  InvoiceStatus,
  PaymentMethod,
  PropertyType,
  RentMode,
  ResidentStatus,
  SubscriptionStatus,
  TenantRole,
  TenantStatus,
} from './types';
import type { ISODate } from './dates';
import type { Paise } from './money';

// ---------------------------------------------------------------------------
// Labels for system vocabularies (UI copy, not business data)
// ---------------------------------------------------------------------------
export const PAYMENT_METHOD_LABELS: Record<PaymentMethod, string> = {
  cash: 'Cash',
  upi: 'UPI',
  bank_transfer: 'Bank transfer',
  card: 'Card',
  cheque: 'Cheque',
  other: 'Other',
};
export const PAYMENT_METHODS = Object.keys(PAYMENT_METHOD_LABELS) as PaymentMethod[];

export const PROPERTY_TYPE_LABELS: Record<PropertyType, string> = {
  pg: 'PG',
  hostel: 'Hostel',
  coliving: 'Co-living',
  service_apartment: 'Service apartment',
  other: 'Other',
};
export const PROPERTY_TYPES = Object.keys(PROPERTY_TYPE_LABELS) as PropertyType[];

export const GENDER_POLICY_LABELS: Record<GenderPolicy, string> = {
  male: 'Men only',
  female: 'Women only',
  any: 'Co-ed / any',
};

export const RENT_MODE_LABELS: Record<RentMode, string> = {
  per_bed: 'Per bed',
  per_room: 'Per room',
};

export const ROLE_LABELS: Record<TenantRole, string> = {
  owner: 'Owner',
  manager: 'Property manager',
  accountant: 'Accountant',
  staff: 'Staff',
};

export const ROLE_DESCRIPTIONS: Record<TenantRole, string> = {
  owner: 'Full access, including settings, team and plan.',
  manager: 'Runs properties, residents, rent and payments. No settings or team access.',
  accountant: 'Invoices, payments, deposits, expenses and reports.',
  staff: 'Views properties, rooms and residents. No financial access.',
};

export const TENANT_STATUS_LABELS: Record<TenantStatus, string> = {
  trial: 'Trial',
  active: 'Active',
  suspended: 'Suspended',
  cancelled: 'Cancelled',
};

export const SUBSCRIPTION_STATUS_LABELS: Record<SubscriptionStatus, string> = {
  trialing: 'Trialing',
  active: 'Active',
  past_due: 'Past due',
  cancelled: 'Cancelled',
};

export const INVOICE_PAYMENT_STATUS_LABELS: Record<InvoicePaymentStatus, string> = {
  paid: 'Paid',
  partially_paid: 'Partially paid',
  pending: 'Pending',
  overdue: 'Overdue',
  void: 'Void',
};

export const INVOICE_ITEM_KIND_LABELS: Record<InvoiceItemKind, string> = {
  rent: 'Rent',
  charge: 'Charge',
  discount: 'Discount',
  adjustment: 'Adjustment',
  other: 'Other',
};

export const RESIDENT_STATUS_LABELS: Record<ResidentStatus, string> = {
  active: 'Staying',
  unassigned: 'No bed yet',
  moved_out: 'Moved out',
  archived: 'Archived',
};

export const BED_STATUS_LABELS: Record<BedStatus, string> = {
  vacant: 'Vacant',
  occupied: 'Occupied',
  unavailable: 'Unavailable',
};

export const DEPOSIT_KIND_LABELS: Record<DepositTxnKind, string> = {
  collected: 'Collected',
  refunded: 'Refunded',
  deducted: 'Deducted',
};

// ---------------------------------------------------------------------------
// Permissions — mirrors the database role groups (private.r_*). The database
// is the enforcement point; this matrix only decides what the UI offers.
// ---------------------------------------------------------------------------
export type Permission =
  | 'workspace.manage'
  | 'team.manage'
  | 'properties.write'
  | 'residents.write'
  | 'finance.read'
  | 'finance.write'
  | 'finance.void'
  | 'expenses.delete'
  | 'audit.read';

const PERMISSIONS: Record<TenantRole, ReadonlySet<Permission>> = {
  owner: new Set<Permission>([
    'workspace.manage',
    'team.manage',
    'properties.write',
    'residents.write',
    'finance.read',
    'finance.write',
    'finance.void',
    'expenses.delete',
    'audit.read',
  ]),
  manager: new Set<Permission>([
    'properties.write',
    'residents.write',
    'finance.read',
    'finance.write',
    'finance.void',
    'expenses.delete',
    'audit.read',
  ]),
  accountant: new Set<Permission>(['finance.read', 'finance.write']),
  staff: new Set<Permission>([]),
};

export function can(role: TenantRole | null | undefined, permission: Permission): boolean {
  if (!role) return false;
  return PERMISSIONS[role].has(permission);
}

// ---------------------------------------------------------------------------
// Business rules mirrored from the database for client-side previews. The
// server remains authoritative; these power live UI feedback only.
// ---------------------------------------------------------------------------

/** Same derivation as private.invoice_payment_status(). */
export function deriveInvoicePaymentStatus(
  status: InvoiceStatus,
  totalPaise: Paise,
  paidPaise: Paise,
  dueDate: ISODate,
  today: ISODate,
): InvoicePaymentStatus {
  if (status === 'void') return 'void';
  if (paidPaise >= totalPaise) return 'paid';
  if (dueDate < today) return 'overdue';
  if (paidPaise > 0) return 'partially_paid';
  return 'pending';
}

export interface OpenInvoice {
  id: string;
  due_date: ISODate;
  balance_paise: Paise;
}

/**
 * Preview of how a payment will be allocated: oldest due first, like
 * private.allocate_payment(). Returns per-invoice amounts and leftover credit.
 */
export function previewAllocation(amountPaise: Paise, invoices: OpenInvoice[]) {
  let remaining = Math.max(0, amountPaise);
  const allocations: { invoice_id: string; amount_paise: Paise }[] = [];
  const sorted = [...invoices].sort((a, b) => a.due_date.localeCompare(b.due_date));
  for (const inv of sorted) {
    if (remaining <= 0) break;
    if (inv.balance_paise <= 0) continue;
    const take = Math.min(remaining, inv.balance_paise);
    allocations.push({ invoice_id: inv.id, amount_paise: take });
    remaining -= take;
  }
  return { allocations, credit_paise: remaining };
}

/** Prorated rent for a partial first month, matching generate_rent_invoices(). */
export function proratedRent(monthlyRentPaise: Paise, moveIn: ISODate, monthStart: ISODate): Paise {
  const start = new Date(`${monthStart}T00:00:00Z`);
  const end = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 1, 0));
  const daysInMonth = end.getUTCDate();
  const moveInDate = new Date(`${moveIn}T00:00:00Z`);
  if (moveInDate <= start) return monthlyRentPaise;
  const daysStayed = Math.round((end.getTime() - moveInDate.getTime()) / 86_400_000) + 1;
  // Rounded to whole rupees like the database (round() on numeric, half away from zero).
  return Math.round((monthlyRentPaise * daysStayed) / daysInMonth / 100) * 100;
}

export function occupancyRate(occupied: number, totalBeds: number, unavailable = 0): number {
  const usable = totalBeds - unavailable;
  if (usable <= 0) return 0;
  return Math.round((occupied / usable) * 1000) / 10;
}

export function initials(name: string | null | undefined): string {
  if (!name) return '?';
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return '?';
  const first = parts[0]?.[0] ?? '';
  const last = parts.length > 1 ? (parts[parts.length - 1]?.[0] ?? '') : '';
  return (first + last).toUpperCase();
}
