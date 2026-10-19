/**
 * Money is always handled as integer paise (1 INR = 100 paise). Conversions
 * from user input use string arithmetic so no floating-point rounding can leak
 * into stored amounts. Division by 100 happens only for display.
 */
export type Paise = number;

const inrFormatter = new Intl.NumberFormat('en-IN', {
  style: 'currency',
  currency: 'INR',
  minimumFractionDigits: 0,
  maximumFractionDigits: 2,
});

const inrWholeFormatter = new Intl.NumberFormat('en-IN', {
  style: 'currency',
  currency: 'INR',
  minimumFractionDigits: 0,
  maximumFractionDigits: 0,
});

const plainFormatter = new Intl.NumberFormat('en-IN', {
  minimumFractionDigits: 0,
  maximumFractionDigits: 2,
});

export interface FormatMoneyOptions {
  /** Round to whole rupees (default false: shows paise only when non-zero). */
  whole?: boolean;
  /** Indian compact notation: ₹1.2K, ₹3.45L, ₹1.1Cr. */
  compact?: boolean;
  /** Prefix positive values with "+". */
  signed?: boolean;
}

export function isValidPaise(value: unknown): value is Paise {
  return typeof value === 'number' && Number.isSafeInteger(value);
}

/** Formats paise as Indian rupees, e.g. 1234550 -> "₹12,345.50". */
export function formatINR(paise: Paise | null | undefined, options: FormatMoneyOptions = {}): string {
  if (paise === null || paise === undefined || Number.isNaN(paise)) return '—';
  const negative = paise < 0;
  const abs = Math.abs(paise);
  let body: string;
  if (options.compact) {
    body = compactINR(abs);
  } else {
    const rupees = abs / 100;
    body = options.whole || abs % 100 === 0 ? inrWholeFormatter.format(Math.round(rupees)) : inrFormatter.format(rupees);
  }
  if (negative) return `−${body}`;
  if (options.signed && paise > 0) return `+${body}`;
  return body;
}

function compactINR(absPaise: number): string {
  const rupees = absPaise / 100;
  const fmt = (n: number, suffix: string) => `₹${trimZeros(n.toFixed(n >= 100 ? 0 : n >= 10 ? 1 : 2))}${suffix}`;
  if (rupees >= 1_00_00_000) return fmt(rupees / 1_00_00_000, 'Cr');
  if (rupees >= 1_00_000) return fmt(rupees / 1_00_000, 'L');
  if (rupees >= 1_000) return fmt(rupees / 1_000, 'K');
  return inrWholeFormatter.format(Math.round(rupees));
}

function trimZeros(value: string): string {
  return value.includes('.') ? value.replace(/\.?0+$/, '') : value;
}

/** Formats paise as a plain number of rupees without the symbol: "12,345.5". */
export function formatRupeesPlain(paise: Paise): string {
  return plainFormatter.format(paise / 100);
}

/**
 * Parses user-entered rupees ("12,345.50", "₹ 500", "1200") into paise.
 * Returns null for empty or invalid input, or more than two decimal places.
 */
export function rupeesToPaise(input: string | number | null | undefined): Paise | null {
  if (input === null || input === undefined) return null;
  const raw = typeof input === 'number' ? input.toString() : input;
  const cleaned = raw.replace(/[₹,\s]/g, '').trim();
  if (cleaned === '') return null;
  const match = /^(-)?(\d+)(?:\.(\d{0,2}))?$/.exec(cleaned);
  if (!match) return null;
  const [, sign, whole, fraction = ''] = match;
  const paise = Number(whole) * 100 + Number(fraction.padEnd(2, '0'));
  if (!Number.isSafeInteger(paise)) return null;
  return sign ? -paise : paise;
}

/** Converts paise into an editable rupee string: 150050 -> "1500.50", 150000 -> "1500". */
export function paiseToRupeesInput(paise: Paise | null | undefined): string {
  if (paise === null || paise === undefined) return '';
  const negative = paise < 0;
  const abs = Math.abs(paise);
  const whole = Math.trunc(abs / 100);
  const fraction = abs % 100;
  const body = fraction === 0 ? `${whole}` : `${whole}.${fraction.toString().padStart(2, '0')}`;
  return negative ? `-${body}` : body;
}

/** Sums paise values exactly. */
export function sumPaise(values: Iterable<Paise | null | undefined>): Paise {
  let total = 0;
  for (const v of values) total += v ?? 0;
  return total;
}

/** Percentage helper for display (0–100, one decimal). */
export function percent(part: number, whole: number): number {
  if (!whole) return 0;
  return Math.round((part / whole) * 1000) / 10;
}
