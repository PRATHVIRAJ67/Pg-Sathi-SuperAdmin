/**
 * Domain types. Field names mirror the database (snake_case) because the API
 * returns JSON built directly from rows; this avoids a lossy mapping layer.
 */
import type { ISODate } from './dates';
import type { Paise } from './money';

export type UUID = string;
export type Timestamp = string;

export type TenantRole = 'owner' | 'manager' | 'accountant' | 'staff';
export type TenantStatus = 'trial' | 'active' | 'suspended' | 'cancelled';
export type SubscriptionStatus = 'trialing' | 'active' | 'past_due' | 'cancelled';
export type RentMode = 'per_bed' | 'per_room';
export type PaymentMethod = 'cash' | 'upi' | 'bank_transfer' | 'card' | 'cheque' | 'other';
export type PaymentSource = 'manual' | 'gateway';
export type PaymentStatus = 'recorded' | 'voided' | 'pending' | 'succeeded' | 'failed' | 'refunded';
export type InvoiceKind = 'rent' | 'other';
export type InvoiceStatus = 'issued' | 'void';
export type InvoicePaymentStatus = 'paid' | 'partially_paid' | 'pending' | 'overdue' | 'void';
export type InvoiceItemKind = 'rent' | 'charge' | 'discount' | 'adjustment' | 'other';
export type DepositTxnKind = 'collected' | 'refunded' | 'deducted';
export type PropertyType = 'pg' | 'hostel' | 'coliving' | 'service_apartment' | 'other';
export type GenderPolicy = 'male' | 'female' | 'any';
export type Gender = 'male' | 'female' | 'other';
export type ResidentStatus = 'active' | 'unassigned' | 'moved_out' | 'archived';
export type BedStatus = 'vacant' | 'occupied' | 'unavailable';
export type OnboardingStep = 'property' | 'rooms' | 'rent' | 'residents' | 'done';

// ---------------------------------------------------------------------------
// Session / workspace
// ---------------------------------------------------------------------------
export interface WorkspaceSummary {
  tenant_id: UUID;
  name: string;
  role: TenantRole;
  status: TenantStatus;
  onboarding_step: OnboardingStep;
  onboarding_completed_at: Timestamp | null;
  logo_path: string | null;
}

export interface ResidentLink {
  tenant_id: UUID;
  tenant_name: string;
  resident_id: UUID;
  resident_name: string;
}

export interface UserContext {
  user: { id: UUID; full_name?: string | null; email?: string | null; phone?: string | null };
  is_platform_admin: boolean;
  workspaces: WorkspaceSummary[];
  resident_links: ResidentLink[];
}

export interface Tenant {
  id: UUID;
  name: string;
  status: TenantStatus;
  contact_name: string | null;
  contact_phone: string | null;
  contact_email: string | null;
  address_line: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  gstin: string | null;
  logo_path: string | null;
  created_by: UUID;
  onboarding_step: OnboardingStep;
  onboarding_completed_at: Timestamp | null;
  status_reason: string | null;
  created_at: Timestamp;
  updated_at: Timestamp;
}

export interface TenantSettings {
  tenant_id: UUID;
  default_rent_mode: RentMode;
  default_billing_day: number;
  payment_due_days: number;
  default_deposit_paise: Paise;
  prorate_first_month: boolean;
  invoice_prefix: string;
  receipt_prefix: string;
  next_invoice_number: number;
  next_receipt_number: number;
  payment_methods: PaymentMethod[];
  expense_categories: string[];
  facility_options: string[];
  receipt_footer: string | null;
  upi_id: string | null;
  notification_prefs: Record<string, unknown>;
  updated_at: Timestamp;
}

export interface Plan {
  id: UUID;
  code: string;
  name: string;
  description: string | null;
  price_paise: Paise;
  billing_interval: 'month' | 'year';
  max_properties: number | null;
  max_residents: number | null;
  max_staff: number | null;
  features: string[];
  trial_days: number;
  is_public: boolean;
  is_active: boolean;
  sort_order: number;
}

export interface Subscription {
  id: UUID;
  tenant_id: UUID;
  plan_id: UUID;
  status: SubscriptionStatus;
  trial_ends_at: Timestamp | null;
  current_period_start: Timestamp | null;
  current_period_end: Timestamp | null;
  provider: string | null;
}

