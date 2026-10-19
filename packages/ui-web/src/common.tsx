import { useState, type ReactNode } from 'react';
import { AlertTriangle, ChevronLeft, ChevronRight, RefreshCw, Search, type LucideIcon } from 'lucide-react';
import {
  BED_STATUS_LABELS,
  INVOICE_PAYMENT_STATUS_LABELS,
  RESIDENT_STATUS_LABELS,
  TENANT_STATUS_LABELS,
  formatINR,
  type BedStatus,
  type InvoicePaymentStatus,
  type Paise,
  type PaymentStatus,
  type ResidentStatus,
  type TenantStatus,
} from '@pg/shared';
import { errorMessage } from '@pg/api-client';
import { cn } from './utils';
import { Button } from './ui/button';
import { Input } from './ui/form-controls';
import { Badge, Card, Skeleton } from './ui/surfaces';
import { Dialog, DialogContent } from './ui/overlays';

export function PageHeader({
  title,
  description,
  actions,
  breadcrumb,
}: {
  title: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
  breadcrumb?: ReactNode;
}) {
  return (
    <div className="mb-6 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
      <div className="min-w-0">
        {breadcrumb && <div className="mb-2 text-[13px] text-gray-500">{breadcrumb}</div>}
        <h1 className="truncate text-[22px] font-semibold tracking-tight text-gray-900">{title}</h1>
        {description && <p className="mt-1 text-sm text-gray-500">{description}</p>}
      </div>
      {actions && <div className="flex flex-wrap items-center gap-2 print:hidden">{actions}</div>}
    </div>
  );
}

export function Money({ paise, className, compact, muted }: { paise: Paise | null | undefined; className?: string; compact?: boolean; muted?: boolean }) {
  return (
    <span className={cn('tabular whitespace-nowrap', muted && paise === 0 && 'text-gray-400', className)}>
      {formatINR(paise, { compact })}
    </span>
  );
}

export function StatCard({
  label,
  value,
  icon: Icon,
  footer,
  tone = 'default',
  loading,
}: {
  label: string;
  value: ReactNode;
  icon?: LucideIcon;
  footer?: ReactNode;
  tone?: 'default' | 'success' | 'warning' | 'danger' | 'accent';
  loading?: boolean;
}) {
  const iconTone = {
    default: 'bg-gray-100 text-gray-600',
    success: 'bg-success-50 text-success-700',
    warning: 'bg-warning-50 text-warning-700',
    danger: 'bg-danger-50 text-danger-700',
    accent: 'bg-accent-50 text-accent-700',
  }[tone];
  return (
    <Card className="p-4">
      <div className="flex items-center justify-between gap-3">
        <p className="text-[13px] font-medium text-gray-500">{label}</p>
        {Icon && (
          <span className={cn('flex size-7 items-center justify-center rounded-md', iconTone)}>
            <Icon className="size-4" aria-hidden />
          </span>
        )}
      </div>
      {loading ? <Skeleton className="mt-3 h-7 w-28" /> : <div className="tabular mt-2 text-2xl font-semibold tracking-tight text-gray-900">{value}</div>}
      {footer && <div className="mt-2 text-xs text-gray-500">{footer}</div>}
    </Card>
  );
}

export function EmptyState({
  icon: Icon,
  title,
  description,
  action,
  className,
  compact,
}: {
  icon: LucideIcon;
  title: string;
  description?: ReactNode;
  action?: ReactNode;
  className?: string;
  compact?: boolean;
}) {
  return (
    <div className={cn('flex flex-col items-center justify-center text-center', compact ? 'px-4 py-8' : 'px-6 py-14', className)}>
      <div className="mb-3 flex size-11 items-center justify-center rounded-xl border border-gray-200 bg-gray-25 text-gray-500 shadow-xs">
        <Icon className="size-5" aria-hidden />
      </div>
      <h3 className="text-[15px] font-semibold text-gray-900">{title}</h3>
      {description && <p className="mt-1 max-w-sm text-[13px] leading-relaxed text-gray-500">{description}</p>}
      {action && <div className="mt-4 flex flex-wrap justify-center gap-2">{action}</div>}
    </div>
  );
}

