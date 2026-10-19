import type { PGlite } from '@electric-sql/pglite';
import { createDataService, newIdempotencyKey, type DataService } from '@pg/api-client';
import {
  addDaysISO,
  addMonthsISO,
  startOfMonthISO,
  todayISO,
  type ISODate,
  type PaymentMethod,
  type UUID,
} from '@pg/shared';
import { createPgliteTransport, type DemoAuth } from './database';

/**
 * DEMO DATA ONLY. Everything below is fictional and exists solely so the demo
 * mode has something to show. It is never loaded when the apps are connected
 * to Supabase. The seed runs through the same public API functions a real
 * owner uses, so demo data passes the same validation as real data.
 */
export const DEMO_ACCOUNT = {
  email: 'owner@demo.pgsaas.local',
  password: 'demo-owner-2026',
  fullName: 'Demo Owner',
} as const;

/** Demo-only platform operator account for the super-admin app. */
export const DEMO_ADMIN_ACCOUNT = {
  email: 'admin@demo.pgsaas.local',
  password: 'demo-admin-2026',
  fullName: 'Demo Platform Admin',
} as const;

const SEED_MARKER = 'demo-seed:v1';
const ADMIN_MARKER = 'demo-admin:v1';

/** Creates the demo platform admin (super-admin app demo mode only). Idempotent. */
export async function seedDemoPlatformAdmin(db: PGlite, auth: DemoAuth): Promise<void> {
  const done = await db.query('select 1 from demo_meta.applied where name = $1', [ADMIN_MARKER]);
  if (done.rows.length) return;
  const userId = await auth.createUser({ ...DEMO_ADMIN_ACCOUNT, confirmed: true });
  // Operators are granted with SQL, never through the app — same as production.
  await db.query('insert into public.platform_admins (user_id, note) values ($1, $2)', [userId, 'Demo operator']);
  // A second, freshly onboarded demo business so the tenant list has variety.
  const ownerId = await auth.createUser({ email: 'owner2@demo.pgsaas.local', password: 'demo-owner-2026', fullName: 'Second Demo Owner', confirmed: true });
  const api = createDataService(createPgliteTransport(db, () => ownerId));
  const tenantId = await api.provisionWorkspace({ requestId: newIdempotencyKey(), businessName: 'Lakeview Hostel (demo)', city: 'Pune', state: 'Maharashtra' });
  const propertyId = await api.createProperty(tenantId, { name: 'Lakeview Hostel — Baner (demo)', property_type: 'hostel', city: 'Pune' });
  await api.createRooms(propertyId, [
    { name: 'G1', rent_paise: 6_500_00, bed_count: 4 },
    { name: 'G2', rent_paise: 6_500_00, bed_count: 4 },
  ]);
  await db.query('insert into demo_meta.applied (name) values ($1)', [ADMIN_MARKER]);
}

type Behaviour = 'prompt' | 'late' | 'partial' | 'overdue' | 'advance';

interface DemoResident {
  name: string;
  phone: string;
  gender: 'male' | 'female';
  occupation: string;
  property: 0 | 1;
  room: string;
  bed: number;
  monthsAgo: number;
  day: number;
  behaviour: Behaviour;
  depositCollected: boolean;
}

const PROPERTIES = [
  {
    name: 'Sunrise Residency (demo)',
    property_type: 'pg' as const,
    gender_policy: 'male' as const,
    address_line1: '14, 5th Cross, 6th Block',
    locality: 'Koramangala',
    city: 'Bengaluru',
    state: 'Karnataka',
    postal_code: '560095',
    facilities: ['WiFi', 'Meals', 'Laundry', 'Housekeeping', 'Power backup', 'Hot water'],
    rooms: [
      { name: '101', floor: 'Ground', category: 'Double sharing', rent_paise: 9_000_00, deposit_paise: 18_000_00, bed_count: 2 },
      { name: '102', floor: 'Ground', category: 'Triple sharing', rent_paise: 7_500_00, deposit_paise: 15_000_00, bed_count: 3 },
      { name: '103', floor: 'Ground', category: 'Single', rent_paise: 14_000_00, deposit_paise: 28_000_00, bed_count: 1 },
      { name: '201', floor: 'First', category: 'Double sharing', rent_paise: 9_500_00, deposit_paise: 19_000_00, bed_count: 2 },
      { name: '202', floor: 'First', category: 'Triple sharing', rent_paise: 7_000_00, deposit_paise: 14_000_00, bed_count: 3 },
      { name: '203', floor: 'First', category: 'Double sharing', rent_paise: 9_500_00, deposit_paise: 19_000_00, bed_count: 2 },
    ],
  },
  {
    name: 'Green Nest Co-living (demo)',
    property_type: 'coliving' as const,
    gender_policy: 'female' as const,
    address_line1: '221, 27th Main, Sector 2',
    locality: 'HSR Layout',
    city: 'Bengaluru',
    state: 'Karnataka',
    postal_code: '560102',
    facilities: ['WiFi', 'Meals', 'AC', 'CCTV', 'Laundry'],
    rooms: [
      { name: 'A1', floor: 'First', category: 'Double sharing AC', rent_paise: 12_000_00, deposit_paise: 24_000_00, bed_count: 2 },
      { name: 'A2', floor: 'First', category: 'Single AC', rent_paise: 18_000_00, deposit_paise: 36_000_00, bed_count: 1 },
      { name: 'B1', floor: 'Second', category: 'Triple sharing', rent_paise: 8_500_00, deposit_paise: 17_000_00, bed_count: 3 },
      { name: 'B2', floor: 'Second', category: 'Double sharing', rent_paise: 10_500_00, deposit_paise: 21_000_00, bed_count: 2 },
    ],
  },
];

