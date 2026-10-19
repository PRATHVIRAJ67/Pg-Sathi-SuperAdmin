import type {
  AdminAuditEntry,
  AdminOverview,
  AdminPlan,
  AdminTenantDetail,
  AdminTenantRow,
  AuditLogEntry,
  ChargeTemplate,
  DashboardSummary,
  DepositOverview,
  DepositTxnKind,
  ExpenseList,
  FinancialReport,
  InvoiceDetail,
  InvoiceItemKind,
  InvoiceKind,
  InvoiceList,
  InvoicePaymentStatus,
  InvitationToken,
  ISODate,
  Paged,
  Paise,
  PaymentDetail,
  PaymentList,
  PaymentMethod,
  Plan,
  PlatformSettings,
  Property,
  PropertyDetail,
  PropertyType,
  GenderPolicy,
  RentMode,
  ResidentDetail,
  ResidentListItem,
  ResidentStatus,
  Room,
  SubscriptionStatus,
  TeamOverview,
  TenantRole,
  TenantSettings,
  TenantStatus,
  UserContext,
  UUID,
  Workspace,
  OnboardingStep,
  Gender,
} from '@pg/shared';
import type { RpcTransport } from './transport';

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------
export interface ProvisionWorkspaceInput {
  requestId: UUID;
  businessName: string;
  ownerName?: string;
  contactPhone?: string;
  contactEmail?: string;
  city?: string;
  state?: string;
}

export interface WorkspacePatch {
  name?: string;
  contact_name?: string | null;
  contact_phone?: string | null;
  contact_email?: string | null;
  address_line?: string | null;
  city?: string | null;
  state?: string | null;
  postal_code?: string | null;
  gstin?: string | null;
  logo_path?: string | null;
}

export type TenantSettingsPatch = Partial<
  Pick<
    TenantSettings,
    | 'default_rent_mode'
    | 'default_billing_day'
    | 'payment_due_days'
    | 'default_deposit_paise'
    | 'prorate_first_month'
    | 'invoice_prefix'
    | 'receipt_prefix'
    | 'payment_methods'
    | 'expense_categories'
    | 'facility_options'
    | 'receipt_footer'
    | 'upi_id'
    | 'notification_prefs'
  >
>;

export interface PropertyInput {
  name?: string;
  property_type?: PropertyType;
  gender_policy?: GenderPolicy;
  address_line1?: string | null;
  address_line2?: string | null;
  locality?: string | null;
  city?: string | null;
  state?: string | null;
  postal_code?: string | null;
  contact_phone?: string | null;
  description?: string | null;
  facilities?: string[];
  cover_image_path?: string | null;
  settings?: {
    billing_day?: number | null;
    payment_due_days?: number | null;
    notice_period_days?: number | null;
    house_rules?: string | null;
  };
}

export interface RoomInput {
  name: string;
  floor?: string | null;
  category?: string | null;
  rent_mode?: RentMode;
  rent_paise: Paise;
  deposit_paise?: Paise;
  bed_count?: number;
  bed_labels?: string[];
  amenities?: string[];
  notes?: string | null;
}

export type RoomPatch = Partial<Omit<RoomInput, 'bed_count' | 'bed_labels'>> & { is_active?: boolean };

export interface BedPatch {
  label?: string;
  rent_paise?: Paise | null;
  is_unavailable?: boolean;
  unavailable_reason?: string | null;
}

export interface ResidentInput {
  full_name?: string;
  phone?: string | null;
  email?: string | null;
  gender?: Gender | null;
  date_of_birth?: ISODate | null;
  occupation?: string | null;
  organization?: string | null;
  id_proof_type?: string | null;
  id_proof_number?: string | null;
  permanent_address?: string | null;
  emergency_contact_name?: string | null;
  emergency_contact_phone?: string | null;
  emergency_contact_relation?: string | null;
  notes?: string | null;
}

export interface ResidentListParams {
  search?: string;
  property_id?: UUID | null;
  status?: 'current' | 'all' | ResidentStatus;
  sort?: 'name' | 'outstanding' | 'move_in';
  limit?: number;
  offset?: number;
}

