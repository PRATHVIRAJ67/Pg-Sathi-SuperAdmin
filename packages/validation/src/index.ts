/**
 * Form schemas shared by web and mobile. They give instant feedback; the
 * database repeats every rule, so these are a UX layer, not a security one.
 * Money fields are entered in rupees as strings and converted to paise.
 */
import { z } from 'zod';
import { isISODate, rupeesToPaise, todayISO, PAYMENT_METHODS, PROPERTY_TYPES } from '@pg/shared';

const PHONE = /^\+?[0-9][0-9 ()-]{5,18}$/;

export const optionalText = (max: number) =>
  z
    .string()
    .trim()
    .max(max, `Use at most ${max} characters`)
    .optional()
    .or(z.literal(''));

export const requiredText = (label: string, min: number, max: number) =>
  z
    .string()
    .trim()
    .min(min, min <= 1 ? `${label} is required` : `${label} must be at least ${min} characters`)
    .max(max, `${label} must be at most ${max} characters`);

export const phoneField = (label = 'Phone number') =>
  z
    .string()
    .trim()
    .refine((v) => v === '' || PHONE.test(v), `${label} is not valid`)
    .optional();

export const emailField = z
  .string()
  .trim()
  .refine((v) => v === '' || /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v), 'Enter a valid email address')
  .optional();

export const dateField = (label = 'Date') => z.string().refine((v) => isISODate(v), `${label} is not a valid date`);

export const optionalDateField = (label = 'Date') =>
  z
    .string()
    .refine((v) => v === '' || isISODate(v), `${label} is not a valid date`)
    .optional();

/** Rupee amount entered as text, e.g. "9,500" or "1200.50". */
export const rupeesField = (label: string, options: { min?: number; required?: boolean } = {}) => {
  const required = options.required ?? true;
  const minPaise = options.min ?? 0;
  return z.string().superRefine((value, ctx) => {
    if (value.trim() === '') {
      if (required) ctx.addIssue({ code: 'custom', message: `${label} is required` });
      return;
    }
    const paise = rupeesToPaise(value);
    if (paise === null) {
      ctx.addIssue({ code: 'custom', message: `${label} must be a valid amount (up to 2 decimals)` });
      return;
    }
    if (paise < minPaise) {
      ctx.addIssue({
        code: 'custom',
        message: minPaise > 0 ? `${label} must be greater than zero` : `${label} cannot be negative`,
      });
    }
    if (paise > 100_000_000_00) ctx.addIssue({ code: 'custom', message: `${label} is too large` });
  });
};

/** Converts an optional rupee string to paise (undefined when blank). */
export function toPaise(value: string | undefined | null): number | undefined {
  if (value === undefined || value === null || value.trim() === '') return undefined;
  return rupeesToPaise(value) ?? undefined;
}

/** Converts blank strings to null for optional database fields. */
export function blankToNull(value: string | undefined | null): string | null {
  if (value === undefined || value === null) return null;
  const trimmed = value.trim();
  return trimmed === '' ? null : trimmed;
}

// ---------------------------------------------------------------------------
// Auth & onboarding
// ---------------------------------------------------------------------------
export const passwordField = z
  .string()
  .min(8, 'Use at least 8 characters')
  .max(72, 'Use at most 72 characters');

export const signUpSchema = z.object({
  fullName: requiredText('Your name', 2, 120),
  email: z.string().trim().email('Enter a valid email address'),
  password: passwordField,
});
export type SignUpValues = z.infer<typeof signUpSchema>;

export const signInSchema = z.object({
  email: z.string().trim().email('Enter a valid email address'),
  password: z.string().min(1, 'Enter your password'),
});
export type SignInValues = z.infer<typeof signInSchema>;

export const businessSchema = z.object({
  businessName: requiredText('Business name', 2, 120),
  ownerName: requiredText('Your name', 2, 120),
  contactPhone: phoneField('Contact phone'),
  contactEmail: emailField,
  city: optionalText(80),
  state: optionalText(80),
});
export type BusinessValues = z.infer<typeof businessSchema>;

// ---------------------------------------------------------------------------
// Properties, rooms, beds
// ---------------------------------------------------------------------------
export const propertySchema = z.object({
  name: requiredText('Property name', 2, 120),
  property_type: z.enum(PROPERTY_TYPES as [string, ...string[]]),
  gender_policy: z.enum(['male', 'female', 'any']),
  address_line1: optionalText(200),
  address_line2: optionalText(200),
  locality: optionalText(100),
  city: optionalText(80),
  state: optionalText(80),
  postal_code: z
    .string()
    .trim()
    .refine((v) => v === '' || /^[0-9]{6}$/.test(v), 'PIN code must be 6 digits')
    .optional(),
  contact_phone: phoneField(),
  description: optionalText(2000),
  facilities: z.array(z.string()).max(50),
});
export type PropertyValues = z.infer<typeof propertySchema>;

