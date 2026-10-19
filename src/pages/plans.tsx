import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Plus } from 'lucide-react';
import { queryKeys, useAdminMutation, useBackend } from '@pg/api-client/react';
import { formatINR, paiseToRupeesInput, rupeesToPaise, type AdminPlan } from '@pg/shared';
import { planSchema, type PlanValues } from '@pg/validation';
import { Button } from '@pg/ui-web/ui/button';
import { Input, MoneyInput, Select, Switch, Textarea } from '@pg/ui-web/ui/form-controls';
import { Badge, Card } from '@pg/ui-web/ui/surfaces';
import { Dialog, DialogContent } from '@pg/ui-web/ui/overlays';
import { Table, TBody, TD, TH, THead, TR } from '@pg/ui-web/ui/table';
import { ErrorState, Field, InlineError, PageHeader, TableSkeleton } from '@pg/ui-web/common';

const limit = (v: number | null) => (v === null ? '∞' : String(v));

export function PlansPage() {
  const { admin } = useBackend();
  const q = useQuery({ queryKey: queryKeys.admin.plans(), queryFn: () => admin.listPlans() });
  const [editing, setEditing] = useState<AdminPlan | 'new' | null>(null);

  return (
    <div>
      <PageHeader
        title="Plans"
        description="Plans and limits are configuration stored in the database. Limits are enforced by the server for every tenant."
        actions={
          <Button onClick={() => setEditing('new')}>
            <Plus /> New plan
          </Button>
        }
      />
      <Card>
        {q.isError ? (
          <ErrorState error={q.error} />
        ) : q.isPending ? (
          <TableSkeleton />
        ) : (
          <Table>
            <THead>
              <TR>
                <TH>Plan</TH>
                <TH align="right">Price</TH>
                <TH align="right">Properties</TH>
                <TH align="right">Residents</TH>
                <TH align="right">Team</TH>
                <TH align="right">Trial</TH>
                <TH align="right">Subscribers</TH>
                <TH />
              </TR>
            </THead>
            <TBody>
              {q.data.map((p) => (
                <TR key={p.id}>
                  <TD>
                    <span className="flex items-center gap-2 font-medium text-gray-900">
                      {p.name}
                      {p.is_default && <Badge tone="accent">Default for sign-ups</Badge>}
                      {!p.is_active && <Badge>Inactive</Badge>}
                      {!p.is_public && <Badge>Hidden</Badge>}
                    </span>
                    <span className="text-xs text-gray-500">{p.code}</span>
                  </TD>
                  <TD numeric>{p.price_paise ? `${formatINR(p.price_paise)}/${p.billing_interval === 'month' ? 'mo' : 'yr'}` : 'Free'}</TD>
                  <TD numeric>{limit(p.max_properties)}</TD>
                  <TD numeric>{limit(p.max_residents)}</TD>
                  <TD numeric>{limit(p.max_staff)}</TD>
                  <TD numeric>{p.trial_days ? `${p.trial_days} days` : '—'}</TD>
                  <TD numeric>{p.subscriber_count}</TD>
                  <TD className="text-right">
                    <Button variant="ghost" size="sm" onClick={() => setEditing(p)}>
                      Edit
                    </Button>
                  </TD>
                </TR>
              ))}
            </TBody>
          </Table>
        )}
      </Card>
      <p className="mt-4 text-xs text-gray-500">Subscription payments are not collected yet; prices are shown to owners for information and plans are assigned manually.</p>
      {editing && <PlanDialog plan={editing === 'new' ? null : editing} onClose={() => setEditing(null)} />}
    </div>
  );
}