export function ErrorState({ error, onRetry, className }: { error: unknown; onRetry?: () => void; className?: string }) {
  return (
    <div role="alert" className={cn('flex flex-col items-center justify-center px-6 py-12 text-center', className)}>
      <div className="mb-3 flex size-11 items-center justify-center rounded-xl bg-danger-50 text-danger-600">
        <AlertTriangle className="size-5" aria-hidden />
      </div>
      <h3 className="text-[15px] font-semibold text-gray-900">Couldn’t load this</h3>
      <p className="mt-1 max-w-sm text-[13px] text-gray-500">{errorMessage(error)}</p>
      {onRetry && (
        <Button variant="secondary" size="sm" className="mt-4" onClick={onRetry}>
          <RefreshCw /> Try again
        </Button>
      )}
    </div>
  );
}

export function InlineError({ error }: { error: unknown }) {
  if (!error) return null;
  return (
    <div role="alert" className="flex items-start gap-2 rounded-lg border border-danger-100 bg-danger-50 px-3 py-2.5 text-[13px] text-danger-700">
      <AlertTriangle className="mt-0.5 size-4 shrink-0" aria-hidden />
      <span>{errorMessage(error)}</span>
    </div>
  );
}

export function TableSkeleton({ rows = 6, columns = 5 }: { rows?: number; columns?: number }) {
  return (
    <div className="divide-y divide-gray-100" aria-busy aria-label="Loading">
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} className="flex items-center gap-6 px-4 py-3.5">
          {Array.from({ length: columns }).map((__, j) => (
            <Skeleton key={j} className={cn('h-4', j === 0 ? 'w-40' : 'w-20', j === columns - 1 && 'ml-auto')} />
          ))}
        </div>
      ))}
    </div>
  );
}

export function SearchInput({ value, onChange, placeholder, className }: { value: string; onChange: (v: string) => void; placeholder: string; className?: string }) {
  return (
    <div className={cn('w-full sm:w-72', className)}>
      <Input type="search" value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} leading={<Search />} aria-label={placeholder} />
    </div>
  );
}