export interface Workspace {
  tenant: Tenant;
  settings: TenantSettings;
  subscription: Subscription | null;
  plan: Plan | null;
  usage: { properties: number; residents: number; staff: number };
  my_role: TenantRole;
}

// ---------------------------------------------------------------------------
// Properties, rooms, beds
// ---------------------------------------------------------------------------
export interface Property {
  id: UUID;
  tenant_id: UUID;
  name: string;
  property_type: PropertyType;
  gender_policy: GenderPolicy;
  address_line1: string | null;
  address_line2: string | null;
  locality: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  contact_phone: string | null;
  description: string | null;
  facilities: string[];
  status: 'active' | 'archived';
  cover_image_path: string | null;
  created_at: Timestamp;
  room_count: number;
  bed_count: number;
  occupied_count: number;
  unavailable_count: number;
}

export interface PropertySettings {
  property_id: UUID;
  billing_day: number | null;
  payment_due_days: number | null;
  notice_period_days: number;
  house_rules: string | null;
}

export interface PropertyDetail extends Property {
  settings: PropertySettings | null;
}

export interface BedOccupant {
  stay_id: UUID;
  resident_id: UUID;
  full_name: string;
  move_in_date: ISODate;
}

export interface Bed {
  id: UUID;
  label: string;
  rent_paise: Paise | null;
  suggested_rent_paise: Paise;
  is_unavailable: boolean;
  unavailable_reason: string | null;
  status: BedStatus;
  occupant: BedOccupant | null;
}

export interface Room {
  id: UUID;
  tenant_id: UUID;
  property_id: UUID;
  property_name: string;
  name: string;
  floor: string | null;
  category: string | null;
  rent_mode: RentMode;
  rent_paise: Paise;
  deposit_paise: Paise;
  amenities: string[];
  notes: string | null;
  is_active: boolean;
  beds: Bed[];
}

// ---------------------------------------------------------------------------
// Residents and stays
// ---------------------------------------------------------------------------
export interface ResidentStaySummary {
  stay_id: UUID;
  property_id: UUID;
  property_name: string;
  room_id: UUID;
  room_name: string;
  bed_id: UUID;
  bed_label: string;
  move_in_date: ISODate;
  expected_move_out_date: ISODate | null;
}

export interface ResidentListItem {
  id: UUID;
  full_name: string;
  phone: string | null;
  email: string | null;
  gender: Gender | null;
  occupation: string | null;
  archived_at: Timestamp | null;
  created_at: Timestamp;
  status: ResidentStatus;
  stay: ResidentStaySummary | null;
  /** Finance fields are null for roles without finance access. */
  monthly_rent_paise: Paise | null;
  outstanding_paise: Paise | null;
  overdue_paise: Paise | null;
  credit_paise: Paise | null;
  deposit_held_paise: Paise | null;
}

export interface Paged<T> {
  total: number;
  rows: T[];
}

export interface RentAgreement {
  id: UUID;
  stay_id: UUID;
  monthly_rent_paise: Paise;
  deposit_paise: Paise;
  billing_day: number;
  effective_from: ISODate;
  /** Exclusive end date; null while the agreement is current. */
  effective_to: ISODate | null;
  note: string | null;
  created_at: Timestamp;
}

export interface Stay {
  id: UUID;
  resident_id: UUID;
  property_id: UUID;
  bed_id: UUID;
  move_in_date: ISODate;
  expected_move_out_date: ISODate | null;
  move_out_date: ISODate | null;
  status: 'active' | 'ended';
  notes: string | null;
  property_name: string;
  room_id: UUID;
  room_name: string;
  bed_label: string;
  agreements: RentAgreement[];
}

export interface Resident {
  id: UUID;
  tenant_id: UUID;
  full_name: string;
  phone: string | null;
  email: string | null;
  gender: Gender | null;
  date_of_birth: ISODate | null;
  occupation: string | null;
  organization: string | null;
  id_proof_type: string | null;
  id_proof_number: string | null;
  permanent_address: string | null;
  emergency_contact_name: string | null;
  emergency_contact_phone: string | null;
  emergency_contact_relation: string | null;
  notes: string | null;
  archived_at: Timestamp | null;
  created_at: Timestamp;
}