export const roomSchema = z.object({
  name: requiredText('Room name', 1, 40),
  floor: optionalText(40),
  category: optionalText(60),
  rent_mode: z.enum(['per_bed', 'per_room']),
  rent: rupeesField('Rent'),
  deposit: rupeesField('Deposit', { required: false }),
  bed_count: z.coerce.number().int('Whole number').min(1, 'At least 1 bed').max(30, 'At most 30 beds'),
});
export type RoomValues = z.infer<typeof roomSchema>;

/** Quick bulk generator used during onboarding: "101–110, 2 beds each". */
export const roomBatchSchema = z.object({
  prefix: optionalText(10),
  start: z.coerce.number().int().min(0).max(9999),
  count: z.coerce.number().int().min(1, 'Add at least 1 room').max(100, 'At most 100 rooms at once'),
  floor: optionalText(40),
  category: optionalText(60),
  bed_count: z.coerce.number().int().min(1).max(30),
  rent_mode: z.enum(['per_bed', 'per_room']),
  rent: rupeesField('Rent'),
  deposit: rupeesField('Deposit', { required: false }),
});
export type RoomBatchValues = z.infer<typeof roomBatchSchema>;

// ---------------------------------------------------------------------------
// Residents & stays
// ---------------------------------------------------------------------------
export const residentSchema = z.object({
  full_name: requiredText('Name', 2, 120),
  phone: phoneField(),
  email: emailField,
  gender: z.enum(['male', 'female', 'other', '']).optional(),
  date_of_birth: optionalDateField('Date of birth'),
  occupation: optionalText(120),
  organization: optionalText(120),
  id_proof_type: optionalText(40),
  id_proof_number: optionalText(40),
  permanent_address: optionalText(500),
  emergency_contact_name: optionalText(120),
  emergency_contact_phone: phoneField('Emergency contact phone'),
  emergency_contact_relation: optionalText(40),
  notes: optionalText(2000),
});
export type ResidentValues = z.infer<typeof residentSchema>;

export const assignBedSchema = z.object({
  bed_id: z.string().min(1, 'Choose a bed'),
  move_in_date: dateField('Move-in date'),
  monthly_rent: rupeesField('Monthly rent'),
  deposit: rupeesField('Security deposit', { required: false }),
  deposit_collected: rupeesField('Deposit collected', { required: false }),
  deposit_method: z.enum(PAYMENT_METHODS as [string, ...string[]]),
  billing_day: z.coerce.number().int().min(1, '1–28').max(28, '1–28'),
  expected_move_out_date: optionalDateField('Expected move-out'),
  notes: optionalText(1000),
});
export type AssignBedValues = z.infer<typeof assignBedSchema>;

export const moveOutSchema = z.object({
  move_out_date: dateField('Move-out date'),
  notes: optionalText(1000),
});
export type MoveOutValues = z.infer<typeof moveOutSchema>;

export const changeRentSchema = z.object({
  monthly_rent: rupeesField('New monthly rent'),
  effective_from: dateField('Effective from'),
  note: optionalText(500),
});
export type ChangeRentValues = z.infer<typeof changeRentSchema>;

// ---------------------------------------------------------------------------
// Finance
// ---------------------------------------------------------------------------
export const paymentSchema = z.object({
  resident_id: z.string().min(1, 'Choose a resident'),
  amount: rupeesField('Amount', { min: 1 }),
  paid_on: dateField('Payment date').refine((v) => v <= todayISO(), 'Payment date cannot be in the future'),
  method: z.enum(PAYMENT_METHODS as [string, ...string[]]),
  reference: optionalText(100),
  notes: optionalText(1000),
});
export type PaymentValues = z.infer<typeof paymentSchema>;

export const invoiceLineSchema = z.object({
  kind: z.enum(['rent', 'charge', 'discount', 'adjustment', 'other']),
  description: requiredText('Description', 1, 200),
  amount: rupeesField('Amount'),
});

export const invoiceSchema = z.object({
  resident_id: z.string().min(1, 'Choose a resident'),
  kind: z.enum(['rent', 'other']),
  issue_date: dateField('Issue date'),
  due_date: dateField('Due date'),
  notes: optionalText(1000),
  items: z.array(invoiceLineSchema).min(1, 'Add at least one line item').max(50),
});
export type InvoiceValues = z.infer<typeof invoiceSchema>;

