import { useEffect, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Check, Copy, Mail, MessageCircle, UserPlus, X } from 'lucide-react';
import { queryKeys, useAdminMutation, useBackend } from '@pg/api-client/react';
import { formatDateTime, type OwnerInvite, type OwnerInviteStatus } from '@pg/shared';
import { Button } from '@pg/ui-web/ui/button';
import { Input, Select, Textarea } from '@pg/ui-web/ui/form-controls';
import { Badge, Card, CardHeader, Skeleton } from '@pg/ui-web/ui/surfaces';
import { Dialog, DialogContent, Segmented } from '@pg/ui-web/ui/overlays';
import { ConfirmDialog, EmptyState, ErrorState, Field, InlineError } from '@pg/ui-web/common';

/** Where owners sign up (the owner dashboard). */
export const OWNER_APP_URL = ((import.meta.env.VITE_OWNER_APP_URL as string | undefined)?.trim() || 'https://pg-sathi-admin.prathviholla67.workers.dev').replace(/\/$/, '');

export const inviteLink = (email: string) => `${OWNER_APP_URL}/sign-up?email=${encodeURIComponent(email)}&invited=1`;

function inviteMessage(i: Pick<OwnerInvite, 'email' | 'owner_name' | 'business_name'>) {
  const hi = i.owner_name ? `Hi ${i.owner_name.split(' ')[0]},` : 'Hi,';
  const what = i.business_name ? ` to run ${i.business_name}` : '';
  return `${hi} you're invited to PG Sathi${what}. Sign up with ${i.email} here: ${inviteLink(i.email)}`;
}

/** WhatsApp wants digits with country code; Indian 10-digit numbers get 91. */
const waNumber = (phone: string | null) => {
  const d = (phone ?? '').replace(/\D/g, '');
  return d.length === 10 ? `91${d}` : d;
};

export function InviteOwnerDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (o: boolean) => void }) {
  const { admin } = useBackend();
  const plans = useQuery({ queryKey: queryKeys.admin.plans(), queryFn: () => admin.listPlans() });
  const empty = { email: '', owner_name: '', business_name: '', phone: '', plan_id: '', note: '' };
  const [f, setF] = useState(empty);
  const [done, setDone] = useState<OwnerInvite | null>(null);
  useEffect(() => {
    if (open) {
      setF(empty);
      setDone(null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);
  const invite = useAdminMutation(() =>
    admin.inviteOwner({
      email: f.email.trim(),
      owner_name: f.owner_name.trim() || null,
      business_name: f.business_name.trim() || null,
      phone: f.phone.trim() || null,
      plan_id: f.plan_id || null,
      note: f.note.trim() || null,
    }),
  );
  const set = (k: keyof typeof empty) => (e: { target: { value: string } }) => setF((s) => ({ ...s, [k]: e.target.value }));

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent
        title={done ? 'Invitation ready' : 'Invite an owner'}
        description={done ? 'Send them this sign-up link. When they sign up with this email and set up their PG, it appears under Tenants.' : 'They sign up with this email on the owner dashboard and set up their own PG. You choose their plan.'}
        footer={
          done ? (
            <Button onClick={() => onOpenChange(false)}>Done</Button>
          ) : (
            <>
              <Button variant="secondary" onClick={() => onOpenChange(false)}>
                Cancel
              </Button>
              <Button
                loading={invite.isPending}
                disabled={!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(f.email.trim())}
                onClick={() =>
                  invite
                    .mutateAsync()
                    .then((r) => {
                      toast.success(`Invitation created for ${r.email}`);
                      setDone({ ...f, email: r.email, id: r.id } as unknown as OwnerInvite);
                    })
                    .catch(() => undefined)
                }
              >
                <UserPlus /> Create invitation
              </Button>
            </>
          )
        }
      >
        {done ? (
          <ShareInvite invite={done} />
        ) : (
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Owner’s email" htmlFor="io-email" required className="sm:col-span-2" hint="They must sign up with exactly this email.">
              <Input id="io-email" type="email" autoFocus value={f.email} onChange={set('email')} placeholder="owner@example.com" />
            </Field>
            <Field label="Owner’s name" htmlFor="io-name">
              <Input id="io-name" value={f.owner_name} onChange={set('owner_name')} />
            </Field>
            <Field label="Phone (for WhatsApp)" htmlFor="io-phone">
              <Input id="io-phone" type="tel" value={f.phone} onChange={set('phone')} placeholder="98450 00000" />
            </Field>
            <Field label="Business name" htmlFor="io-biz" hint="Filled in for them during setup.">
              <Input id="io-biz" value={f.business_name} onChange={set('business_name')} placeholder="e.g. Sunrise Stays" />
            </Field>
            <Field label="Plan" htmlFor="io-plan" hint="Leave as default to use the platform’s default plan.">
              <Select id="io-plan" value={f.plan_id} onChange={set('plan_id')}>
                <option value="">Default plan</option>
                {(plans.data ?? [])
                  .filter((p) => p.is_active)
                  .map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.name}
                    </option>
                  ))}
              </Select>
            </Field>
            <Field label="Note (only admins see this)" htmlFor="io-note" className="sm:col-span-2">
              <Textarea id="io-note" rows={2} value={f.note} onChange={set('note')} placeholder="e.g. Met at the Udupi PG owners meet" />
            </Field>
            <div className="sm:col-span-2">
              <InlineError error={invite.error} />
            </div>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}

/** Link plus one-tap ways to send it. */
function ShareInvite({ invite }: { invite: Pick<OwnerInvite, 'email' | 'owner_name' | 'business_name' | 'phone'> }) {
  const [copied, setCopied] = useState(false);
  const link = inviteLink(invite.email);
  const msg = inviteMessage(invite);
  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <Input readOnly value={link} className="font-mono text-xs" aria-label="Sign-up link" onFocus={(e) => e.target.select()} />
        <Button
          variant="secondary"
          size="icon"
          aria-label="Copy link"
          onClick={() => void navigator.clipboard.writeText(msg).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1500); })}
        >
          {copied ? <Check /> : <Copy />}
        </Button>
      </div>
      <div className="flex flex-wrap gap-2">
        <Button variant="secondary" asChild>
          <a href={`https://wa.me/${waNumber(invite.phone)}?text=${encodeURIComponent(msg)}`} target="_blank" rel="noreferrer">
            <MessageCircle /> WhatsApp
          </a>
        </Button>
        <Button variant="secondary" asChild>
          <a href={`mailto:${invite.email}?subject=${encodeURIComponent('Your PG Sathi invitation')}&body=${encodeURIComponent(msg)}`}>
            <Mail /> Email
          </a>
        </Button>
      </div>
      <p className="text-xs text-gray-500">“Copy” copies the full message with the link. The link opens sign-up with their email filled in.</p>
    </div>
  );
}