export interface ResidentInvoiceSummary {
  id: UUID;
  invoice_number: string;
  kind: InvoiceKind;
  period_start: ISODate | null;
  period_end: ISODate | null;
  issue_date: ISODate;
  due_date: ISODate;
  status: InvoiceStatus;
  total_paise: Paise;
  paid_paise: Paise;
  balance_paise: Paise;
  payment_status: InvoicePaymentStatus;
}

export interface ResidentPaymentSummary {
  id: UUID;
  receipt_number: string;
  amount_paise: Paise;
  paid_on: ISODate;
  method: PaymentMethod;
  source: PaymentSource;
  status: PaymentStatus;
  reference: string | null;
}

export interface DepositTransaction {
  id: UUID;
  resident_id: UUID;
  stay_id: UUID | null;
  kind: DepositTxnKind;
  amount_paise: Paise;
  txn_date: ISODate;
  method: PaymentMethod | null;
  reference: string | null;
  notes: string | null;
  created_at: Timestamp;
}

export interface ResidentDetail extends Resident {
  status: ResidentStatus;
  stays: Stay[];
  finance_visible: boolean;
  balance: {
    invoiced_paise: Paise;
    paid_paise: Paise;
    outstanding_paise: Paise;
    overdue_paise: Paise;
    credit_paise: Paise;
  } | null;
  invoices: ResidentInvoiceSummary[];
  payments: ResidentPaymentSummary[];
  deposit: {
    agreed_paise: Paise;
    collected_paise: Paise;
    refunded_paise: Paise;
    deducted_paise: Paise;
    transactions: DepositTransaction[];
  } | null;
  has_app_account: boolean;
  pending_invitation: { id: UUID; email: string; expires_at: Timestamp } | null;
}

// ---------------------------------------------------------------------------
// Finance
// ---------------------------------------------------------------------------
export interface InvoiceListItem {
  id: UUID;
  tenant_id: UUID;
  resident_id: UUID;
  property_id: UUID;
  stay_id: UUID | null;
  invoice_number: string;
  kind: InvoiceKind;
  period_start: ISODate | null;
  period_end: ISODate | null;
  issue_date: ISODate;
  due_date: ISODate;
  status: InvoiceStatus;
  total_paise: Paise;
  paid_paise: Paise;
  balance_paise: Paise;
  payment_status: InvoicePaymentStatus;
  resident_name: string;
  resident_phone: string | null;
  property_name: string;
  notes: string | null;
  created_at: Timestamp;
  voided_at: Timestamp | null;
  void_reason: string | null;
}

export interface InvoiceItem {
  id: UUID;
  kind: InvoiceItemKind;
  description: string;
  amount_paise: Paise;
  sort_order: number;
}

export interface BusinessDetails {
  name: string;
  address_line: string | null;
  city: string | null;
  state: string | null;
  postal_code: string | null;
  contact_phone: string | null;
  contact_email: string | null;
  gstin: string | null;
  logo_path: string | null;
  receipt_footer: string | null;
  upi_id: string | null;
}

export interface InvoiceDetail extends Omit<InvoiceListItem, 'resident_name' | 'resident_phone' | 'property_name'> {
  items: InvoiceItem[];
  allocations: {
    id: UUID;
    payment_id: UUID;
    receipt_number: string;
    paid_on: ISODate;
    method: PaymentMethod;
    amount_paise: Paise;
    voided_at: Timestamp | null;
  }[];
  resident: { id: UUID; full_name: string; phone: string | null; email: string | null };
  property: { id: UUID; name: string; address_line1: string | null; city: string | null };
  business: BusinessDetails;
}

export interface PaymentListItem {
  id: UUID;
  receipt_number: string;
  resident_id: UUID;
  property_id: UUID | null;
  amount_paise: Paise;
  paid_on: ISODate;
  method: PaymentMethod;
  source: PaymentSource;
  status: PaymentStatus;
  reference: string | null;
  notes: string | null;
  created_at: Timestamp;
  voided_at: Timestamp | null;
  void_reason: string | null;
  resident_name: string;
  property_name: string | null;
  allocated_paise: Paise;
}