export interface AssignBedInput {
  residentId: UUID;
  bedId: UUID;
  move_in_date?: ISODate;
  monthly_rent_paise?: Paise;
  deposit_paise?: Paise;
  billing_day?: number;
  expected_move_out_date?: ISODate | null;
  notes?: string | null;
  deposit_collected_paise?: Paise;
  deposit_method?: PaymentMethod;
}

export interface InvoiceLineInput {
  kind?: InvoiceItemKind;
  description: string;
  amount_paise: Paise;
}

export interface CreateInvoiceInput {
  residentId: UUID;
  kind?: InvoiceKind;
  property_id?: UUID;
  period_start?: ISODate;
  period_end?: ISODate;
  issue_date?: ISODate;
  due_date?: ISODate;
  items: InvoiceLineInput[];
  notes?: string | null;
}

export interface InvoiceListParams {
  property_id?: UUID | null;
  status?: 'all' | 'open' | InvoicePaymentStatus;
  month?: ISODate | null;
  resident_id?: UUID | null;
  search?: string;
  limit?: number;
  offset?: number;
}

export interface RecordPaymentInput {
  residentId: UUID;
  amount_paise: Paise;
  paid_on: ISODate;
  method: PaymentMethod;
  reference?: string | null;
  notes?: string | null;
  /** Generate once per user action and reuse it for retries. */
  idempotency_key: UUID;
  allocations?: { invoice_id: UUID; amount_paise: Paise }[];
  allow_duplicate?: boolean;
}

export interface PaymentListParams {
  property_id?: UUID | null;
  resident_id?: UUID | null;
  from?: ISODate | null;
  to?: ISODate | null;
  method?: PaymentMethod | null;
  status?: 'live' | 'voided' | 'all';
  search?: string;
  limit?: number;
  offset?: number;
}

export interface RecordDepositInput {
  residentId: UUID;
  kind: DepositTxnKind;
  amount_paise: Paise;
  txn_date?: ISODate;
  method?: PaymentMethod | null;
  reference?: string | null;
  notes?: string | null;
  stay_id?: UUID | null;
  idempotency_key: UUID;
}

export interface ExpenseInput {
  property_id?: UUID | null;
  category?: string;
  amount_paise?: Paise;
  expense_date?: ISODate;
  payee?: string | null;
  method?: PaymentMethod | null;
  reference?: string | null;
  notes?: string | null;
  receipt_path?: string | null;
}

export interface ExpenseListParams {
  property_id?: UUID | null;
  from?: ISODate | null;
  to?: ISODate | null;
  category?: string | null;
  search?: string;
  limit?: number;
  offset?: number;
}

export interface ChargeTemplateInput {
  property_id?: UUID | null;
  name?: string;
  amount_paise?: Paise;
  frequency?: 'monthly' | 'one_time';
  apply_by_default?: boolean;
  is_active?: boolean;
}

export interface PlanInput {
  code?: string;
  name?: string;
  description?: string | null;
  price_paise?: Paise;
  billing_interval?: 'month' | 'year';
  max_properties?: number | null;
  max_residents?: number | null;
  max_staff?: number | null;
  features?: string[];
  trial_days?: number;
  is_public?: boolean;
  is_active?: boolean;
  sort_order?: number;
}