export function Pagination({ total, limit, offset, onChange }: { total: number; limit: number; offset: number; onChange: (offset: number) => void }) {
  if (total <= limit) return null;
  const from = offset + 1;
  const to = Math.min(offset + limit, total);
  return (
    <div className="flex items-center justify-between border-t border-gray-100 px-4 py-3 text-[13px] text-gray-500">
      <span className="tabular">
        {from}–{to} of {total}
      </span>
      <div className="flex gap-1">
        <Button variant="secondary" size="icon-sm" disabled={offset === 0} onClick={() => onChange(Math.max(0, offset - limit))} aria-label="Previous page">
          <ChevronLeft />
        </Button>
        <Button variant="secondary" size="icon-sm" disabled={to >= total} onClick={() => onChange(offset + limit)} aria-label="Next page">
          <ChevronRight />
        </Button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Status badges
// ---------------------------------------------------------------------------
export function InvoiceStatusBadge({ status }: { status: InvoicePaymentStatus }) {
  const tone = ({ paid: 'success', partially_paid: 'info', pending: 'neutral', overdue: 'danger', void: 'neutral' } as const)[status];
  return (
    <Badge tone={tone} dot className={status === 'void' ? 'line-through' : undefined}>
      {INVOICE_PAYMENT_STATUS_LABELS[status]}
    </Badge>
  );
}

export function PaymentStatusBadge({ status }: { status: PaymentStatus }) {
  if (status === 'voided') return <Badge tone="danger">Voided</Badge>;
  if (status === 'recorded') return <Badge tone="neutral">Recorded manually</Badge>;
  if (status === 'succeeded') return <Badge tone="success">Gateway verified</Badge>;
  return <Badge tone="warning">{status}</Badge>;
}

export function ResidentStatusBadge({ status }: { status: ResidentStatus }) {
  const tone = ({ active: 'success', unassigned: 'warning', moved_out: 'neutral', archived: 'neutral' } as const)[status];
  return (
    <Badge tone={tone} dot>
      {RESIDENT_STATUS_LABELS[status]}
    </Badge>
  );
}

export function BedStatusBadge({ status }: { status: BedStatus }) {
  const tone = ({ vacant: 'success', occupied: 'accent', unavailable: 'warning' } as const)[status];
  return <Badge tone={tone}>{BED_STATUS_LABELS[status]}</Badge>;
}

export function TenantStatusBadge({ status }: { status: TenantStatus }) {
  const tone = ({ trial: 'accent', active: 'success', suspended: 'danger', cancelled: 'neutral' } as const)[status];
  return <Badge tone={tone}>{TENANT_STATUS_LABELS[status]}</Badge>;
}

// ---------------------------------------------------------------------------
// Forms
// ---------------------------------------------------------------------------
export function Field({
  label,
  htmlFor,
  error,
  hint,
  required,
  children,
  className,
}: {
  label: ReactNode;
  htmlFor?: string;
  error?: string;
  hint?: ReactNode;
  required?: boolean;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn('space-y-1.5', className)}>
      <label htmlFor={htmlFor} className="block text-[13px] font-medium text-gray-700">
        {label}
        {required && <span className="ml-0.5 text-danger-600" aria-hidden>*</span>}
      </label>
      {children}
      {error ? (
        <p className="text-xs text-danger-600" role="alert">
          {error}
        </p>
      ) : (
        hint && <p className="text-xs leading-relaxed text-gray-500">{hint}</p>
      )}
    </div>
  );
}

export function FormSection({ title, description, children }: { title: string; description?: string; children: ReactNode }) {
  return (
    <section className="grid gap-x-8 gap-y-4 border-b border-gray-100 py-6 first:pt-0 last:border-0 md:grid-cols-[220px_1fr]">
      <div>
        <h3 className="text-sm font-semibold text-gray-900">{title}</h3>
        {description && <p className="mt-1 text-[13px] leading-relaxed text-gray-500">{description}</p>}
      </div>
      <div className="space-y-4">{children}</div>
    </section>
  );
}

export function ConfirmDialog({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel = 'Confirm',
  destructive,
  onConfirm,
  children,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description?: ReactNode;
  confirmLabel?: string;
  destructive?: boolean;
  onConfirm: () => Promise<unknown> | void;
  children?: ReactNode;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  return (
    <Dialog
      open={open}
      onOpenChange={(o) => {
        if (!o) setError(null);
        onOpenChange(o);
      }}
    >
      <DialogContent
        size="sm"
        title={title}
        description={description}
        footer={
          <>
            <Button variant="secondary" onClick={() => onOpenChange(false)} disabled={busy}>
              Cancel
            </Button>
            <Button
              variant={destructive ? 'danger' : 'primary'}
              loading={busy}
              onClick={async () => {
                setBusy(true);
                setError(null);
                try {
                  await onConfirm();
                  onOpenChange(false);
                } catch (e) {
                  setError(e);
                } finally {
                  setBusy(false);
                }
              }}
            >
              {confirmLabel}
            </Button>
          </>
        }
      >
        <div className="space-y-3">
          {children}
          <InlineError error={error} />
        </div>
      </DialogContent>
    </Dialog>
  );
}

export function KeyValue({ label, children, className }: { label: string; children: ReactNode; className?: string }) {
  return (
    <div className={className}>
      <dt className="text-xs text-gray-500">{label}</dt>
      <dd className="mt-0.5 text-[13px] font-medium text-gray-900">{children ?? '—'}</dd>
    </div>
  );
}