export interface PaymentDetail {
  id: UUID;
  tenant_id: UUID;
  resident_id: UUID;
  property_id: UUID | null;
  receipt_number: string;
  amount_paise: Paise;
  paid_on: ISODate;
  method: PaymentMethod;
  source: PaymentSource;
  status: PaymentStatus;
  reference: string | null;
  notes: string | null;
  created_at: Timestamp;
  voided_at: Timestamp | null;
  void_reason: string | null;
  gateway_provider: string | null;
  gateway_payment_id: string | null;
  allocations: {
    id: UUID;
    invoice_id: UUID;
    invoice_number: string;
    period_start: ISODate | null;
    due_date: ISODate;
    amount_paise: Paise;
    voided_at: Timestamp | null;
  }[];
  allocated_paise: Paise;
  resident: { id: UUID; full_name: string; phone: string | null; email: string | null };
  property: { id: UUID; name: string; address_line1: string | null; city: string | null } | null;
  recorded_by_name: string | null;
  business: BusinessDetails;
}

export interface DepositRow {
  resident_id: UUID;
  full_name: string;
  stay_status: 'active' | 'ended' | null;
  property_id: UUID | null;
  property_name: string | null;
  agreed_paise: Paise;
  collected_paise: Paise;
  refunded_paise: Paise;
  deducted_paise: Paise;
  held_paise: Paise;
  due_paise: Paise;
}

export interface DepositOverview {
  rows: DepositRow[];
  totals: { held_paise: Paise; due_paise: Paise; refunded_paise: Paise; deducted_paise: Paise };
  recent_transactions: (DepositTransaction & { full_name: string })[];
}

export interface Expense {
  id: UUID;
  tenant_id: UUID;
  property_id: UUID | null;
  property_name: string | null;
  category: string;
  amount_paise: Paise;
  expense_date: ISODate;
  payee: string | null;
  method: PaymentMethod | null;
  reference: string | null;
  notes: string | null;
  receipt_path: string | null;
  created_at: Timestamp;
}

export interface ExpenseList extends Paged<Expense> {
  totals: { amount_paise: Paise };
  by_category: { category: string; amount_paise: Paise }[];
}

export interface InvoiceList extends Paged<InvoiceListItem> {
  totals: { total_paise: Paise; paid_paise: Paise; balance_paise: Paise };
}

export interface PaymentList extends Paged<PaymentListItem> {
  totals: { amount_paise: Paise };
}

export interface ChargeTemplate {
  id: UUID;
  tenant_id: UUID;
  property_id: UUID | null;
  property_name: string | null;
  name: string;
  amount_paise: Paise;
  frequency: 'monthly' | 'one_time';
  apply_by_default: boolean;
  is_active: boolean;
}

// ---------------------------------------------------------------------------
// Analytics
// ---------------------------------------------------------------------------
export interface MonthlyPoint {
  month: ISODate;
  billed_paise: Paise;
  collected_paise: Paise;
  expenses_paise: Paise;
}

export interface OutstandingResident {
  resident_id: UUID;
  full_name: string;
  phone?: string | null;
  property_name: string;
  balance_paise: Paise;
  overdue_paise: Paise;
  oldest_due_date: ISODate;
  open_invoices?: number;
}

export interface DashboardSummary {
  month: ISODate;
  today: ISODate;
  finance_visible: boolean;
  occupancy: { total_beds: number; occupied: number; unavailable: number; vacant: number };
  finance: {
    billed_paise: Paise;
    billed_collected_paise: Paise;
    collected_paise: Paise;
    outstanding_paise: Paise;
    overdue_paise: Paise;
    projected_rent_paise: Paise;
    expenses_paise: Paise;
    stays_without_invoice: number;
    series: MonthlyPoint[];
    recent_payments: {
      id: UUID;
      receipt_number: string;
      resident_id: UUID;
      resident_name: string;
      amount_paise: Paise;
      paid_on: ISODate;
      method: PaymentMethod;
    }[];
    top_outstanding: OutstandingResident[];
  } | null;
  recent_checkins: {
    stay_id: UUID;
    resident_id: UUID;
    full_name: string;
    property_name: string;
    room_name: string;
    bed_label: string;
    move_in_date: ISODate;
  }[];
  upcoming_move_outs: {
    stay_id: UUID;
    resident_id: UUID;
    full_name: string;
    property_name: string;
    expected_move_out_date: ISODate;
  }[];
  properties: { id: UUID; name: string; beds: number; occupied: number; unavailable: number }[];
  checklist: {
    has_property: boolean;
    has_rooms: boolean;
    has_residents: boolean;
    has_assignments: boolean;
    has_invoices: boolean;
    has_payments: boolean;
    has_team: boolean;
  };
}