function PlanDialog({ plan, onClose }: { plan: AdminPlan | null; onClose: () => void }) {
  const { admin } = useBackend();
  const [v, setV] = useState<PlanValues>({
    code: plan?.code ?? '',
    name: plan?.name ?? '',
    description: plan?.description ?? '',
    price: paiseToRupeesInput(plan?.price_paise ?? 0),
    billing_interval: plan?.billing_interval ?? 'month',
    max_properties: plan?.max_properties?.toString() ?? '',
    max_residents: plan?.max_residents?.toString() ?? '',
    max_staff: plan?.max_staff?.toString() ?? '',
    features: (plan?.features ?? []).join('\n'),
    trial_days: plan?.trial_days ?? 0,
    is_public: plan?.is_public ?? true,
    is_active: plan?.is_active ?? true,
    sort_order: plan?.sort_order ?? 0,
  });
  const [errors, setErrors] = useState<Record<string, string>>({});
  const save = useAdminMutation((values: PlanValues) =>
    admin.savePlan(plan?.id ?? null, {
      ...(plan ? {} : { code: values.code }),
      name: values.name,
      description: values.description || null,
      price_paise: rupeesToPaise(values.price) ?? 0,
      billing_interval: values.billing_interval,
      max_properties: values.max_properties ? Number(values.max_properties) : null,
      max_residents: values.max_residents ? Number(values.max_residents) : null,
      max_staff: values.max_staff ? Number(values.max_staff) : null,
      features: values.features.split('\n').map((f) => f.trim()).filter(Boolean),
      trial_days: Number(values.trial_days),
      is_public: values.is_public,
      is_active: values.is_active,
      sort_order: Number(values.sort_order),
    }),
  );
  const submit = () => {
    const parsed = planSchema.safeParse(v);
    if (!parsed.success) {
      setErrors(Object.fromEntries(parsed.error.issues.map((i) => [String(i.path[0]), i.message])));
      return;
    }
    setErrors({});
    save.mutate(parsed.data, { onSuccess: () => { toast.success('Plan saved'); onClose(); } });
  };
  const set = <K extends keyof PlanValues>(k: K, val: PlanValues[K]) => setV((s) => ({ ...s, [k]: val }));

  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent
        size="lg"
        title={plan ? `Edit ${plan.name}` : 'New plan'}
        description="Changing limits applies to all subscribers immediately. Existing data above a lowered limit is kept; only new additions are blocked."
        footer={
          <>
            <Button variant="secondary" onClick={onClose}>
              Cancel
            </Button>
            <Button loading={save.isPending} onClick={submit}>
              Save plan
            </Button>
          </>
        }
      >
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Code" htmlFor="pd-code" error={errors.code} hint={plan ? 'Codes cannot be changed.' : 'e.g. growth'}>
            <Input id="pd-code" value={v.code} disabled={!!plan} onChange={(e) => set('code', e.target.value)} />
          </Field>
          <Field label="Name" htmlFor="pd-name" error={errors.name}>
            <Input id="pd-name" value={v.name} onChange={(e) => set('name', e.target.value)} />
          </Field>
          <Field label="Price" htmlFor="pd-price" error={errors.price}>
            <MoneyInput id="pd-price" value={v.price} onChange={(e) => set('price', e.target.value)} />
          </Field>
          <Field label="Billing interval" htmlFor="pd-int">
            <Select id="pd-int" value={v.billing_interval} onChange={(e) => set('billing_interval', e.target.value as 'month' | 'year')}>
              <option value="month">Monthly</option>
              <option value="year">Yearly</option>
            </Select>
          </Field>
          <Field label="Max properties" htmlFor="pd-mp" error={errors.max_properties} hint="Blank = unlimited">
            <Input id="pd-mp" inputMode="numeric" value={v.max_properties} onChange={(e) => set('max_properties', e.target.value)} />
          </Field>
          <Field label="Max residents" htmlFor="pd-mr" error={errors.max_residents} hint="Blank = unlimited">
            <Input id="pd-mr" inputMode="numeric" value={v.max_residents} onChange={(e) => set('max_residents', e.target.value)} />
          </Field>
          <Field label="Max team members" htmlFor="pd-ms" error={errors.max_staff} hint="Blank = unlimited">
            <Input id="pd-ms" inputMode="numeric" value={v.max_staff} onChange={(e) => set('max_staff', e.target.value)} />
          </Field>
          <Field label="Trial days" htmlFor="pd-trial" error={errors.trial_days}>
            <Input id="pd-trial" inputMode="numeric" value={String(v.trial_days)} onChange={(e) => set('trial_days', e.target.value as unknown as number)} />
          </Field>
          <Field label="Description" htmlFor="pd-desc" className="sm:col-span-2">
            <Input id="pd-desc" value={v.description} onChange={(e) => set('description', e.target.value)} />
          </Field>
          <Field label="Features (one per line)" htmlFor="pd-feat" className="sm:col-span-2">
            <Textarea id="pd-feat" rows={4} value={v.features} onChange={(e) => set('features', e.target.value)} />
          </Field>
          <label className="flex items-center gap-3">
            <Switch checked={v.is_active} onCheckedChange={(c) => set('is_active', c)} />
            <span className="text-[13px] text-gray-700">Active</span>
          </label>
          <label className="flex items-center gap-3">
            <Switch checked={v.is_public} onCheckedChange={(c) => set('is_public', c)} />
            <span className="text-[13px] text-gray-700">Shown to owners</span>
          </label>
          <div className="sm:col-span-2">
            <InlineError error={save.error} />
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
