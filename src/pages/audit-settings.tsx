import { useEffect, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Activity } from 'lucide-react';
import { queryKeys, useAdminMutation, useBackend } from '@pg/api-client/react';
import { formatDateTime } from '@pg/shared';
import { Button } from '@pg/ui-web/ui/button';
import { Input, Select, Switch } from '@pg/ui-web/ui/form-controls';
import { Card, CardBody, CardHeader, Skeleton } from '@pg/ui-web/ui/surfaces';
import { Table, TBody, TD, TH, THead, TR } from '@pg/ui-web/ui/table';
import { EmptyState, ErrorState, Field, FormSection, InlineError, PageHeader, TableSkeleton } from '@pg/ui-web/common';

export function AuditPage() {
  const { admin } = useBackend();
  const q = useQuery({ queryKey: queryKeys.admin.audit(), queryFn: () => admin.listAudit(200) });
  return (
    <div>
      <PageHeader title="Audit log" description="Platform administration and workspace lifecycle events (latest 200)." />
      <Card>
        {q.isError ? (
          <ErrorState error={q.error} />
        ) : q.isPending ? (
          <TableSkeleton />
        ) : q.data.length === 0 ? (
          <EmptyState icon={Activity} title="No events yet" />
        ) : (
          <Table>
            <THead>
              <TR>
                <TH>When</TH>
                <TH>Action</TH>
                <TH>Tenant</TH>
                <TH>Actor</TH>
                <TH>Details</TH>
              </TR>
            </THead>
            <TBody>
              {q.data.map((a) => (
                <TR key={a.id}>
                  <TD className="whitespace-nowrap">{formatDateTime(a.created_at)}</TD>
                  <TD className="font-medium text-gray-900">{a.action}</TD>
                  <TD>{a.tenant_name ?? 'Platform'}</TD>
                  <TD>{a.actor_name ?? a.actor_email ?? 'System'}</TD>
                  <TD className="max-w-sm truncate font-mono text-xs text-gray-500">{JSON.stringify(a.details)}</TD>
                </TR>
              ))}
            </TBody>
          </Table>
        )}
      </Card>
    </div>
  );
}

export function PlatformSettingsPage() {
  const { admin } = useBackend();
  const settings = useQuery({ queryKey: queryKeys.admin.settings(), queryFn: () => admin.getSettings() });
  const plans = useQuery({ queryKey: queryKeys.admin.plans(), queryFn: () => admin.listPlans() });
  const [signup, setSignup] = useState(true);
  const [plan, setPlan] = useState('');
  const [email, setEmail] = useState('');
  useEffect(() => {
    if (settings.data) {
      setSignup(settings.data.signup_enabled);
      setPlan(settings.data.default_plan_id ?? '');
      setEmail(settings.data.support_email ?? '');
    }
  }, [settings.data]);
  const save = useAdminMutation(() => admin.updateSettings({ signup_enabled: signup, default_plan_id: plan || null, support_email: email.trim() || null }));

  if (settings.isError) return <ErrorState error={settings.error} />;
  if (!settings.data) return <Skeleton className="h-64 rounded-xl" />;
  return (
    <div>
      <PageHeader title="Platform settings" />
      <Card>
        <CardHeader title="Sign-ups" />
        <CardBody>
          <FormSection title="Self-service onboarding" description="When paused, new accounts can sign up but cannot create a workspace.">
            <label className="flex items-center gap-3">
              <Switch checked={signup} onCheckedChange={setSignup} />
              <span className="text-[13px] text-gray-700">Allow new businesses to create workspaces</span>
            </label>
          </FormSection>
          <FormSection title="Default plan" description="Assigned automatically to new workspaces during provisioning.">
            <Select value={plan} onChange={(e) => setPlan(e.target.value)} aria-label="Default plan" className="max-w-xs">
              {(plans.data ?? []).filter((p) => p.is_active).map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </Select>
          </FormSection>
          <FormSection title="Support contact">
            <Field label="Support email" htmlFor="ps-email">
              <Input id="ps-email" type="email" value={email} onChange={(e) => setEmail(e.target.value)} className="max-w-sm" />
            </Field>
          </FormSection>
          <InlineError error={save.error} />
          <Button loading={save.isPending} onClick={() => save.mutate(undefined, { onSuccess: () => toast.success('Settings saved') })}>
            Save settings
          </Button>
        </CardBody>
      </Card>
    </div>
  );
}
