/**
 * Dates exchanged with the database are ISO calendar dates ("YYYY-MM-DD")
 * without a time zone. Business "today" is India Standard Time, matching the
 * database's private.today().
 */
export type ISODate = string;

const IST_OFFSET_MINUTES = 330;

/** Today's calendar date in India. */
export function todayISO(now: Date = new Date()): ISODate {
  const ist = new Date(now.getTime() + (IST_OFFSET_MINUTES + now.getTimezoneOffset()) * 60_000);
  return toISODate(ist);
}

/** Formats a local Date's calendar components as YYYY-MM-DD. */
export function toISODate(date: Date): ISODate {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

/** Parses YYYY-MM-DD (or a timestamp) into a local Date at midnight without TZ shifting. */
export function parseISODate(value: string): Date {
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(value);
  if (!match) return new Date(value);
  return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
}

export function isISODate(value: unknown): value is ISODate {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const d = parseISODate(value);
  return toISODate(d) === value;
}

export function startOfMonthISO(value: ISODate): ISODate {
  return `${value.slice(0, 7)}-01`;
}

export function endOfMonthISO(value: ISODate): ISODate {
  const d = parseISODate(startOfMonthISO(value));
  return toISODate(new Date(d.getFullYear(), d.getMonth() + 1, 0));
}

export function addMonthsISO(value: ISODate, months: number): ISODate {
  const d = parseISODate(value);
  const target = new Date(d.getFullYear(), d.getMonth() + months, 1);
  const lastDay = new Date(target.getFullYear(), target.getMonth() + 1, 0).getDate();
  target.setDate(Math.min(d.getDate(), lastDay));
  return toISODate(target);
}

export function addDaysISO(value: ISODate, days: number): ISODate {
  const d = parseISODate(value);
  d.setDate(d.getDate() + days);
  return toISODate(d);
}

export function daysBetween(from: ISODate, to: ISODate): number {
  const a = parseISODate(from).getTime();
  const b = parseISODate(to).getTime();
  return Math.round((b - a) / 86_400_000);
}

const dateFmt = new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });
const shortFmt = new Intl.DateTimeFormat('en-IN', { day: 'numeric', month: 'short' });
const monthFmt = new Intl.DateTimeFormat('en-IN', { month: 'long', year: 'numeric' });
const monthShortFmt = new Intl.DateTimeFormat('en-IN', { month: 'short' });
const dateTimeFmt = new Intl.DateTimeFormat('en-IN', {
  day: 'numeric',
  month: 'short',
  year: 'numeric',
  hour: 'numeric',
  minute: '2-digit',
});

/** "12 Oct 2026" */
export function formatDate(value: string | null | undefined): string {
  if (!value) return '—';
  return dateFmt.format(parseISODate(value));
}

/** "12 Oct" */
export function formatShortDate(value: string | null | undefined): string {
  if (!value) return '—';
  return shortFmt.format(parseISODate(value));
}

/** "October 2026" */
export function formatMonth(value: string | null | undefined): string {
  if (!value) return '—';
  return monthFmt.format(parseISODate(value));
}

/** "Oct" */
export function formatMonthShort(value: string): string {
  return monthShortFmt.format(parseISODate(value));
}

/** Formats a full timestamp in the viewer's locale time. */
export function formatDateTime(value: string | null | undefined): string {
  if (!value) return '—';
  return dateTimeFmt.format(new Date(value));
}

/** "3 days ago", "in 5 days", "today" relative to the business day. */
export function relativeDays(value: ISODate, today: ISODate = todayISO()): string {
  const diff = daysBetween(today, value);
  if (diff === 0) return 'today';
  if (diff === 1) return 'tomorrow';
  if (diff === -1) return 'yesterday';
  return diff > 0 ? `in ${diff} days` : `${-diff} days ago`;
}
