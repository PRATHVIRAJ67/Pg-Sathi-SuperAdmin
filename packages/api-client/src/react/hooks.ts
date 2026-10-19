import {
  keepPreviousData,
  useMutation,
  useQuery,
  useQueryClient,
  type UseMutationOptions,
} from '@tanstack/react-query';
import type { ISODate, UUID } from '@pg/shared';
import { toAppError, type AppError } from '../errors';
import type { ExpenseListParams, InvoiceListParams, PaymentListParams, ResidentListParams } from '../service';
import { useBackend } from './context';
import { queryKeys } from './query-keys';

const enabled = (...values: unknown[]) => values.every((v) => v !== undefined && v !== null && v !== '');

export function useMyContext(options: { enabled?: boolean } = {}) {
  const { data } = useBackend();
  return useQuery({ queryKey: queryKeys.me(), queryFn: () => data.myContext(), enabled: options.enabled ?? true });
}

export function usePlans() {
  const { data } = useBackend();
  return useQuery({ queryKey: queryKeys.plans(), queryFn: () => data.listPlans(), staleTime: 5 * 60_000 });
}

export function useWorkspace(tenantId: UUID | null | undefined) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.workspace(tenantId ?? ''),
    queryFn: () => data.getWorkspace(tenantId!),
    enabled: enabled(tenantId),
  });
}

export function useProperties(tenantId: UUID | null | undefined, includeArchived = false) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.properties(tenantId ?? '', includeArchived),
    queryFn: () => data.listProperties(tenantId!, includeArchived),
    enabled: enabled(tenantId),
  });
}

export function useProperty(tenantId: UUID | null | undefined, propertyId: UUID | null | undefined) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.property(tenantId ?? '', propertyId ?? ''),
    queryFn: () => data.getProperty(propertyId!),
    enabled: enabled(tenantId, propertyId),
  });
}

export function useRooms(tenantId: UUID | null | undefined, propertyId?: UUID | null) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.rooms(tenantId ?? '', propertyId),
    queryFn: () => data.listRooms(tenantId!, propertyId),
    enabled: enabled(tenantId),
  });
}

export function useResidents(tenantId: UUID | null | undefined, params: ResidentListParams = {}) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.residents(tenantId ?? '', params),
    queryFn: () => data.listResidents(tenantId!, params),
    enabled: enabled(tenantId),
    placeholderData: keepPreviousData,
  });
}

export function useResident(tenantId: UUID | null | undefined, residentId: UUID | null | undefined) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.resident(tenantId ?? '', residentId ?? ''),
    queryFn: () => data.getResident(residentId!),
    enabled: enabled(tenantId, residentId),
  });
}

export function useInvoices(tenantId: UUID | null | undefined, params: InvoiceListParams = {}, options: { enabled?: boolean } = {}) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.invoices(tenantId ?? '', params),
    queryFn: () => data.listInvoices(tenantId!, params),
    enabled: enabled(tenantId) && (options.enabled ?? true),
    placeholderData: keepPreviousData,
  });
}

export function useInvoice(tenantId: UUID | null | undefined, invoiceId: UUID | null | undefined) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.invoice(tenantId ?? '', invoiceId ?? ''),
    queryFn: () => data.getInvoice(invoiceId!),
    enabled: enabled(tenantId, invoiceId),
  });
}

export function usePayments(tenantId: UUID | null | undefined, params: PaymentListParams = {}, options: { enabled?: boolean } = {}) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.payments(tenantId ?? '', params),
    queryFn: () => data.listPayments(tenantId!, params),
    enabled: enabled(tenantId) && (options.enabled ?? true),
    placeholderData: keepPreviousData,
  });
}

export function usePayment(tenantId: UUID | null | undefined, paymentId: UUID | null | undefined) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.payment(tenantId ?? '', paymentId ?? ''),
    queryFn: () => data.getPayment(paymentId!),
    enabled: enabled(tenantId, paymentId),
  });
}

