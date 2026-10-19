/**
 * Design tokens shared by the web dashboards (via theme.css) and the mobile
 * app (via this module). Keep the two in sync when changing values.
 */
export const colors = {
  navy: { 950: '#0B1326', 900: '#14213D', 800: '#1E2E52', 700: '#2A3C66' },
  accent: { 50: '#EEEEFD', 100: '#E0E0FB', 200: '#C4C4F6', 500: '#6C6DE8', 600: '#5B5CE2', 700: '#4A4BC9', 800: '#3B3CA3' },
  success: { 50: '#E8F7F1', 100: '#CDEFE2', 600: '#0F9F75', 700: '#0B7F5D' },
  warning: { 50: '#FDF5E6', 100: '#FAE8C3', 600: '#D99018', 700: '#A86C0C' },
  danger: { 50: '#FCEDED', 100: '#F8D7D7', 600: '#D64545', 700: '#B23434' },
  info: { 50: '#EAF3FD', 600: '#2F6FD6' },
  gray: {
    25: '#FBFBFD',
    50: '#F6F7FB',
    100: '#EEF0F5',
    200: '#E3E6EE',
    300: '#CDD2DE',
    400: '#98A1B3',
    500: '#667085',
    600: '#4B5565',
    700: '#344054',
    800: '#1F2937',
    900: '#182230',
  },
  white: '#FFFFFF',
} as const;

export const semantic = {
  background: colors.gray[50],
  surface: colors.white,
  surfaceMuted: colors.gray[25],
  border: colors.gray[200],
  borderStrong: colors.gray[300],
  text: colors.gray[900],
  textSecondary: colors.gray[500],
  textMuted: colors.gray[400],
  primary: colors.navy[900],
  accent: colors.accent[600],
  accentSoft: colors.accent[50],
  success: colors.success[600],
  successSoft: colors.success[50],
  warning: colors.warning[600],
  warningSoft: colors.warning[50],
  danger: colors.danger[600],
  dangerSoft: colors.danger[50],
} as const;

/** 4px base spacing scale. */
export const spacing = { 0: 0, 0.5: 2, 1: 4, 1.5: 6, 2: 8, 2.5: 10, 3: 12, 4: 16, 5: 20, 6: 24, 8: 32, 10: 40, 12: 48, 16: 64 } as const;

export const radius = { sm: 6, md: 8, lg: 10, xl: 14, full: 999 } as const;

export const fontSize = {
  xs: 12,
  sm: 13,
  base: 14,
  md: 15,
  lg: 17,
  xl: 20,
  '2xl': 24,
  '3xl': 30,
} as const;

export const fontWeight = { regular: '400', medium: '500', semibold: '600', bold: '700' } as const;

export const shadow = {
  xs: '0 1px 2px rgba(16, 24, 40, 0.05)',
  sm: '0 1px 3px rgba(16, 24, 40, 0.08), 0 1px 2px rgba(16, 24, 40, 0.04)',
  md: '0 4px 12px -2px rgba(16, 24, 40, 0.08), 0 2px 4px -2px rgba(16, 24, 40, 0.04)',
  lg: '0 12px 24px -6px rgba(16, 24, 40, 0.12), 0 4px 8px -4px rgba(16, 24, 40, 0.05)',
} as const;

/** Chart palette (categorical) — readable on white, distinguishable for common colour-vision deficiencies. */
export const chart = {
  // Validated with the dataviz palette checker (CVD + normal-vision separation).
  billed: colors.accent[600],
  collected: colors.success[600],
  expenses: colors.warning[600],
  occupied: colors.accent[600],
  vacant: colors.gray[300],
  unavailable: colors.warning[600],
  categorical: ['#5B5CE2', '#0F9F75', '#D99018', '#2F6FD6', '#C2417C', '#14213D', '#8A94A6'],
} as const;
