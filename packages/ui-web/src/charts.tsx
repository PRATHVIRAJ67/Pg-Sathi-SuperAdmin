import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis, type TooltipContentProps } from 'recharts';
import { chart, colors } from '@pg/design-tokens';
import { formatINR, formatMonth, formatMonthShort, type MonthlyPoint } from '@pg/shared';

const SERIES = [
  { key: 'billed_paise', label: 'Billed', color: chart.billed },
  { key: 'collected_paise', label: 'Collected', color: chart.collected },
  { key: 'expenses_paise', label: 'Expenses', color: chart.expenses },
] as const;

export type SeriesKey = (typeof SERIES)[number]['key'];

function MoneyTooltip({ active, payload, label }: TooltipContentProps<number, string>) {
  if (!active || !payload?.length) return null;
  return (
    <div className="rounded-lg border border-gray-200 bg-white px-3 py-2 text-xs shadow-md">
      <p className="mb-1.5 font-medium text-gray-900">{formatMonth(String(label))}</p>
      {payload.map((p) => (
        <div key={String(p.dataKey)} className="flex items-center justify-between gap-6 py-0.5">
          <span className="flex items-center gap-1.5 text-gray-600">
            <span className="size-2 rounded-sm" style={{ background: p.color }} aria-hidden />
            {p.name}
          </span>
          <span className="tabular font-medium text-gray-900">{formatINR(Number(p.value))}</span>
        </div>
      ))}
    </div>
  );
}

/** Grouped monthly bars on a single rupee axis, with legend and hover tooltip. */
export function MonthlyMoneyChart({ data, series = ['billed_paise', 'collected_paise', 'expenses_paise'], height = 260 }: { data: MonthlyPoint[]; series?: SeriesKey[]; height?: number }) {
  const shown = SERIES.filter((s) => series.includes(s.key));
  return (
    <div className="min-w-0">
      <ul className="mb-3 flex flex-wrap gap-4 text-xs text-gray-600" aria-label="Legend">
        {shown.map((s) => (
          <li key={s.key} className="flex items-center gap-1.5">
            <span className="size-2.5 rounded-sm" style={{ background: s.color }} aria-hidden />
            {s.label}
          </li>
        ))}
      </ul>
      <div className="w-full min-w-0" style={{ height }} role="img" aria-label={`Monthly ${shown.map((s) => s.label.toLowerCase()).join(', ')}`}>
        <ResponsiveContainer width="100%" height="100%">
          <BarChart data={data} barGap={2} barCategoryGap="28%" margin={{ top: 4, right: 4, left: 4, bottom: 0 }}>
            <CartesianGrid vertical={false} stroke={colors.gray[100]} />
            <XAxis dataKey="month" tickFormatter={(v: string) => formatMonthShort(v)} tickLine={false} axisLine={false} tick={{ fontSize: 12, fill: colors.gray[500] }} />
            <YAxis tickFormatter={(v: number) => formatINR(v, { compact: true })} tickLine={false} axisLine={false} width={56} tick={{ fontSize: 12, fill: colors.gray[500] }} />
            <Tooltip content={(props) => <MoneyTooltip {...(props as TooltipContentProps<number, string>)} />} cursor={{ fill: colors.gray[50] }} />
            {shown.map((s) => (
              <Bar key={s.key} dataKey={s.key} name={s.label} fill={s.color} radius={[4, 4, 0, 0]} maxBarSize={22} />
            ))}
          </BarChart>
        </ResponsiveContainer>
      </div>
    </div>
  );
}

/** Horizontal share bars (e.g. expenses by category) — labelled, no legend needed. */
export function ShareBars({ rows, color = chart.expenses }: { rows: { label: string; value: number }[]; color?: string }) {
  const max = Math.max(...rows.map((r) => r.value), 1);
  const total = rows.reduce((n, r) => n + r.value, 0);
  return (
    <ul className="space-y-3">
      {rows.map((r) => (
        <li key={r.label}>
          <div className="mb-1 flex justify-between text-[13px]">
            <span className="text-gray-700">{r.label}</span>
            <span className="tabular text-gray-900">
              {formatINR(r.value)} <span className="text-xs text-gray-400">{total ? Math.round((r.value / total) * 100) : 0}%</span>
            </span>
          </div>
          <div className="h-2 rounded-full bg-gray-100">
            <div className="h-2 rounded-full" style={{ width: `${(r.value / max) * 100}%`, background: color }} />
          </div>
        </li>
      ))}
    </ul>
  );
}
