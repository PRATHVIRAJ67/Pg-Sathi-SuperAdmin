import { useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { toast } from 'sonner';
import { Inbox, MessageCircle, Phone, UserPlus } from 'lucide-react';
import { queryKeys, useAdminMutation, useBackend } from '@pg/api-client/react';
import { formatDateTime, type Lead, type LeadStatus } from '@pg/shared';
import { Button } from '@pg/ui-web/ui/button';
import { Select, Textarea } from '@pg/ui-web/ui/form-controls';
import { Badge, Card, Skeleton } from '@pg/ui-web/ui/surfaces';
import { Segmented } from '@pg/ui-web/ui/overlays';
import { EmptyState, ErrorState, PageHeader } from '@pg/ui-web/common';
import { InviteOwnerDialog } from './invites';

const STATUS_LABEL: Record<LeadStatus, string> = { new: 'New', contacted: 'Contacted', invited: 'Invited', won: 'Customer', lost: 'Not interested' };
const STATUS_TONE: Record<LeadStatus, 'accent' | 'warning' | 'success' | 'danger' | undefined> = { new: 'accent', contacted: 'warning', invited: 'success', won: 'success', lost: undefined };

const waNumber = (phone: string) => {
  const d = phone.replace(/\D/g, '');
  return d.length === 10 ? `91${d}` : d;
};

/**
 * "Book a demo" requests from the marketing website. Call the owner, agree the
 * plan and payment, then invite them: the invite is prefilled from the lead.
 */
export function LeadsPage() {
  const { admin } = useBackend();
  const [status, setStatus] = useState<LeadStatus | 'open' | 'all'>('open');
  const q = useQuery({ queryKey: [...queryKeys.admin.leads(), status], queryFn: () => admin.listLeads(status), refetchInterval: 60_000 });
  const [inviting, setInviting] = useState<Lead | null>(null);
  const update = useAdminMutation(({ id, patch }: { id: string; patch: Parameters<typeof admin.updateLead>[1] }) => admin.updateLead(id, patch));

  return (
    <div>
      <PageHeader title="Leads" description="Owners who asked for a demo on the website. Call them, agree the plan and payment, then invite them to sign up." />
      <div className="mb-4">
        <Segmented
          label="Lead status"
          value={status}
          onChange={setStatus}
          options={[
            { value: 'open', label: 'To follow up' },
            { value: 'invited', label: 'Invited' },
            { value: 'won', label: 'Customers' },
            { value: 'lost', label: 'Not interested' },
            { value: 'all', label: 'All' },
          ]}
        />
      </div>
      {q.isError ? (
        <ErrorState error={q.error} onRetry={() => void q.refetch()} />
      ) : q.isPending ? (
        <Skeleton className="h-40 rounded-xl" />
      ) : q.data.length === 0 ? (
        <Card>
          <EmptyState icon={Inbox} title={status === 'open' ? 'No new leads' : 'Nothing here'} description={status === 'open' ? 'When an owner fills in “Book a demo” on the website, they show up here.' : undefined} />
        </Card>
      ) : (
        <div className="grid gap-4 lg:grid-cols-2">
          {q.data.map((l) => (
            <LeadCard
              key={l.id}
              lead={l}
              busy={update.isPending}
              onStatus={(s) => update.mutate({ id: l.id, patch: { status: s } }, { onSuccess: () => toast.success(`Marked as ${STATUS_LABEL[s].toLowerCase()}`) })}
              onNote={(note) => update.mutate({ id: l.id, patch: { admin_note: note } }, { onSuccess: () => toast.success('Note saved') })}
              onInvite={() => setInviting(l)}
            />
          ))}
        </div>
      )}
      <InviteOwnerDialog
        open={!!inviting}
        onOpenChange={(o) => !o && setInviting(null)}
        initial={inviting ? { email: inviting.email ?? '', owner_name: inviting.owner_name, business_name: inviting.business_name, phone: inviting.phone, note: inviting.admin_note ?? '' } : undefined}
        onInvited={(inv) => inviting && update.mutate({ id: inviting.id, patch: { status: 'invited', invite_id: inv.id } })}
      />
    </div>
  );
}

function LeadCard({ lead: l, busy, onStatus, onNote, onInvite }: { lead: Lead; busy: boolean; onStatus: (s: LeadStatus) => void; onNote: (note: string) => void; onInvite: () => void }) {
  const [note, setNote] = useState(l.admin_note ?? '');
  const rows: [string, string | null][] = [
    ['Owner', l.owner_name],
    ['Phone', l.phone],
    ['Email', l.email],
    ['City', l.city],
    ['Beds', l.beds],
  ];
  return (
    <Card className="flex flex-col">
      <div className="flex items-start justify-between gap-3 border-b border-gray-100 px-5 py-4">
        <div className="min-w-0">
          <h3 className="truncate text-[15px] font-semibold text-gray-900">{l.business_name}</h3>
          <p className="text-xs text-gray-500">asked {formatDateTime(l.created_at)}</p>
        </div>
        <Badge tone={STATUS_TONE[l.status]} dot={l.status === 'new'}>
          {STATUS_LABEL[l.status]}
        </Badge>
      </div>
      <div className="flex-1 space-y-3 px-5 py-4">
        <dl className="grid grid-cols-[80px_1fr] gap-x-3 gap-y-1.5 text-[13px]">
          {rows
            .filter(([, v]) => v)
            .map(([k, v]) => (
              <div key={k} className="contents">
                <dt className="text-gray-500">{k}</dt>
                <dd className="text-gray-900">{v}</dd>
              </div>
            ))}
        </dl>
        {l.message && <p className="rounded-md bg-gray-25 px-3 py-2 text-[13px] text-gray-700 ring-1 ring-gray-100">“{l.message}”</p>}
        <Textarea rows={2} value={note} onChange={(e) => setNote(e.target.value)} onBlur={() => note !== (l.admin_note ?? '') && onNote(note)} placeholder="Your notes, e.g. agreed Growth, paid ₹999 by UPI" aria-label="Notes" className="text-[13px]" />
      </div>
      <div className="flex flex-wrap items-center gap-2 border-t border-gray-100 px-5 py-3">
        <Button size="sm" variant="secondary" asChild>
          <a href={`tel:${l.phone}`}>
            <Phone /> Call
          </a>
        </Button>
        <Button size="sm" variant="secondary" asChild>
          <a href={`https://wa.me/${waNumber(l.phone)}?text=${encodeURIComponent(`Hi ${l.owner_name.split(' ')[0]}, this is PG Sathi. Thanks for asking for a demo for ${l.business_name}.`)}`} target="_blank" rel="noreferrer">
            <MessageCircle /> WhatsApp
          </a>
        </Button>
        {l.status !== 'invited' && l.status !== 'won' && (
          <Button size="sm" onClick={onInvite}>
            <UserPlus /> Invite (after payment)
          </Button>
        )}
        <Select value={l.status} disabled={busy} onChange={(e) => onStatus(e.target.value as LeadStatus)} aria-label="Lead status" className="ml-auto h-8 w-40 text-[13px]">
          {(Object.keys(STATUS_LABEL) as LeadStatus[]).map((s) => (
            <option key={s} value={s}>
              {STATUS_LABEL[s]}
            </option>
          ))}
        </Select>
      </div>
    </Card>
  );
}