const STATUS_TONE: Record<OwnerInviteStatus, 'accent' | 'success' | undefined> = { pending: 'accent', accepted: 'success', revoked: undefined };
const STATUS_LABEL: Record<OwnerInviteStatus, string> = { pending: 'Invited', accepted: 'Joined', revoked: 'Cancelled' };

export function OwnerInvitesCard({ onInvite }: { onInvite: () => void }) {
  const { admin } = useBackend();
  const [status, setStatus] = useState<OwnerInviteStatus | 'all'>('pending');
  const q = useQuery({ queryKey: [...queryKeys.admin.ownerInvites(), status], queryFn: () => admin.listOwnerInvites(status) });
  const [sharing, setSharing] = useState<OwnerInvite | null>(null);
  const [cancelling, setCancelling] = useState<OwnerInvite | null>(null);
  const revoke = useAdminMutation((id: string) => admin.revokeOwnerInvite(id));

  return (
    <Card className="mb-6">
      <CardHeader
        title="Owner invitations"
        description="Owners you invited. They show up under Tenants once they set up their PG."
        action={
          <Segmented
            label="Invitation status"
            value={status}
            onChange={setStatus}
            options={[
              { value: 'pending', label: 'Invited' },
              { value: 'accepted', label: 'Joined' },
              { value: 'revoked', label: 'Cancelled' },
              { value: 'all', label: 'All' },
            ]}
          />
        }
      />
      {q.isError ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : q.isPending ? (
        <div className="p-4">
          <Skeleton className="h-16 rounded-lg" />
        </div>
      ) : q.data.length === 0 ? (
        <EmptyState
          compact
          icon={UserPlus}
          title={status === 'pending' ? 'No pending invitations' : 'Nothing here yet'}
          action={status === 'pending' ? <Button size="sm" onClick={onInvite}><UserPlus /> Invite an owner</Button> : undefined}
        />
      ) : (
        <ul className="divide-y divide-gray-100">
          {q.data.map((i) => (
            <li key={i.id} className="flex flex-col gap-3 px-5 py-3.5 sm:flex-row sm:items-center">
              <div className="min-w-0 flex-1">
                <p className="flex flex-wrap items-center gap-2 text-[14px] font-medium text-gray-900">
                  {i.business_name ?? i.email}
                  <Badge tone={STATUS_TONE[i.status]} dot={i.status === 'pending'}>
                    {STATUS_LABEL[i.status]}
                  </Badge>
                  {i.plan_name && <Badge>{i.plan_name}</Badge>}
                </p>
                <p className="mt-0.5 truncate text-xs text-gray-500">
                  {[i.owner_name, i.email, i.phone].filter(Boolean).join(' · ')} · invited {formatDateTime(i.created_at)}
                  {i.status === 'pending' && i.has_account && ' · has signed up, setting up their PG'}
                  {i.status === 'accepted' && i.tenant_name && ` · joined as ${i.tenant_name}`}
                </p>
                {i.note && <p className="mt-1 text-xs text-gray-600">“{i.note}”</p>}
              </div>
              {i.status === 'pending' && (
                <div className="flex shrink-0 gap-2">
                  <Button size="sm" variant="secondary" onClick={() => setSharing(i)}>
                    <MessageCircle /> Send link
                  </Button>
                  <Button size="sm" variant="ghost" className="text-danger-600" onClick={() => setCancelling(i)} aria-label={`Cancel invitation for ${i.email}`}>
                    <X /> Cancel
                  </Button>
                </div>
              )}
            </li>
          ))}
        </ul>
      )}
      <Dialog open={!!sharing} onOpenChange={(o) => !o && setSharing(null)}>
        <DialogContent size="sm" title={`Send invitation to ${sharing?.email ?? ''}`} footer={<Button onClick={() => setSharing(null)}>Done</Button>}>
          {sharing && <ShareInvite invite={sharing} />}
        </DialogContent>
      </Dialog>
      <ConfirmDialog
        open={!!cancelling}
        onOpenChange={(o) => !o && setCancelling(null)}
        title="Cancel this invitation?"
        description={`${cancelling?.email ?? ''} will no longer be able to create a business (when sign-ups are invite-only).`}
        confirmLabel="Cancel invitation"
        destructive
        onConfirm={() => revoke.mutateAsync(cancelling!.id).then(() => toast.success('Invitation cancelled'))}
      />
    </Card>
  );
}
