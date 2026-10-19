import { useDeferredValue, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router';
import { useQuery } from '@tanstack/react-query';
import { toast } from 'sonner';
import { ArrowLeft, Building2, Lock } from 'lucide-react';
import { queryKeys, useAdminMutation, useBackend } from '@pg/api-client/react';
import { ROLE_LABELS, SUBSCRIPTION_STATUS_LABELS, TENANT_STATUS_LABELS, formatDate, formatDateTime, formatINR, type SubscriptionStatus, type TenantStatus } from '@pg/shared';
import { Button } from '@pg/ui-web/ui/button';
import { Select, Textarea } from '@pg/ui-web/ui/form-controls';
import { Badge, Card, CardBody, CardHeader, Progress, Skeleton } from '@pg/ui-web/ui/surfaces';
import { Dialog, DialogContent } from '@pg/ui-web/ui/overlays';
import { Table, TBody, TD, TH, THead, TR } from '@pg/ui-web/ui/table';
import { EmptyState, ErrorState, Field, InlineError, KeyValue, PageHeader, Pagination, SearchInput, TableSkeleton, TenantStatusBadge } from '@pg/ui-web/common';

const PAGE = 25;

export function TenantsPage() {
  const { admin } = useBackend();
  const navigate = useNavigate();
  const [search, setSearch] = useState('');
  const deferred = useDeferredValue(search);
  const [status, setStatus] = useState<TenantStatus | ''>('');
  const [offset, setOffset] = useState(0);
  const params = { search: deferred.trim() || undefined, status: status || null, limit: PAGE, offset };
  const q = useQuery({ queryKey: queryKeys.admin.tenants(params), queryFn: () => admin.listTenants(params) });

  return (
    <div>
      <PageHeader title="Tenants" description="Every business that has signed up. Each one provisioned itself through self-service onboarding." />
      <Card>
        <div className="flex flex-col gap-3 border-b border-gray-100 p-4 sm:flex-row sm:items-center sm:justify-between">
          <SearchInput value={search} onChange={(v) => { setSearch(v); setOffset(0); }} placeholder="Business, email or city" />
          <Select value={status} onChange={(e) => { setStatus(e.target.value as TenantStatus | ''); setOffset(0); }} aria-label="Status" className="sm:w-44">
            <option value="">All statuses</option>
            {(Object.keys(TENANT_STATUS_LABELS) as TenantStatus[]).map((s) => (
              <option key={s} value={s}>
                {TENANT_STATUS_LABELS[s]}
              </option>
            ))}
          </Select>
        </div>
        {q.isError ? (
          <ErrorState error={q.error} onRetry={() => void q.refetch()} />
        ) : q.isPending ? (
          <TableSkeleton />
        ) : q.data.rows.length === 0 ? (
          <EmptyState icon={Building2} title="No tenants found" />
        ) : (
          <>
            <Table>
              <THead>
                <TR>
                  <TH>Business</TH>
                  <TH>Plan</TH>
                  <TH align="right">Properties</TH>
                  <TH align="right">Residents</TH>
                  <TH align="right">Team</TH>
                  <TH>Signed up</TH>
                  <TH>Status</TH>
                </TR>
              </THead>
              <TBody>
                {q.data.rows.map((t) => (
                  <TR key={t.id} className="cursor-pointer hover:bg-gray-25" onClick={() => navigate(`/tenants/${t.id}`)}>
                    <TD>
                      <Link to={`/tenants/${t.id}`} className="font-medium text-gray-900 hover:underline" onClick={(e) => e.stopPropagation()}>
                        {t.name}
                      </Link>
                      <span className="block text-xs text-gray-500">
                        {t.contact_email ?? '—'} · {t.city ?? '—'}
                        {!t.onboarding_completed_at && ` · setting up (${t.onboarding_step})`}
                      </span>
                    </TD>
                    <TD>
                      {t.plan_name ?? '—'}
                      {t.subscription_status && <span className="block text-xs text-gray-500">{SUBSCRIPTION_STATUS_LABELS[t.subscription_status]}</span>}
                    </TD>
                    <TD numeric>{t.property_count}</TD>
                    <TD numeric>{t.resident_count}</TD>
                    <TD numeric>{t.member_count}</TD>
                    <TD>{formatDate(t.created_at)}</TD>
                    <TD>
                      <TenantStatusBadge status={t.status} />
                    </TD>
                  </TR>
                ))}
              </TBody>
            </Table>
            <Pagination total={q.data.total} limit={PAGE} offset={offset} onChange={setOffset} />
          </>
        )}
      </Card>
    </div>
  );
}

function Usage({ label, used, limit }: { label: string; used: number; limit: number | null | undefined }) {
  const unlimited = limit === null || limit === undefined;
  return (
    <div>
      <div className="mb-1 flex justify-between text-[13px]">
        <span className="text-gray-600">{label}</span>
        <span className="tabular text-gray-900">
          {used}
          {unlimited ? ' · unlimited' : ` / ${limit}`}
        </span>
      </div>
      {!unlimited && <Progress value={(used / Math.max(limit, 1)) * 100} tone={used >= limit ? 'danger' : 'accent'} />}
    </div>
  );
}

export function TenantDetailPage() {
  const { tenantId = '' } = useParams();
  const { admin } = useBackend();
  const q = useQuery({ queryKey: queryKeys.admin.tenant(tenantId), queryFn: () => admin.getTenant(tenantId) });
  const plans = useQuery({ queryKey: queryKeys.admin.plans(), queryFn: () => admin.listPlans() });
  const [statusDialog, setStatusDialog] = useState<TenantStatus | null>(null);
  const [reason, setReason] = useState('');
  const [planDialog, setPlanDialog] = useState(false);
  const [planId, setPlanId] = useState('');
  const [subStatus, setSubStatus] = useState<SubscriptionStatus>('active');
  const setStatus = useAdminMutation((s: TenantStatus) => admin.setTenantStatus(tenantId, s, reason));
  const assign = useAdminMutation(() => admin.assignPlan(tenantId, planId, subStatus));

  if (q.isError) return <ErrorState error={q.error} onRetry={() => void q.refetch()} />;
  if (q.isPending) return <Skeleton className="h-96 rounded-xl" />;
  const { tenant, plan, subscription, members, usage, admin_activity } = q.data;

  return (
    <div>
      <PageHeader
        breadcrumb={
          <Link to="/tenants" className="inline-flex items-center gap-1 hover:text-gray-900">
            <ArrowLeft className="size-3.5" /> Tenants
          </Link>
        }
        title={
          <span className="flex items-center gap-3">
            {tenant.name} <TenantStatusBadge status={tenant.status} />
          </span>
        }
        description={`Signed up ${formatDate(tenant.created_at)}${tenant.onboarding_completed_at ? ` · setup completed ${formatDate(tenant.onboarding_completed_at)}` : ' · onboarding in progress'}`}
        actions={
          <>
            <Button variant="secondary" onClick={() => { setPlanId(plan?.id ?? ''); setSubStatus(subscription?.status ?? 'active'); setPlanDialog(true); }}>
              Change plan
            </Button>
            {tenant.status === 'suspended' || tenant.status === 'cancelled' ? (
              <Button onClick={() => { setReason(''); setStatusDialog('active'); }}>Reactivate</Button>
            ) : (
              <Button variant="danger" onClick={() => { setReason(''); setStatusDialog('suspended'); }}>
                Suspend
              </Button>
            )}
          </>
        }
      />
      {tenant.status_reason && (
        <p className="mb-4 rounded-lg border border-gray-200 bg-white px-4 py-3 text-[13px] text-gray-600">Last status change reason: {tenant.status_reason}</p>
      )}
      <div className="grid gap-6 lg:grid-cols-3">
        <Card>
          <CardHeader title="Business" />
          <CardBody>
            <dl className="grid grid-cols-2 gap-4">
              <KeyValue label="Contact">{tenant.contact_name}</KeyValue>
              <KeyValue label="Phone">{tenant.contact_phone}</KeyValue>
              <KeyValue label="Email" className="col-span-2">
                {tenant.contact_email}
              </KeyValue>
              <KeyValue label="City">{tenant.city}</KeyValue>
              <KeyValue label="State">{tenant.state}</KeyValue>
            </dl>
          </CardBody>
        </Card>
        <Card>
          <CardHeader title="Subscription" />
          <CardBody className="space-y-4">
            <div>
              <p className="text-lg font-semibold text-gray-900">{plan?.name ?? '—'}</p>
              <p className="text-[13px] text-gray-500">
                {plan ? (plan.price_paise ? `${formatINR(plan.price_paise)} / ${plan.billing_interval}` : 'Free') : ''}
                {subscription ? ` · ${SUBSCRIPTION_STATUS_LABELS[subscription.status]}` : ''}
                {subscription?.trial_ends_at && subscription.status === 'trialing' ? ` · trial ends ${formatDate(subscription.trial_ends_at)}` : ''}
              </p>
            </div>
            <Usage label="Properties" used={usage.properties} limit={plan?.max_properties} />
            <Usage label="Residents" used={usage.residents} limit={plan?.max_residents} />
            <Usage label="Team members" used={Math.max(members.filter((m) => m.role !== 'owner').length, 0)} limit={plan?.max_staff} />
          </CardBody>
        </Card>
        <Card>
          <CardHeader title="Usage" description="Counts only" />
          <CardBody className="grid grid-cols-2 gap-4">
            {[
              ['Rooms', usage.rooms],
              ['Beds', usage.beds],
              ['Active stays', usage.active_stays],
              ['Bills issued', usage.invoices],
              ['Payments recorded', usage.payments],
            ].map(([l, v]) => (
              <KeyValue key={l} label={String(l)}>
                <span className="tabular">{v}</span>
              </KeyValue>
            ))}
          </CardBody>
        </Card>
      </div>
      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <Card>
          <CardHeader title="Members" />
          <ul className="divide-y divide-gray-100">
            {members.map((m, i) => (
              <li key={i} className="flex items-center justify-between px-5 py-3 text-[13px]">
                <span>
                  <span className="block font-medium text-gray-900">{m.full_name ?? '—'}</span>
                  <span className="text-xs text-gray-500">{m.email}</span>
                </span>
                <Badge>{ROLE_LABELS[m.role]}</Badge>
              </li>
            ))}
          </ul>
        </Card>
        <Card>
          <CardHeader title="Administrative history" />
          {admin_activity.length === 0 ? (
            <p className="px-5 py-4 text-[13px] text-gray-500">No administrative actions.</p>
          ) : (
            <ul className="divide-y divide-gray-100">
              {admin_activity.map((a) => (
                <li key={a.id} className="px-5 py-3 text-[13px]">
                  <p className="text-gray-900">{a.action}</p>
                  <p className="text-xs text-gray-500">
                    {a.actor_name ?? 'System'} · {formatDateTime(a.created_at)}
                    {typeof a.details.reason === 'string' ? ` · “${a.details.reason}”` : ''}
                  </p>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
      <p className="mt-6 flex items-center gap-2 text-xs text-gray-500">
        <Lock className="size-3.5" /> Resident details, bills and payments of this business are not accessible to platform admins.
      </p>

      <Dialog open={!!statusDialog} onOpenChange={(o) => !o && setStatusDialog(null)}>
        <DialogContent
          size="sm"
          title={statusDialog === 'suspended' ? `Suspend ${tenant.name}?` : `Reactivate ${tenant.name}?`}
          description={statusDialog === 'suspended' ? 'Members can still sign in and read data, but every change is blocked until reactivated.' : 'Restores full access for this business.'}
          footer={
            <>
              <Button variant="secondary" onClick={() => setStatusDialog(null)}>
                Cancel
              </Button>
              <Button
                variant={statusDialog === 'suspended' ? 'danger' : 'primary'}
                loading={setStatus.isPending}
                onClick={() => setStatus.mutate(statusDialog!, { onSuccess: () => { toast.success('Status updated'); setStatusDialog(null); } })}
              >
                Confirm
              </Button>
            </>
          }
        >
          <div className="space-y-3">
            <Field label="Reason (recorded in the audit log)" required htmlFor="st-reason">
              <Textarea id="st-reason" rows={2} value={reason} onChange={(e) => setReason(e.target.value)} />
            </Field>
            <InlineError error={setStatus.error} />
          </div>
        </DialogContent>
      </Dialog>

      <Dialog open={planDialog} onOpenChange={setPlanDialog}>
        <DialogContent
          size="sm"
          title="Change plan"
          description="Manual assignment. No payment is taken — subscription billing is not integrated yet."
          footer={
            <>
              <Button variant="secondary" onClick={() => setPlanDialog(false)}>
                Cancel
              </Button>
              <Button loading={assign.isPending} disabled={!planId} onClick={() => assign.mutate(undefined, { onSuccess: () => { toast.success('Plan updated'); setPlanDialog(false); } })}>
                Save
              </Button>
            </>
          }
        >
          <div className="space-y-4">
            <Field label="Plan" htmlFor="pl-plan">
              <Select id="pl-plan" value={planId} onChange={(e) => setPlanId(e.target.value)}>
                <option value="">Choose a plan</option>
                {(plans.data ?? []).map((p) => (
                  <option key={p.id} value={p.id}>
                    {p.name} {p.is_active ? '' : '(inactive)'}
                  </option>
                ))}
              </Select>
            </Field>
            <Field label="Subscription status" htmlFor="pl-status">
              <Select id="pl-status" value={subStatus} onChange={(e) => setSubStatus(e.target.value as SubscriptionStatus)}>
                {(Object.keys(SUBSCRIPTION_STATUS_LABELS) as SubscriptionStatus[]).map((s) => (
                  <option key={s} value={s}>
                    {SUBSCRIPTION_STATUS_LABELS[s]}
                  </option>
                ))}
              </Select>
            </Field>
            <InlineError error={assign.error} />
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