export const depositSchema = z.object({
  kind: z.enum(['collected', 'refunded', 'deducted']),
  amount: rupeesField('Amount', { min: 1 }),
  txn_date: dateField('Date'),
  method: z.enum([...(PAYMENT_METHODS as [string, ...string[]]), '']).optional(),
  reference: optionalText(100),
  notes: optionalText(1000),
});
export type DepositValues = z.infer<typeof depositSchema>;

export const expenseSchema = z.object({
  property_id: z.string().optional(),
  category: requiredText('Category', 2, 60),
  amount: rupeesField('Amount', { min: 1 }),
  expense_date: dateField('Date'),
  payee: optionalText(120),
  method: z.enum([...(PAYMENT_METHODS as [string, ...string[]]), '']).optional(),
  reference: optionalText(100),
  notes: optionalText(1000),
});
export type ExpenseValues = z.infer<typeof expenseSchema>;

export const chargeTemplateSchema = z.object({
  name: requiredText('Charge name', 2, 80),
  amount: rupeesField('Amount', { min: 1 }),
  frequency: z.enum(['monthly', 'one_time']),
  property_id: z.string().optional(),
  apply_by_default: z.boolean(),
});
export type ChargeTemplateValues = z.infer<typeof chargeTemplateSchema>;

export const voidSchema = z.object({
  reason: requiredText('Reason', 3, 500),
});
export type VoidValues = z.infer<typeof voidSchema>;

// ---------------------------------------------------------------------------
// Settings & team
// ---------------------------------------------------------------------------
export const workspaceProfileSchema = z.object({
  name: requiredText('Business name', 2, 120),
  contact_name: optionalText(120),
  contact_phone: phoneField('Contact phone'),
  contact_email: emailField,
  address_line: optionalText(300),
  city: optionalText(80),
  state: optionalText(80),
  postal_code: optionalText(12),
  gstin: z
    .string()
    .trim()
    .refine((v) => v === '' || /^[0-9A-Za-z]{15}$/.test(v), 'GSTIN must be 15 letters or digits')
    .optional(),
});
export type WorkspaceProfileValues = z.infer<typeof workspaceProfileSchema>;

export const billingSettingsSchema = z.object({
  default_rent_mode: z.enum(['per_bed', 'per_room']),
  default_billing_day: z.coerce.number().int().min(1, '1–28').max(28, '1–28'),
  payment_due_days: z.coerce.number().int().min(0, '0–60').max(60, '0–60'),
  default_deposit: rupeesField('Default deposit', { required: false }),
  prorate_first_month: z.boolean(),
  invoice_prefix: z.string().trim().regex(/^[A-Za-z0-9]{1,8}$/, '1–8 letters or digits'),
  receipt_prefix: z.string().trim().regex(/^[A-Za-z0-9]{1,8}$/, '1–8 letters or digits'),
  payment_methods: z.array(z.string()).min(1, 'Enable at least one payment method'),
  upi_id: optionalText(100),
  receipt_footer: optionalText(500),
});
export type BillingSettingsValues = z.infer<typeof billingSettingsSchema>;

export const inviteMemberSchema = z.object({
  email: z.string().trim().email('Enter a valid email address'),
  role: z.enum(['manager', 'accountant', 'staff']),
});
export type InviteMemberValues = z.infer<typeof inviteMemberSchema>;

export const planSchema = z.object({
  code: z.string().trim().regex(/^[a-z0-9][a-z0-9_-]{1,39}$/, 'Lowercase letters, digits, - or _'),
  name: requiredText('Name', 2, 60),
  description: optionalText(500),
  price: rupeesField('Price', { required: true }),
  billing_interval: z.enum(['month', 'year']),
  max_properties: z.string().refine((v) => v === '' || /^[1-9][0-9]*$/.test(v), 'Leave blank for unlimited'),
  max_residents: z.string().refine((v) => v === '' || /^[1-9][0-9]*$/.test(v), 'Leave blank for unlimited'),
  max_staff: z.string().refine((v) => v === '' || /^[0-9]+$/.test(v), 'Leave blank for unlimited'),
  features: z.string().max(2000),
  trial_days: z.coerce.number().int().min(0).max(365),
  is_public: z.boolean(),
  is_active: z.boolean(),
  sort_order: z.coerce.number().int(),
});
export type PlanValues = z.infer<typeof planSchema>;
