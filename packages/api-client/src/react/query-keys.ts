/**
 * Every query for tenant-owned data is keyed under ['tenant', tenantId, ...].
 * Switching workspaces therefore never reuses another tenant's cache, and a
 * mutation can invalidate everything for one tenant with a single prefix.
 */
export const queryKeys = {
  me: () => ['me'] as const,
  plans: () => ['plans'] as const,
  tenant: (tenantId: string) => ['tenant', tenantId] as const,
  workspace: (tenantId: string) => ['tenant', tenantId, 'workspace'] as const,
  properties: (tenantId: string, includeArchived = false) => ['tenant', tenantId, 'properties', { includeArchived }] as const,
  property: (tenantId: string, propertyId: string) => ['tenant', tenantId, 'property', propertyId] as const,
  rooms: (tenantId: string, propertyId?: string | null) => ['tenant', tenantId, 'rooms', propertyId ?? 'all'] as const,
  residents: (tenantId: string, params: object = {}) => ['tenant', tenantId, 'residents', params] as const,
  resident: (tenantId: string, residentId: string) => ['tenant', tenantId, 'resident', residentId] as const,
  invoices: (tenantId: string, params: object = {}) => ['tenant', tenantId, 'invoices', params] as const,
  invoice: (tenantId: string, invoiceId: string) => ['tenant', tenantId, 'invoice', invoiceId] as const,
  payments: (tenantId: string, params: object = {}) => ['tenant', tenantId, 'payments', params] as const,
  payment: (tenantId: string, paymentId: string) => ['tenant', tenantId, 'payment', paymentId] as const,
  deposits: (tenantId: string, params: object = {}) => ['tenant', tenantId, 'deposits', params] as const,
  expenses: (tenantId: string, params: object = {}) => ['tenant', tenantId, 'expenses', params] as const,
  charges: (tenantId: string) => ['tenant', tenantId, 'charges'] as const,
  dashboard: (tenantId: string, propertyId: string | null | undefined, month: string | null | undefined) =>
    ['tenant', tenantId, 'dashboard', propertyId ?? 'all', month ?? 'current'] as const,
  report: (tenantId: string, params: object) => ['tenant', tenantId, 'report', params] as const,
  members: (tenantId: string) => ['tenant', tenantId, 'members'] as const,
  audit: (tenantId: string) => ['tenant', tenantId, 'audit'] as const,
  admin: {
    all: () => ['admin'] as const,
    overview: () => ['admin', 'overview'] as const,
    tenants: (params: object) => ['admin', 'tenants', params] as const,
    tenant: (tenantId: string) => ['admin', 'tenant', tenantId] as const,
    plans: () => ['admin', 'plans'] as const,
    audit: () => ['admin', 'audit'] as const,
    settings: () => ['admin', 'settings'] as const,
  },
};