/** Removes undefined keys so partial updates only touch provided fields. */
function compact<T extends object>(value: T): Partial<T> {
  const out: Partial<T> = {};
  for (const [k, v] of Object.entries(value)) {
    if (v !== undefined) (out as Record<string, unknown>)[k] = v;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Owner / staff data service
// ---------------------------------------------------------------------------
export function createDataService(transport: RpcTransport) {
  const call = transport.call.bind(transport);

  return {
    kind: transport.kind,

    // Session & workspace -----------------------------------------------------
    myContext: () => call<UserContext>('my_context'),
    provisionWorkspace: (input: ProvisionWorkspaceInput) =>
      call<UUID>('provision_workspace', {
        p_request_id: input.requestId,
        p_business_name: input.businessName,
        p_owner_name: input.ownerName ?? null,
        p_contact_phone: input.contactPhone ?? null,
        p_contact_email: input.contactEmail ?? null,
        p_city: input.city ?? null,
        p_state: input.state ?? null,
      }),
    getWorkspace: (tenantId: UUID) => call<Workspace>('get_workspace', { p_tenant_id: tenantId }),
    updateWorkspace: (tenantId: UUID, patch: WorkspacePatch) =>
      call<void>('update_workspace', { p_tenant_id: tenantId, p_data: compact(patch) }),
    updateSettings: (tenantId: UUID, patch: TenantSettingsPatch) =>
      call<void>('update_tenant_settings', { p_tenant_id: tenantId, p_data: compact(patch) }),
    setOnboardingStep: (tenantId: UUID, step: OnboardingStep) =>
      call<void>('set_onboarding_step', { p_tenant_id: tenantId, p_step: step }),
    updateMyProfile: (patch: { full_name?: string; phone?: string | null }) =>
      call<void>('update_my_profile', { p_data: compact(patch) }),
    listPlans: () => call<Plan[]>('list_plans'),

    // Properties ---------------------------------------------------------------
    listProperties: (tenantId: UUID, includeArchived = false) =>
      call<Property[]>('list_properties', { p_tenant_id: tenantId, p_include_archived: includeArchived }),
    getProperty: (propertyId: UUID) => call<PropertyDetail>('get_property', { p_property_id: propertyId }),
    createProperty: (tenantId: UUID, input: PropertyInput) =>
      call<UUID>('save_property', { p_tenant_id: tenantId, p_property_id: null, p_data: compact(input) }),
    updateProperty: (propertyId: UUID, input: PropertyInput) =>
      call<UUID>('save_property', { p_tenant_id: null, p_property_id: propertyId, p_data: compact(input) }),
    setPropertyArchived: (propertyId: UUID, archived: boolean) =>
      call<void>('set_property_archived', { p_property_id: propertyId, p_archived: archived }),

    // Rooms & beds -------------------------------------------------------------
    listRooms: (tenantId: UUID, propertyId?: UUID | null) =>
      call<Room[]>('list_rooms', { p_tenant_id: tenantId, p_property_id: propertyId ?? null }),
    createRooms: (propertyId: UUID, rooms: RoomInput[]) =>
      call<UUID[]>('create_rooms', { p_property_id: propertyId, p_rooms: rooms.map(compact) }),
    updateRoom: (roomId: UUID, patch: RoomPatch) => call<void>('update_room', { p_room_id: roomId, p_data: compact(patch) }),
    deleteRoom: (roomId: UUID) => call<void>('delete_room', { p_room_id: roomId }),
    addBeds: (roomId: UUID, count: number) => call<void>('add_beds', { p_room_id: roomId, p_count: count }),
    updateBed: (bedId: UUID, patch: BedPatch) => call<void>('update_bed', { p_bed_id: bedId, p_data: compact(patch) }),
    deleteBed: (bedId: UUID) => call<void>('delete_bed', { p_bed_id: bedId }),

    // Residents & stays --------------------------------------------------------
    listResidents: (tenantId: UUID, params: ResidentListParams = {}) =>
      call<Paged<ResidentListItem>>('list_residents', { p_tenant_id: tenantId, p_params: compact(params) }),
    getResident: (residentId: UUID) => call<ResidentDetail>('get_resident', { p_resident_id: residentId }),
    createResident: (tenantId: UUID, input: ResidentInput) =>
      call<UUID>('save_resident', { p_tenant_id: tenantId, p_resident_id: null, p_data: compact(input) }),
    updateResident: (residentId: UUID, input: ResidentInput) =>
      call<UUID>('save_resident', { p_tenant_id: null, p_resident_id: residentId, p_data: compact(input) }),
    setResidentArchived: (residentId: UUID, archived: boolean) =>
      call<void>('set_resident_archived', { p_resident_id: residentId, p_archived: archived }),
    assignBed: ({ residentId, bedId, ...data }: AssignBedInput) =>
      call<UUID>('assign_bed', { p_resident_id: residentId, p_bed_id: bedId, p_data: compact(data) }),
    endStay: (stayId: UUID, moveOutDate: ISODate, notes?: string | null) =>
      call<void>('end_stay', { p_stay_id: stayId, p_move_out_date: moveOutDate, p_notes: notes ?? null }),
    transferBed: (stayId: UUID, newBedId: UUID, transferDate: ISODate, monthlyRentPaise?: Paise | null) =>
      call<UUID>('transfer_bed', {
        p_stay_id: stayId,
        p_new_bed_id: newBedId,
        p_transfer_date: transferDate,
        p_monthly_rent_paise: monthlyRentPaise ?? null,
      }),
    changeRent: (stayId: UUID, monthlyRentPaise: Paise, effectiveFrom: ISODate, note?: string | null) =>
      call<UUID>('change_rent', {
        p_stay_id: stayId,
        p_monthly_rent_paise: monthlyRentPaise,
        p_effective_from: effectiveFrom,
        p_note: note ?? null,
      }),
    inviteResident: (residentId: UUID, email?: string | null) =>
      call<InvitationToken>('invite_resident', { p_resident_id: residentId, p_email: email ?? null }),

    // Invoices -----------------------------------------------------------------
    listInvoices: (tenantId: UUID, params: InvoiceListParams = {}) =>
      call<InvoiceList>('list_invoices', { p_tenant_id: tenantId, p_params: compact(params) }),
    getInvoice: (invoiceId: UUID) => call<InvoiceDetail>('get_invoice', { p_invoice_id: invoiceId }),
    createInvoice: ({ residentId, ...data }: CreateInvoiceInput) =>
      call<UUID>('create_invoice', { p_resident_id: residentId, p_data: compact(data) }),
    generateRentInvoices: (tenantId: UUID, month: ISODate, propertyId?: UUID | null) =>
      call<{ created: number; skipped: number; total_paise: Paise; month: ISODate }>('generate_rent_invoices', {
        p_tenant_id: tenantId,
        p_month: month,
        p_property_id: propertyId ?? null,
      }),
    voidInvoice: (invoiceId: UUID, reason: string) => call<void>('void_invoice', { p_invoice_id: invoiceId, p_reason: reason }),

    // Payments -----------------------------------------------------------------
    listPayments: (tenantId: UUID, params: PaymentListParams = {}) =>
      call<PaymentList>('list_payments', { p_tenant_id: tenantId, p_params: compact(params) }),
    getPayment: (paymentId: UUID) => call<PaymentDetail>('get_payment', { p_payment_id: paymentId }),
    recordPayment: ({ residentId, ...data }: RecordPaymentInput) =>
      call<UUID>('record_payment', { p_resident_id: residentId, p_data: compact(data) }),
    voidPayment: (paymentId: UUID, reason: string) => call<void>('void_payment', { p_payment_id: paymentId, p_reason: reason }),

    // Deposits -----------------------------------------------------------------
    listDeposits: (tenantId: UUID, params: { search?: string; property_id?: UUID | null; filter?: 'all' | 'held' | 'due' } = {}) =>
      call<DepositOverview>('list_deposits', { p_tenant_id: tenantId, p_params: compact(params) }),
    recordDeposit: ({ residentId, ...data }: RecordDepositInput) =>
      call<UUID>('record_deposit', { p_resident_id: residentId, p_data: compact(data) }),

    // Expenses & charges -------------------------------------------------------
    listExpenses: (tenantId: UUID, params: ExpenseListParams = {}) =>
      call<ExpenseList>('list_expenses', { p_tenant_id: tenantId, p_params: compact(params) }),
    createExpense: (tenantId: UUID, input: ExpenseInput) =>
      call<UUID>('save_expense', { p_tenant_id: tenantId, p_expense_id: null, p_data: compact(input) }),
    updateExpense: (expenseId: UUID, input: ExpenseInput) =>
      call<UUID>('save_expense', { p_tenant_id: null, p_expense_id: expenseId, p_data: compact(input) }),
    deleteExpense: (expenseId: UUID) => call<void>('delete_expense', { p_expense_id: expenseId }),
    listChargeTemplates: (tenantId: UUID) => call<ChargeTemplate[]>('list_charge_templates', { p_tenant_id: tenantId }),
    saveChargeTemplate: (tenantId: UUID, chargeId: UUID | null, input: ChargeTemplateInput) =>
      call<UUID>('save_charge_template', { p_tenant_id: tenantId, p_charge_id: chargeId, p_data: compact(input) }),
    deleteChargeTemplate: (chargeId: UUID) => call<void>('delete_charge_template', { p_charge_id: chargeId }),

    // Analytics ----------------------------------------------------------------
    dashboard: (tenantId: UUID, propertyId?: UUID | null, month?: ISODate | null) =>
      call<DashboardSummary>('dashboard_summary', {
        p_tenant_id: tenantId,
        p_property_id: propertyId ?? null,
        p_month: month ?? null,
      }),
    financialReport: (tenantId: UUID, from: ISODate, to: ISODate, propertyId?: UUID | null) =>
      call<FinancialReport>('financial_report', {
        p_tenant_id: tenantId,
        p_from: from,
        p_to: to,
        p_property_id: propertyId ?? null,
      }),

    // Team ---------------------------------------------------------------------
    listMembers: (tenantId: UUID) => call<TeamOverview>('list_members', { p_tenant_id: tenantId }),
    inviteMember: (tenantId: UUID, email: string, role: Exclude<TenantRole, 'owner'>) =>
      call<InvitationToken>('invite_member', { p_tenant_id: tenantId, p_email: email, p_role: role }),
    revokeInvitation: (invitationId: UUID) => call<void>('revoke_invitation', { p_invitation_id: invitationId }),
    acceptInvitation: (token: string) =>
      call<{ tenant_id: UUID; kind: 'member' | 'resident' }>('accept_invitation', { p_token: token }),
    updateMember: (membershipId: UUID, role: TenantRole, status: 'active' | 'suspended') =>
      call<void>('update_member', { p_membership_id: membershipId, p_role: role, p_status: status }),
    removeMember: (membershipId: UUID) => call<void>('remove_member', { p_membership_id: membershipId }),
    listAuditLogs: (tenantId: UUID, limit = 50, beforeId?: number | null) =>
      call<AuditLogEntry[]>('list_audit_logs', { p_tenant_id: tenantId, p_limit: limit, p_before_id: beforeId ?? null }),
  };
}

export type DataService = ReturnType<typeof createDataService>;

// ---------------------------------------------------------------------------
// Platform admin service
// ---------------------------------------------------------------------------
export function createAdminService(transport: RpcTransport) {
  const call = transport.call.bind(transport);
  return {
    kind: transport.kind,
    amIPlatformAdmin: () => call<boolean>('am_i_platform_admin'),
    overview: () => call<AdminOverview>('admin_overview'),
    listTenants: (params: { search?: string; status?: TenantStatus | null; plan_id?: UUID | null; limit?: number; offset?: number } = {}) =>
      call<Paged<AdminTenantRow>>('admin_list_tenants', { p_params: compact(params) }),
    getTenant: (tenantId: UUID) => call<AdminTenantDetail>('admin_get_tenant', { p_tenant_id: tenantId }),
    setTenantStatus: (tenantId: UUID, status: TenantStatus, reason: string) =>
      call<void>('admin_set_tenant_status', { p_tenant_id: tenantId, p_status: status, p_reason: reason }),
    listPlans: () => call<AdminPlan[]>('admin_list_plans'),
    savePlan: (planId: UUID | null, input: PlanInput) =>
      call<UUID>('admin_save_plan', { p_plan_id: planId, p_data: compact(input) }),
    assignPlan: (tenantId: UUID, planId: UUID, status: SubscriptionStatus, trialEndsAt?: string | null) =>
      call<void>('admin_assign_plan', {
        p_tenant_id: tenantId,
        p_plan_id: planId,
        p_status: status,
        p_trial_ends_at: trialEndsAt ?? null,
      }),
    listAudit: (limit = 50, beforeId?: number | null) =>
      call<AdminAuditEntry[]>('admin_list_audit', { p_limit: limit, p_before_id: beforeId ?? null }),
    getSettings: () => call<PlatformSettings>('admin_get_settings'),
    updateSettings: (patch: Partial<Pick<PlatformSettings, 'default_plan_id' | 'signup_enabled' | 'support_email'>>) =>
      call<void>('admin_update_settings', { p_data: compact(patch) }),
  };
}

export type AdminService = ReturnType<typeof createAdminService>;