const RESIDENTS: DemoResident[] = [
  { name: 'Arjun Mehta', phone: '9845001101', gender: 'male', occupation: 'Software engineer', property: 0, room: '101', bed: 0, monthsAgo: 7, day: 3, behaviour: 'prompt', depositCollected: true },
  { name: 'Karthik Rao', phone: '9845001102', gender: 'male', occupation: 'Data analyst', property: 0, room: '101', bed: 1, monthsAgo: 5, day: 12, behaviour: 'late', depositCollected: true },
  { name: 'Rohan Iyer', phone: '9845001103', gender: 'male', occupation: 'Student', property: 0, room: '102', bed: 0, monthsAgo: 4, day: 1, behaviour: 'partial', depositCollected: true },
  { name: 'Vikram Singh', phone: '9845001104', gender: 'male', occupation: 'Sales executive', property: 0, room: '102', bed: 1, monthsAgo: 6, day: 8, behaviour: 'prompt', depositCollected: true },
  { name: 'Aditya Kulkarni', phone: '9845001105', gender: 'male', occupation: 'Designer', property: 0, room: '102', bed: 2, monthsAgo: 2, day: 15, behaviour: 'overdue', depositCollected: false },
  { name: 'Siddharth Nair', phone: '9845001106', gender: 'male', occupation: 'Consultant', property: 0, room: '103', bed: 0, monthsAgo: 8, day: 1, behaviour: 'advance', depositCollected: true },
  { name: 'Manish Gupta', phone: '9845001107', gender: 'male', occupation: 'Product manager', property: 0, room: '201', bed: 0, monthsAgo: 3, day: 5, behaviour: 'prompt', depositCollected: true },
  { name: 'Nikhil Reddy', phone: '9845001108', gender: 'male', occupation: 'QA engineer', property: 0, room: '202', bed: 0, monthsAgo: 1, day: 10, behaviour: 'prompt', depositCollected: true },
  { name: 'Pranav Joshi', phone: '9845001109', gender: 'male', occupation: 'Student', property: 0, room: '202', bed: 1, monthsAgo: 0, day: 2, behaviour: 'late', depositCollected: false },
  { name: 'Ananya Sharma', phone: '9845001201', gender: 'female', occupation: 'Software engineer', property: 1, room: 'A1', bed: 0, monthsAgo: 6, day: 1, behaviour: 'prompt', depositCollected: true },
  { name: 'Priya Menon', phone: '9845001202', gender: 'female', occupation: 'Doctor (resident)', property: 1, room: 'A2', bed: 0, monthsAgo: 5, day: 4, behaviour: 'prompt', depositCollected: true },
  { name: 'Sneha Patil', phone: '9845001203', gender: 'female', occupation: 'HR associate', property: 1, room: 'B1', bed: 0, monthsAgo: 3, day: 20, behaviour: 'late', depositCollected: true },
  { name: 'Divya Krishnan', phone: '9845001204', gender: 'female', occupation: 'Student', property: 1, room: 'B1', bed: 1, monthsAgo: 4, day: 6, behaviour: 'overdue', depositCollected: true },
  { name: 'Meera Das', phone: '9845001205', gender: 'female', occupation: 'Chartered accountant', property: 1, room: 'B2', bed: 0, monthsAgo: 2, day: 1, behaviour: 'prompt', depositCollected: true },
];

const UNASSIGNED = [{ name: 'Ishaan Verma', phone: '9845001110', gender: 'male' as const, occupation: 'Intern' }];

const METHODS: PaymentMethod[] = ['upi', 'upi', 'cash', 'bank_transfer'];

function minDate(a: ISODate, b: ISODate): ISODate {
  return a < b ? a : b;
}

export async function isDemoSeeded(db: PGlite): Promise<boolean> {
  const res = await db.query('select 1 from demo_meta.applied where name = $1', [SEED_MARKER]);
  return res.rows.length > 0;
}

