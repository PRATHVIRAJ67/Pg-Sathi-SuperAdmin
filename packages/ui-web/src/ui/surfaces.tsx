import type { HTMLAttributes, ReactNode } from 'react';
import { cva, type VariantProps } from 'class-variance-authority';
import { cn } from '../utils';

export function Card({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('min-w-0 rounded-xl border border-gray-200 bg-white shadow-xs', className)} {...props} />;
}

export function CardHeader({
  title,
  description,
  action,
  className,
}: {
  title: ReactNode;
  description?: ReactNode;
  action?: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn('flex items-start justify-between gap-4 border-b border-gray-100 px-5 py-4', className)}>
      <div className="min-w-0">
        <h3 className="text-[15px] font-semibold text-gray-900">{title}</h3>
        {description && <p className="mt-0.5 text-[13px] text-gray-500">{description}</p>}
      </div>
      {action && <div className="flex shrink-0 items-center gap-2">{action}</div>}
    </div>
  );
}

export function CardBody({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('p-5', className)} {...props} />;
}

export const badgeVariants = cva(
  'inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset [&_svg]:size-3',
  {
    variants: {
      tone: {
        neutral: 'bg-gray-50 text-gray-700 ring-gray-200',
        accent: 'bg-accent-50 text-accent-700 ring-accent-200',
        success: 'bg-success-50 text-success-700 ring-success-100',
        warning: 'bg-warning-50 text-warning-700 ring-warning-100',
        danger: 'bg-danger-50 text-danger-700 ring-danger-100',
        info: 'bg-info-50 text-info-600 ring-info-50',
        navy: 'bg-navy-900 text-white ring-navy-900',
      },
    },
    defaultVariants: { tone: 'neutral' },
  },
);

export function Badge({ className, tone, dot, children, ...props }: HTMLAttributes<HTMLSpanElement> & VariantProps<typeof badgeVariants> & { dot?: boolean }) {
  return (
    <span className={cn(badgeVariants({ tone }), className)} {...props}>
      {dot && <span className="size-1.5 rounded-full bg-current opacity-80" aria-hidden />}
      {children}
    </span>
  );
}

export function Skeleton({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={cn('skeleton rounded-md', className)} aria-hidden {...props} />;
}

export function Separator({ className }: { className?: string }) {
  return <div role="separator" className={cn('h-px w-full bg-gray-100', className)} />;
}

export function Avatar({ name, className }: { name: string; className?: string }) {
  // Skip words like "(demo)" so initials are letters/digits only.
  const parts = name.trim().split(/\s+/).filter((w) => /^[\p{L}\p{N}]/u.test(w));
  const initials = ((parts[0]?.[0] ?? '') + (parts.length > 1 ? (parts[parts.length - 1]?.[0] ?? '') : '')).toUpperCase() || '?';
  // Deterministic tint from the name, purely decorative.
  const tints = ['bg-accent-50 text-accent-700', 'bg-success-50 text-success-700', 'bg-warning-50 text-warning-700', 'bg-info-50 text-info-600', 'bg-gray-100 text-gray-700'];
  let hash = 0;
  for (const ch of name) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
  return (
    <span
      className={cn('inline-flex size-8 shrink-0 items-center justify-center rounded-full text-xs font-semibold', tints[hash % tints.length], className)}
      aria-hidden
    >
      {initials}
    </span>
  );
}

export function Progress({ value, tone = 'accent', className }: { value: number; tone?: 'accent' | 'success' | 'warning' | 'danger'; className?: string }) {
  const color = { accent: 'bg-accent-600', success: 'bg-success-600', warning: 'bg-warning-600', danger: 'bg-danger-600' }[tone];
  const clamped = Math.max(0, Math.min(100, value));
  return (
    <div className={cn('h-1.5 w-full overflow-hidden rounded-full bg-gray-100', className)} role="progressbar" aria-valuenow={Math.round(clamped)} aria-valuemin={0} aria-valuemax={100}>
      <div className={cn('h-full rounded-full transition-[width] duration-500', color)} style={{ width: `${clamped}%` }} />
    </div>
  );
}

export function Kbd({ children }: { children: ReactNode }) {
  return <kbd className="rounded border border-gray-200 bg-gray-50 px-1.5 py-0.5 font-sans text-[11px] text-gray-500">{children}</kbd>;
}
