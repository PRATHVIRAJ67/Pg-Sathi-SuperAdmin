import { useId } from 'react';
import { cn } from './utils';

export const PRODUCT_NAME = 'PG Sathi';

/** PG Sathi logo: a house with a bed, on a navy tile. Same artwork as the app icon. */
export function PgSathiMark({ className, title }: { className?: string; title?: string }) {
  const gradient = useId();
  return (
    <svg viewBox="0 0 1024 1024" className={cn('size-8 shrink-0', className)} role={title ? 'img' : undefined} aria-hidden={title ? undefined : true}>
      {title && <title>{title}</title>}
      <defs>
        <linearGradient id={gradient} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#22325A" />
          <stop offset="1" stopColor="#0B1326" />
        </linearGradient>
      </defs>
      <rect width="1024" height="1024" rx="228" fill={`url(#${gradient})`} />
      <path d="M222 478 L512 250 L802 478" fill="none" stroke="#fff" strokeWidth="68" strokeLinecap="round" strokeLinejoin="round" />
      <path d="M314 492 V742 Q314 780 352 780 H672 Q710 780 710 742 V492" fill="none" stroke="#fff" strokeWidth="60" strokeLinejoin="round" />
      <rect x="366" y="536" width="46" height="196" rx="20" fill="#fff" />
      <rect x="430" y="556" width="104" height="62" rx="24" fill="#7C7DF0" />
      <rect x="386" y="634" width="272" height="58" rx="22" fill="#fff" />
      <rect x="548" y="580" width="110" height="70" rx="22" fill="#7C7DF0" />
      <rect x="620" y="668" width="38" height="64" rx="16" fill="#fff" />
    </svg>
  );
}