/** Creates the demo owner account and a populated, fictional workspace. Idempotent. */
export async function seedDemoWorkspace(db: PGlite, auth: DemoAuth): Promise<{ userId: UUID; tenantId: UUID } | null> {
  if (await isDemoSeeded(db)) return null;

  const userId = await auth.createUser({ ...DEMO_ACCOUNT, confirmed: true });
  const api: DataService = createDataService(createPgliteTransport(db, () => userId));
  const today = todayISO();
  const thisMonth = startOfMonthISO(today);
  const monthStart = (monthsAgo: number) => addMonthsISO(thisMonth, -monthsAgo);
  const dateIn = (monthsAgo: number, day: number) => minDate(addDaysISO(monthStart(monthsAgo), day - 1), today);

  const tenantId = await api.provisionWorkspace({
    requestId: newIdempotencyKey(),
    businessName: 'Sunrise Stays (demo)',
    ownerName: DEMO_ACCOUNT.fullName,
    contactPhone: '9845000000',
    contactEmail: DEMO_ACCOUNT.email,
    city: 'Bengaluru',
    state: 'Karnataka',
  });

  // Demo workspaces run on the multi-property plan so both sample properties fit.
  await db.query(
    `update public.subscriptions
        set plan_id = (select id from public.plans where code = 'growth'), status = 'trialing',
            trial_ends_at = now() + interval '14 days'
      where tenant_id = $1 and exists (select 1 from public.plans where code = 'growth')`,
    [tenantId],
  );

  await api.updateWorkspace(tenantId, {
    address_line: '14, 5th Cross, 6th Block, Koramangala',
    postal_code: '560095',
  });
  await api.updateSettings(tenantId, {
    receipt_footer: 'Thank you! This is a demo receipt generated from sample data.',
    upi_id: 'sunrise.demo@upi',
    payment_due_days: 5,
  });

  const propertyIds: UUID[] = [];
  for (const p of PROPERTIES) {
    const { rooms, ...details } = p;
    const id = await api.createProperty(tenantId, details);
    propertyIds.push(id);
    await api.createRooms(id, rooms.map((r) => ({ ...r, rent_mode: 'per_bed' as const })));
  }

  await api.saveChargeTemplate(tenantId, null, {
    property_id: propertyIds[0]!,
    name: 'Laundry',
    amount_paise: 300_00,
    frequency: 'monthly',
    apply_by_default: true,
  });
  await api.saveChargeTemplate(tenantId, null, {
    name: 'Key replacement',
    amount_paise: 250_00,
    frequency: 'one_time',
    apply_by_default: false,
  });

  const rooms = await api.listRooms(tenantId);
  const bedFor = (propertyIndex: number, roomName: string, bedIndex: number) => {
    const room = rooms.find((r) => r.property_id === propertyIds[propertyIndex] && r.name === roomName);
    const bed = room?.beds[bedIndex];
    if (!room || !bed) throw new Error(`Demo seed: bed ${roomName}/${bedIndex} not found`);
    return { room, bed };
  };

  // One bed under repair.
  await api.updateBed(bedFor(0, '203', 1).bed.id, { is_unavailable: true, unavailable_reason: 'Under repair' });

  // A former resident with a completed stay and settled deposit.
  const formerId = await api.createResident(tenantId, {
    full_name: 'Rahul Bansal',
    phone: '9845001199',
    gender: 'male',
    occupation: 'Analyst',
  });
  const formerBed = bedFor(0, '201', 1);
  const formerStay = await api.assignBed({
    residentId: formerId,
    bedId: formerBed.bed.id,
    move_in_date: dateIn(5, 1),
    monthly_rent_paise: formerBed.bed.suggested_rent_paise,
    deposit_paise: formerBed.room.deposit_paise,
    deposit_collected_paise: formerBed.room.deposit_paise,
    deposit_method: 'bank_transfer',
  });

  const residentIds = new Map<string, { id: UUID; behaviour: Behaviour }>();
  for (const r of RESIDENTS) {
    const id = await api.createResident(tenantId, {
      full_name: r.name,
      phone: r.phone,
      gender: r.gender,
      occupation: r.occupation,
      emergency_contact_name: 'Family contact',
      emergency_contact_phone: `9900${r.phone.slice(-6)}`,
      emergency_contact_relation: 'Parent',
    });
    const { room, bed } = bedFor(r.property, r.room, r.bed);
    await api.assignBed({
      residentId: id,
      bedId: bed.id,
      move_in_date: dateIn(r.monthsAgo, r.day),
      monthly_rent_paise: bed.suggested_rent_paise,
      deposit_paise: room.deposit_paise,
      deposit_collected_paise: r.depositCollected ? room.deposit_paise : undefined,
      deposit_method: 'upi',
    });
    residentIds.set(r.name, { id, behaviour: r.behaviour });
  }
  for (const u of UNASSIGNED) {
    await api.createResident(tenantId, { full_name: u.name, phone: u.phone, gender: u.gender, occupation: u.occupation });
  }

  // Explicit monthly rent runs (the owner would click "Generate rent" each
  // month — there is no scheduler). The older months come first so the former
  // resident can settle up and move out before the recent months are billed.
  for (const m of [3, 2]) {
    await api.generateRentInvoices(tenantId, monthStart(m));
  }

  // The former resident pays everything, then moves out with a deposit settlement.
  const formerDetail = await api.getResident(formerId);
  for (const inv of [...formerDetail.invoices].reverse()) {
    if (inv.balance_paise <= 0 || inv.status === 'void') continue;
    await api.recordPayment({
      residentId: formerId,
      amount_paise: inv.balance_paise,
      paid_on: minDate(addDaysISO(inv.issue_date, 2), today),
      method: 'bank_transfer',
      idempotency_key: newIdempotencyKey(),
    });
  }
  await api.endStay(formerStay, dateIn(1, 10), 'Relocated to another city');
  await api.recordDeposit({
    residentId: formerId,
    kind: 'deducted',
    amount_paise: 1_500_00,
    notes: 'Repainting after move-out',
    txn_date: dateIn(1, 12),
    idempotency_key: newIdempotencyKey(),
  });
  await api.recordDeposit({
    residentId: formerId,
    kind: 'refunded',
    amount_paise: formerBed.room.deposit_paise - 1_500_00,
    method: 'bank_transfer',
    txn_date: dateIn(1, 12),
    idempotency_key: newIdempotencyKey(),
  });

  for (const m of [1, 0]) {
    await api.generateRentInvoices(tenantId, monthStart(m));
  }

  let methodIndex = 0;
  for (const [, { id, behaviour }] of residentIds) {
    const detail = await api.getResident(id);
    const invoices = [...detail.invoices].filter((i) => i.status === 'issued').sort((a, b) => a.due_date.localeCompare(b.due_date));
    for (const inv of invoices) {
      const isCurrent = inv.period_start === thisMonth;
      const isLast = inv.period_start === monthStart(1);
      let amount = inv.balance_paise;
      if (behaviour === 'late' && isCurrent) amount = 0;
      if (behaviour === 'partial' && isLast) amount = Math.round(inv.balance_paise / 2 / 100) * 100;
      if (behaviour === 'partial' && isCurrent) amount = 0;
      if (behaviour === 'overdue' && (isCurrent || isLast)) amount = 0;
      if (behaviour === 'advance' && isCurrent) amount += 5_000_00;
      if (amount <= 0) continue;
      const method = METHODS[methodIndex++ % METHODS.length]!;
      await api.recordPayment({
        residentId: id,
        amount_paise: amount,
        paid_on: minDate(addDaysISO(inv.issue_date, behaviour === 'prompt' ? 1 : 6), today),
        method,
        reference: method === 'cash' ? null : `DEMO${String(methodIndex).padStart(6, '0')}`,
        idempotency_key: newIdempotencyKey(),
      });
    }
  }

  // Monthly running costs.
  const expenseTemplate = [
    { category: 'Electricity', amounts: [9_420_00, 5_870_00] },
    { category: 'Groceries', amounts: [21_250_00, 12_600_00] },
    { category: 'Salaries', amounts: [16_000_00, 9_000_00] },
    { category: 'Internet', amounts: [1_180_00, 885_00] },
    { category: 'Water', amounts: [1_550_00, 825_00] },
  ];
  for (let m = 3; m >= 0; m--) {
    for (const [pIndex, propertyId] of propertyIds.entries()) {
      for (const [i, e] of expenseTemplate.entries()) {
        const date = dateIn(m, 3 + i * 4);
        if (date > today) continue;
        await api.createExpense(tenantId, {
          property_id: propertyId,
          category: e.category,
          amount_paise: e.amounts[pIndex]! + m * 7_500,
          expense_date: date,
          payee: e.category === 'Salaries' ? 'Staff payroll' : `${e.category} vendor`,
          method: e.category === 'Salaries' ? 'bank_transfer' : 'upi',
        });
      }
    }
  }
  await api.createExpense(tenantId, {
    property_id: propertyIds[0]!,
    category: 'Maintenance',
    amount_paise: 6_800_00,
    expense_date: dateIn(1, 18),
    payee: 'Plumbing repairs',
    method: 'cash',
    notes: 'Bathroom pipe replacement, room 203',
  });

  await api.setOnboardingStep(tenantId, 'done');
  await db.query('insert into demo_meta.applied (name) values ($1)', [SEED_MARKER]);
  return { userId, tenantId };
}