export function useDeposits(
  tenantId: UUID | null | undefined,
  params: { search?: string; property_id?: UUID | null; filter?: 'all' | 'held' | 'due' } = {},
) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.deposits(tenantId ?? '', params),
    queryFn: () => data.listDeposits(tenantId!, params),
    enabled: enabled(tenantId),
    placeholderData: keepPreviousData,
  });
}

export function useExpenses(tenantId: UUID | null | undefined, params: ExpenseListParams = {}) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.expenses(tenantId ?? '', params),
    queryFn: () => data.listExpenses(tenantId!, params),
    enabled: enabled(tenantId),
    placeholderData: keepPreviousData,
  });
}

export function useChargeTemplates(tenantId: UUID | null | undefined) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.charges(tenantId ?? ''),
    queryFn: () => data.listChargeTemplates(tenantId!),
    enabled: enabled(tenantId),
  });
}

export function useDashboard(tenantId: UUID | null | undefined, propertyId?: UUID | null, month?: ISODate | null) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.dashboard(tenantId ?? '', propertyId, month),
    queryFn: () => data.dashboard(tenantId!, propertyId, month),
    enabled: enabled(tenantId),
    placeholderData: keepPreviousData,
  });
}

export function useFinancialReport(
  tenantId: UUID | null | undefined,
  params: { from: ISODate; to: ISODate; propertyId?: UUID | null },
  options: { enabled?: boolean } = {},
) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.report(tenantId ?? '', params),
    queryFn: () => data.financialReport(tenantId!, params.from, params.to, params.propertyId),
    enabled: enabled(tenantId) && (options.enabled ?? true),
    placeholderData: keepPreviousData,
  });
}

export function useMembers(tenantId: UUID | null | undefined) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.members(tenantId ?? ''),
    queryFn: () => data.listMembers(tenantId!),
    enabled: enabled(tenantId),
  });
}

export function useAuditLogs(tenantId: UUID | null | undefined, options: { enabled?: boolean } = {}) {
  const { data } = useBackend();
  return useQuery({
    queryKey: queryKeys.audit(tenantId ?? ''),
    queryFn: () => data.listAuditLogs(tenantId!, 100),
    enabled: enabled(tenantId) && (options.enabled ?? true),
  });
}

/**
 * Mutation that refreshes everything cached for the tenant afterwards. Money
 * moves through many views at once (dashboard, ledgers, balances), so a
 * tenant-wide invalidation is the simplest correct choice.
 */
export function useTenantMutation<TData, TVariables = void>(
  tenantId: UUID | null | undefined,
  mutationFn: (variables: TVariables) => Promise<TData>,
  options: Omit<UseMutationOptions<TData, AppError, TVariables>, 'mutationFn'> = {},
) {
  const queryClient = useQueryClient();
  return useMutation<TData, AppError, TVariables>({
    ...options,
    mutationFn: async (variables) => {
      try {
        return await mutationFn(variables);
      } catch (error) {
        throw toAppError(error);
      }
    },
    onSuccess: async (result, variables, context, mutation) => {
      await Promise.all([
        tenantId ? queryClient.invalidateQueries({ queryKey: queryKeys.tenant(tenantId) }) : Promise.resolve(),
        queryClient.invalidateQueries({ queryKey: queryKeys.me() }),
      ]);
      await options.onSuccess?.(result, variables, context, mutation);
    },
  });
}

/** Platform-admin mutation: refreshes all admin queries afterwards. */
export function useAdminMutation<TData, TVariables = void>(
  mutationFn: (variables: TVariables) => Promise<TData>,
  options: Omit<UseMutationOptions<TData, AppError, TVariables>, 'mutationFn'> = {},
) {
  const queryClient = useQueryClient();
  return useMutation<TData, AppError, TVariables>({
    ...options,
    mutationFn: async (variables) => {
      try {
        return await mutationFn(variables);
      } catch (error) {
        throw toAppError(error);
      }
    },
    onSuccess: async (result, variables, context, mutation) => {
      await queryClient.invalidateQueries({ queryKey: queryKeys.admin.all() });
      await options.onSuccess?.(result, variables, context, mutation);
    },
  });
}
