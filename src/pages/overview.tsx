import { Link } from 'react-router';
import { useQuery } from '@tanstack/react-query';
import { BedDouble, Building2, Clock, Hourglass, UserPlus, Users } from 'lucide-react';
import { useBackend, queryKeys } from '@pg/api-client/react';
import { chart } from '@pg/design-tokens';
import { formatDate, formatMonthShort } from '@pg/shared';
import { Card, CardBody, CardHeader } from '@pg/ui-web/ui/surfaces';
import { ErrorState, PageHeader, StatCard, TenantStatusBadge } from '@pg/ui-web/common';

export function OverviewPage() {
  const { admin } = useBackend();
  const q = useQuery({ queryKey: queryKeys.admin.overview(), queryFn: () => admin.overview() });
  if (q.isError) return <ErrorState error={q.error} onRetry={() => void q.refetch()} />;
  const d = q.data;
  const maxSignups = Math.max(1, ...(d?.signups_by_month.map((s) => s.count) ?? [1]));
  const totalSubs = d?.subscriptions_by_plan.reduce((n, p) => n + p.count, 0) ?? 0;

  return (
    <div>
      <PageHeader title="Platform overview" description="Aggregate figures only — resident and financial records stay private to each business." />
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard label="Businesses" icon={Building2} loading={!d} value={d?.tenants_total ?? 0} footer={d ? `${d.tenants_by_status.active ?? 0} active · ${d.tenants_by_status.trial ?? 0} trial · ${d.tenants_by_status.suspended ?? 0} suspended` : null} />
        <StatCard label="New in last 30 days" icon={UserPlus} tone="accent" loading={!d} value={d?.new_tenants_30d ?? 0} />
        <StatCard label="Onboarding incomplete" icon={Hourglass} tone="warning" loading={!d} value={d?.onboarding_incomplete ?? 0} footer="Signed up but not finished setup" />
        <StatCard label="Trials ending in 7 days" icon={Clock} loading={!d} value={d?.trials_ending_7d ?? 0} />
      </div>
      <div className="mt-6 grid gap-6 xl:grid-cols-3">
        <Card className="min-w-0 xl:col-span-2">
          <CardHeader title="New businesses per month" description="Last 6 months" />
          <CardBody>
            <div className="flex h-48 items-end gap-3" role="img" aria-label="New businesses per month">
              {d?.signups_by_month.map((s) => (
                <div key={s.month} className="group flex flex-1 flex-col items-center gap-2" title={`${s.count} sign-ups`}>
                  <span className="tabular text-xs text-gray-700">{s.count}</span>
                  <div className="w-full max-w-10 rounded-t" style={{ height: `${(s.count / maxSignups) * 140 + 2}px`, background: chart.billed }} />
                  <span className="text-xs text-gray-500">{formatMonthShort(s.month)}</span>
                </div>
              ))}
            </div>
          </CardBody>
        </Card>
        <Card>
          <CardHeader title="Subscriptions by plan" />
          <CardBody className="space-y-3">
            {d?.subscriptions_by_plan.map((p) => (
              <div key={p.plan_id}>
                <div className="mb-1 flex justify-between text-[13px]">
                  <span className="text-gray-700">{p.name}</span>
                  <span className="tabular text-gray-900">{p.count}</span>
                </div>
                <div className="h-2 rounded-full bg-gray-100">
                  <div className="h-2 rounded-full bg-accent-600" style={{ width: `${totalSubs ? (p.count / totalSubs) * 100 : 0}%` }} />
                </div>
              </div>
            ))}
          </CardBody>
        </Card>
      </div>
      <div className="mt-6 grid gap-6 xl:grid-cols-3">
        <Card className="min-w-0 xl:col-span-2">
          <CardHeader title="Recent sign-ups" action={<Link to="/tenants" className="text-[13px] font-medium text-accent-700 hover:underline">All tenants</Link>} />
          <ul className="divide-y divide-gray-100">
            {d?.recent_tenants.map((t) => (
              <li key={t.id}>
                <Link to={`/tenants/${t.id}`} className="flex items-center gap-3 px-5 py-3 text-[13px] hover:bg-gray-25">
                  <span className="min-w-0 flex-1">
                    <span className="block truncate font-medium text-gray-900">{t.name}</span>
                    <span className="text-xs text-gray-500">
                      {t.city ?? '—'} · {t.plan_name ?? 'No plan'} · {t.onboarding_completed_at ? 'Setup complete' : 'Setting up'}
                    </span>
                  </span>
                  <TenantStatusBadge status={t.status} />
                  <span className="w-24 text-right text-xs text-gray-500">{formatDate(t.created_at)}</span>
                </Link>
              </li>
            ))}
          </ul>
        </Card>
        <Card>
          <CardHeader title="Platform usage" />
          <CardBody className="grid grid-cols-2 gap-4">
            {[
              { label: 'Properties', value: d?.usage.properties, icon: Building2 },
              { label: 'Beds', value: d?.usage.beds, icon: BedDouble },
              { label: 'Active stays', value: d?.usage.active_stays, icon: BedDouble },
              { label: 'Residents', value: d?.usage.residents, icon: Users },
              { label: 'Team members', value: d?.usage.team_members, icon: Users },
            ].map((u) => (
              <div key={u.label}>
                <p className="text-xs text-gray-500">{u.label}</p>
                <p className="tabular text-lg font-semibold text-gray-900">{u.value ?? '—'}</p>
              </div>
            ))}
          </CardBody>
        </Card>
      </div>
    </div>
  );
}