export interface FinancialReport {
  from: ISODate;
  to: ISODate;
  totals: {
    billed_paise: Paise;
    collected_paise: Paise;
    expenses_paise: Paise;
    outstanding_paise: Paise;
    overdue_paise: Paise;
  };
  monthly: MonthlyPoint[];
  by_property: {
    property_id: UUID;
    name: string;
    beds: number;
    occupied: number;
    billed_paise: Paise;
    collected_paise: Paise;
    expenses_paise: Paise;
    outstanding_paise: Paise;
  }[];
  expenses_by_category: { category: string; amount_paise: Paise }[];
  collection_by_method: { method: PaymentMethod; amount_paise: Paise; count: number }[];
  outstanding: OutstandingResident[];
}

// ---------------------------------------------------------------------------
// Team, audit
// ---------------------------------------------------------------------------
export interface Member {
  id: UUID;
  user_id: UUID;
  role: TenantRole;
  status: 'active' | 'suspended';
  created_at: Timestamp;
  full_name: string | null;
  email: string | null;
  is_me: boolean;
}

export interface PendingInvitation {
  id: UUID;
  kind: 'member' | 'resident';
  email: string;
  role: TenantRole | null;
  resident_id: UUID | null;
  expires_at: Timestamp;
  created_at: Timestamp;
}

export interface TeamOverview {
  members: Member[];
  invitations: PendingInvitation[];
}

export interface InvitationToken {
  id: UUID;
  token: string;
  expires_at: Timestamp;
}

export interface AuditLogEntry {
  id: number;
  action: string;
  entity_type: string | null;
  entity_id: UUID | null;
  details: Record<string, unknown>;
  created_at: Timestamp;
  actor_id: UUID | null;
  actor_name: string | null;
}

// ---------------------------------------------------------------------------
// Platform admin
// ---------------------------------------------------------------------------
export interface AdminOverview {
  tenants_total: number;
  tenants_by_status: Partial<Record<TenantStatus, number>>;
  new_tenants_30d: number;
  onboarding_incomplete: number;
  subscriptions_by_plan: { plan_id: UUID; code: string; name: string; count: number }[];
  trials_ending_7d: number;
  usage: { properties: number; beds: number; active_stays: number; residents: number; team_members: number };
  signups_by_month: { month: ISODate; count: number }[];
  recent_tenants: {
    id: UUID;
    name: string;
    status: TenantStatus;
    city: string | null;
    created_at: Timestamp;
    onboarding_completed_at: Timestamp | null;
    plan_name: string | null;
  }[];
}

export interface AdminTenantRow {
  id: UUID;
  name: string;
  status: TenantStatus;
  city: string | null;
  state: string | null;
  contact_name: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  created_at: Timestamp;
  onboarding_completed_at: Timestamp | null;
  onboarding_step: OnboardingStep;
  subscription_status: SubscriptionStatus | null;
  trial_ends_at: Timestamp | null;
  plan_id: UUID | null;
  plan_name: string | null;
  property_count: number;
  resident_count: number;
  member_count: number;
}

export interface AdminTenantDetail {
  tenant: Tenant;
  subscription: Subscription | null;
  plan: Plan | null;
  members: { role: TenantRole; status: string; full_name: string | null; email: string | null; created_at: Timestamp }[];
  usage: {
    properties: number;
    rooms: number;
    beds: number;
    active_stays: number;
    residents: number;
    invoices: number;
    payments: number;
  };
  admin_activity: { id: number; action: string; details: Record<string, unknown>; created_at: Timestamp; actor_name: string | null }[];
}

export interface AdminPlan extends Plan {
  subscriber_count: number;
  is_default: boolean;
}

export interface AdminAuditEntry {
  id: number;
  tenant_id: UUID | null;
  tenant_name: string | null;
  action: string;
  entity_type: string | null;
  entity_id: UUID | null;
  details: Record<string, unknown>;
  created_at: Timestamp;
  actor_name: string | null;
  actor_email: string | null;
}

export interface PlatformSettings {
  default_plan_id: UUID | null;
  signup_enabled: boolean;
  support_email: string | null;
  updated_at: Timestamp;
}
