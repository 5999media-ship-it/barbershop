'use server'

import { revalidatePath } from 'next/cache'
import { z } from 'zod'

import { createClient } from '@/lib/supabase/server'
import { createAdminClient } from '@/lib/supabase/admin'
import { citySlug } from '@/lib/slug'

export type ActionState = { error?: string; message?: string }

/** Slug voor namen: hergebruikt dezelfde normalisatie als de stadsslug. */
function slugify(value: string): string {
  return citySlug(value).slice(0, 60)
}

/**
 * Alle acties hieronder draaien met de sessie van de ingelogde gebruiker.
 * Er staat bewust geen enkele rolcontrole in deze functies: de RLS-policies
 * (can_manage_shop / is_shop_staff) doen dat werk. Twee plekken met dezelfde
 * regel is één plek te veel — die lopen vroeg of laat uit elkaar.
 */

// ---------------------------------------------------------------------------
// Afspraken
// ---------------------------------------------------------------------------
const statusSchema = z.object({
  bookingId: z.string().uuid(),
  status: z.enum(['confirmed', 'completed', 'cancelled', 'no_show']),
})

export async function updateBookingStatus(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const parsed = statusSchema.safeParse({
    bookingId: formData.get('bookingId'),
    status: formData.get('status'),
  })
  if (!parsed.success) return { error: 'Ongeldige actie.' }

  const supabase = await createClient()
  const patch: Record<string, unknown> = { status: parsed.data.status }
  if (parsed.data.status === 'cancelled') {
    patch.cancelled_at = new Date().toISOString()
    patch.cancelled_by = 'shop'
  }

  const { error } = await supabase.from('bookings').update(patch).eq('id', parsed.data.bookingId)
  if (error) return { error: 'Bijwerken lukte niet. Heb je hier rechten voor?' }

  revalidatePath('/dashboard')
  revalidatePath('/dashboard/bookings')
  return { message: 'Bijgewerkt.' }
}

// ---------------------------------------------------------------------------
// Behandelingen
// ---------------------------------------------------------------------------
const serviceSchema = z.object({
  shopId: z.string().uuid(),
  id: z.string().uuid().optional().or(z.literal('')),
  name: z.string().trim().min(2).max(100),
  description: z.string().trim().max(1000).optional().or(z.literal('')),
  durationMinutes: z.coerce.number().int().min(5).max(480),
  bufferMinutes: z.coerce.number().int().min(0).max(120),
  priceEuro: z.coerce.number().min(0).max(10000),
  isActive: z.coerce.boolean(),
})

export async function saveService(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const parsed = serviceSchema.safeParse({
    shopId: formData.get('shopId'),
    id: formData.get('id') ?? '',
    name: formData.get('name'),
    description: formData.get('description') ?? '',
    durationMinutes: formData.get('durationMinutes'),
    bufferMinutes: formData.get('bufferMinutes') ?? 0,
    priceEuro: formData.get('priceEuro'),
    isActive: formData.get('isActive') === 'on',
  })
  if (!parsed.success) return { error: 'Controleer de ingevulde velden.' }

  const d = parsed.data
  const supabase = await createClient()

  const row = {
    shop_id: d.shopId,
    slug: slugify(d.name),
    name: d.name,
    description: d.description || null,
    duration_minutes: d.durationMinutes,
    buffer_after_minutes: d.bufferMinutes,
    // Cent-berekening via afronding: 24.95 * 100 is in floating point 2494.9999…
    price_cents: Math.round(d.priceEuro * 100),
    is_active: d.isActive,
  }

  const { error } = d.id
    ? await supabase.from('services').update(row).eq('id', d.id)
    : await supabase.from('services').insert(row)

  if (error) {
    return {
      error: error.code === '23505'
        ? 'Er bestaat al een behandeling met deze naam.'
        : 'Opslaan lukte niet.',
    }
  }

  revalidatePath('/dashboard/services')
  return { message: 'Opgeslagen.' }
}

// ---------------------------------------------------------------------------
// Team
// ---------------------------------------------------------------------------
const barberSchema = z.object({
  shopId: z.string().uuid(),
  id: z.string().uuid().optional().or(z.literal('')),
  displayName: z.string().trim().min(2).max(80),
  bio: z.string().trim().max(1000).optional().or(z.literal('')),
  isActive: z.coerce.boolean(),
  acceptsOnline: z.coerce.boolean(),
})

export async function saveBarber(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = barberSchema.safeParse({
    shopId: formData.get('shopId'),
    id: formData.get('id') ?? '',
    displayName: formData.get('displayName'),
    bio: formData.get('bio') ?? '',
    isActive: formData.get('isActive') === 'on',
    acceptsOnline: formData.get('acceptsOnline') === 'on',
  })
  if (!parsed.success) return { error: 'Controleer de ingevulde velden.' }

  const d = parsed.data
  const supabase = await createClient()

  const row = {
    shop_id: d.shopId,
    slug: slugify(d.displayName),
    display_name: d.displayName,
    bio: d.bio || null,
    is_active: d.isActive,
    accepts_online_bookings: d.acceptsOnline,
  }

  const { error } = d.id
    ? await supabase.from('barbers').update(row).eq('id', d.id)
    : await supabase.from('barbers').insert(row)

  if (error) return { error: 'Opslaan lukte niet.' }

  revalidatePath('/dashboard/barbers')
  return { message: 'Opgeslagen.' }
}

/** Koppelt of ontkoppelt een behandeling aan een barber. */
export async function toggleBarberService(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const barberId = String(formData.get('barberId') ?? '')
  const serviceId = String(formData.get('serviceId') ?? '')
  const enable = formData.get('enable') === 'true'

  if (!barberId || !serviceId) return { error: 'Ongeldige actie.' }

  const supabase = await createClient()
  const { error } = enable
    ? await supabase.from('barber_services').insert({ barber_id: barberId, service_id: serviceId })
    : await supabase
        .from('barber_services')
        .delete()
        .eq('barber_id', barberId)
        .eq('service_id', serviceId)

  if (error) return { error: 'Wijzigen lukte niet.' }

  revalidatePath('/dashboard/barbers')
  return { message: 'Bijgewerkt.' }
}

// ---------------------------------------------------------------------------
// Werktijden
// ---------------------------------------------------------------------------
export async function saveWorkingHours(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const barberId = String(formData.get('barberId') ?? '')
  if (!z.string().uuid().safeParse(barberId).success) return { error: 'Ongeldige barber.' }

  const rows: Array<{ barber_id: string; weekday: number; start_time: string; end_time: string }> = []

  for (let weekday = 0; weekday < 7; weekday++) {
    for (const block of ['a', 'b'] as const) {
      const start = String(formData.get(`start_${weekday}_${block}`) ?? '')
      const end = String(formData.get(`end_${weekday}_${block}`) ?? '')
      if (!start || !end) continue
      if (end <= start) {
        return { error: `De eindtijd op dag ${weekday} moet later zijn dan de starttijd.` }
      }
      rows.push({ barber_id: barberId, weekday, start_time: start, end_time: end })
    }
  }

  const supabase = await createClient()
  const { error: delError } = await supabase
    .from('working_hours')
    .delete()
    .eq('barber_id', barberId)
  if (delError) return { error: 'Opslaan lukte niet.' }

  if (rows.length > 0) {
    const { error } = await supabase.from('working_hours').insert(rows)
    if (error) return { error: 'Opslaan lukte niet.' }
  }

  revalidatePath('/dashboard/hours')
  return { message: 'Rooster opgeslagen.' }
}

// ---------------------------------------------------------------------------
// Instellingen
// ---------------------------------------------------------------------------
const settingsSchema = z.object({
  shopId: z.string().uuid(),
  name: z.string().trim().min(2).max(120),
  tagline: z.string().trim().max(160).optional().or(z.literal('')),
  description: z.string().trim().max(4000).optional().or(z.literal('')),
  phone: z.string().trim().max(30).optional().or(z.literal('')),
  email: z.string().trim().email().optional().or(z.literal('')),
  street: z.string().trim().max(120).optional().or(z.literal('')),
  houseNumber: z.string().trim().max(20).optional().or(z.literal('')),
  postalCode: z.string().trim().max(12).optional().or(z.literal('')),
  city: z.string().trim().max(80).optional().or(z.literal('')),
  slotInterval: z.coerce.number().int(),
  minLeadMinutes: z.coerce.number().int().min(0).max(43200),
  maxAdvanceDays: z.coerce.number().int().min(1).max(365),
  cancelCutoffHours: z.coerce.number().int().min(0).max(168),
  staffNotifyEmail: z.string().trim().email().optional().or(z.literal('')),
  isPublished: z.coerce.boolean(),
})

export async function saveShopSettings(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const parsed = settingsSchema.safeParse({
    shopId: formData.get('shopId'),
    name: formData.get('name'),
    tagline: formData.get('tagline') ?? '',
    description: formData.get('description') ?? '',
    phone: formData.get('phone') ?? '',
    email: formData.get('email') ?? '',
    street: formData.get('street') ?? '',
    houseNumber: formData.get('houseNumber') ?? '',
    postalCode: formData.get('postalCode') ?? '',
    city: formData.get('city') ?? '',
    slotInterval: formData.get('slotInterval'),
    minLeadMinutes: formData.get('minLeadMinutes'),
    maxAdvanceDays: formData.get('maxAdvanceDays'),
    cancelCutoffHours: formData.get('cancelCutoffHours'),
    staffNotifyEmail: formData.get('staffNotifyEmail') ?? '',
    isPublished: formData.get('isPublished') === 'on',
  })

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Controleer de ingevulde velden.' }
  }

  const d = parsed.data
  const supabase = await createClient()

  const { error } = await supabase
    .from('shops')
    .update({
      name: d.name,
      tagline: d.tagline || null,
      description: d.description || null,
      phone: d.phone || null,
      email: d.email || null,
      street: d.street || null,
      house_number: d.houseNumber || null,
      postal_code: d.postalCode || null,
      city: d.city || null,
      slot_interval_minutes: d.slotInterval,
      min_lead_minutes: d.minLeadMinutes,
      max_advance_days: d.maxAdvanceDays,
      cancel_cutoff_hours: d.cancelCutoffHours,
      staff_notify_email: d.staffNotifyEmail || null,
      is_published: d.isPublished,
    })
    .eq('id', d.shopId)

  if (error) return { error: 'Opslaan lukte niet. Heb je beheerdersrechten?' }

  revalidatePath('/dashboard/settings')
  revalidatePath('/', 'layout')
  return { message: 'Instellingen opgeslagen.' }
}

// ---------------------------------------------------------------------------
// Afbeeldingen
// ---------------------------------------------------------------------------
// De upload zelf gebeurt in de browser rechtstreeks naar Supabase Storage,
// onder de policies uit migratie 000700. Hier slaan we alleen de URL op — en
// ook dat gaat via RLS, dus iemand die een vreemde shop_id meestuurt krijgt
// simpelweg nul rijen bijgewerkt.

export async function saveShopLogo(shopId: string, url: string): Promise<ActionState> {
  if (!z.string().uuid().safeParse(shopId).success) return { error: 'Ongeldige salon.' }
  if (!z.string().url().max(500).safeParse(url).success) return { error: 'Ongeldige afbeelding.' }

  const supabase = await createClient()
  const { error } = await supabase.from('shops').update({ logo_url: url }).eq('id', shopId)
  if (error) return { error: 'Opslaan lukte niet.' }

  revalidatePath('/dashboard/settings')
  revalidatePath('/', 'layout')
  return { message: 'Logo opgeslagen.' }
}

export async function saveBarberAvatar(barberId: string, url: string): Promise<ActionState> {
  if (!z.string().uuid().safeParse(barberId).success) return { error: 'Ongeldige barber.' }
  if (!z.string().url().max(500).safeParse(url).success) return { error: 'Ongeldige afbeelding.' }

  const supabase = await createClient()
  const { error } = await supabase.from('barbers').update({ avatar_url: url }).eq('id', barberId)
  if (error) return { error: 'Opslaan lukte niet.' }

  revalidatePath('/dashboard/barbers')
  revalidatePath('/dashboard/profiel')
  revalidatePath('/', 'layout')
  return { message: 'Foto opgeslagen.' }
}

// ---------------------------------------------------------------------------
// Zelfbeheer voor de kapper
// ---------------------------------------------------------------------------
const selfProfileSchema = z.object({
  barberId: z.string().uuid(),
  bio: z.string().trim().max(1000).optional().or(z.literal('')),
  instagram: z.string().trim().max(100).optional().or(z.literal('')),
})

export async function saveOwnProfile(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const parsed = selfProfileSchema.safeParse({
    barberId: formData.get('barberId'),
    bio: formData.get('bio') ?? '',
    instagram: formData.get('instagram') ?? '',
  })
  if (!parsed.success) return { error: 'Controleer de ingevulde velden.' }

  const supabase = await createClient()
  // De trigger tg_barbers_guard zet alles behalve bio, avatar en instagram
  // terug, dus zelfs als hier per ongeluk meer velden bij komen te staan kan
  // een kapper zichzelf niet naar een andere salon verplaatsen.
  const { error } = await supabase
    .from('barbers')
    .update({
      bio: parsed.data.bio || null,
      instagram: parsed.data.instagram || null,
    })
    .eq('id', parsed.data.barberId)

  if (error) return { error: 'Opslaan lukte niet.' }

  revalidatePath('/dashboard/profiel')
  return { message: 'Opgeslagen.' }
}

export async function saveOwnPrice(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const barberId = String(formData.get('barberId') ?? '')
  const serviceId = String(formData.get('serviceId') ?? '')
  const priceEuro = Number(formData.get('priceEuro'))

  if (!z.string().uuid().safeParse(barberId).success) return { error: 'Ongeldige barber.' }
  if (!z.string().uuid().safeParse(serviceId).success) return { error: 'Ongeldige behandeling.' }
  if (!Number.isFinite(priceEuro) || priceEuro < 0 || priceEuro > 10000) {
    return { error: 'Vul een geldig bedrag in.' }
  }

  const supabase = await createClient()
  const { error } = await supabase
    .from('barber_services')
    .update({ price_cents: Math.round(priceEuro * 100) })
    .eq('barber_id', barberId)
    .eq('service_id', serviceId)

  if (error) return { error: 'Opslaan lukte niet.' }

  revalidatePath('/dashboard/profiel')
  return { message: 'Tarief opgeslagen.' }
}

// ---------------------------------------------------------------------------
// Teamleden koppelen op e-mailadres
// ---------------------------------------------------------------------------
export async function inviteMember(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const shopId = String(formData.get('shopId') ?? '')
  const email = String(formData.get('email') ?? '')
  const role = String(formData.get('role') ?? 'barber')

  if (!z.string().uuid().safeParse(shopId).success) return { error: 'Ongeldige salon.' }
  if (!z.string().email().safeParse(email).success) return { error: 'Vul een geldig e-mailadres in.' }
  if (!['barber', 'manager', 'shop_owner'].includes(role)) return { error: 'Ongeldige rol.' }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('invite_member', {
    p_shop_id: shopId,
    p_email: email,
    p_role: role,
  })

  if (error) return { error: error.hint ?? 'Koppelen lukte niet.' }

  const result = data as { ok: boolean; reason?: string; hint?: string }
  if (!result.ok) {
    return {
      error:
        result.reason === 'no_account'
          ? 'Deze persoon heeft nog geen account. Laat hem zich eerst registreren via de inlogpagina, daarna koppel je hem hier.'
          : 'Koppelen lukte niet.',
    }
  }

  revalidatePath('/dashboard/barbers')
  return { message: 'Gekoppeld aan deze salon.' }
}

// ---------------------------------------------------------------------------
// Platformbeheer
// ---------------------------------------------------------------------------
export async function togglePlatformAdmin(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const email = String(formData.get('email') ?? '')
  const value = formData.get('value') === 'true'

  if (!z.string().email().safeParse(email).success) return { error: 'Vul een geldig e-mailadres in.' }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('set_platform_admin', {
    p_email: email,
    p_value: value,
  })

  if (error) return { error: error.hint ?? 'Wijzigen lukte niet.' }

  const result = data as { ok: boolean; reason?: string }
  if (!result.ok) return { error: 'Er bestaat geen account met dit e-mailadres.' }

  revalidatePath('/dashboard/platform')
  return { message: value ? 'Toegevoegd als platformbeheerder.' : 'Rechten ingetrokken.' }
}

export async function setShopPublished(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const shopId = String(formData.get('shopId') ?? '')
  const value = formData.get('value') === 'true'
  if (!z.string().uuid().safeParse(shopId).success) return { error: 'Ongeldige salon.' }

  const supabase = await createClient()
  const { error } = await supabase.from('shops').update({ is_published: value }).eq('id', shopId)
  if (error) return { error: 'Wijzigen lukte niet.' }

  revalidatePath('/dashboard/platform')
  revalidatePath('/', 'layout')
  return { message: value ? 'Salon gepubliceerd.' : 'Salon offline gehaald.' }
}

// ---------------------------------------------------------------------------
// Salons aanmaken — alleen de platformbeheerder
// ---------------------------------------------------------------------------
const newShopSchema = z.object({
  name: z.string().trim().min(2).max(120),
  city: z.string().trim().min(2).max(80),
  ownerEmail: z.string().trim().email().optional().or(z.literal('')),
  timezone: z.string().trim().min(3).max(64),
  currency: z.string().trim().length(3),
})

export async function createShop(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = newShopSchema.safeParse({
    name: formData.get('name'),
    city: formData.get('city'),
    ownerEmail: formData.get('ownerEmail') ?? '',
    timezone: formData.get('timezone') ?? 'America/Curacao',
    currency: formData.get('currency') ?? 'ANG',
  })
  if (!parsed.success) return { error: 'Vul minimaal een naam en een plaats in.' }

  const supabase = await createClient()
  const { data, error } = await supabase.rpc('admin_create_shop', {
    p_name: parsed.data.name,
    p_city: parsed.data.city,
    p_owner_email: parsed.data.ownerEmail || null,
    p_timezone: parsed.data.timezone,
    p_currency: parsed.data.currency,
  })

  if (error) return { error: error.hint ?? 'Aanmaken lukte niet.' }

  const result = data as { ok: boolean; warning?: string; hint?: string }
  revalidatePath('/dashboard', 'layout')
  revalidatePath('/', 'layout')

  return result.warning === 'no_account'
    ? { message: result.hint ?? 'Salon aangemaakt.' }
    : { message: 'Salon aangemaakt.' }
}

// ---------------------------------------------------------------------------
// Account aanmaken voor een medewerker
// ---------------------------------------------------------------------------
// Een kapper die zijn eigen agenda wil beheren heeft een inlog nodig. In plaats
// van hem te laten registreren maak jij het account aan en geef je hem het
// wachtwoord. Dat kan alleen met de service-role sleutel, dus dit gebeurt hier
// op de server — met een eigen rechtencontrole ervoor, want die sleutel kent
// geen RLS.
const staffAccountSchema = z.object({
  shopId: z.string().uuid(),
  email: z.string().trim().toLowerCase().email(),
  password: z.string().min(10).max(200),
  fullName: z.string().trim().max(100).optional().or(z.literal('')),
  role: z.enum(['barber', 'manager', 'shop_owner']),
})

export async function createStaffAccount(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const parsed = staffAccountSchema.safeParse({
    shopId: formData.get('shopId'),
    email: formData.get('email'),
    password: formData.get('password'),
    fullName: formData.get('fullName') ?? '',
    role: formData.get('role') ?? 'barber',
  })
  if (!parsed.success) {
    return { error: 'Controleer het e-mailadres en gebruik een wachtwoord van minimaal 10 tekens.' }
  }

  const d = parsed.data
  const supabase = await createClient()

  // Rechtencontrole vóór we de service-role sleutel aanraken. can_manage_shop
  // draait onder de sessie van de gebruiker, dus dit is dezelfde regel als
  // overal elders — niet een tweede, afwijkende kopie ervan.
  const { data: allowed } = await supabase.rpc('can_manage_shop', { p_shop_id: d.shopId })
  if (allowed !== true) return { error: 'Je hebt geen beheerrechten voor deze salon.' }

  const admin = createAdminClient()
  const { error: createError } = await admin.auth.admin.createUser({
    email: d.email,
    password: d.password,
    email_confirm: true, // geen bevestigingsmail: jij geeft de inlog persoonlijk door
    user_metadata: { full_name: d.fullName || null },
  })

  // Bestaat het account al? Dan is koppelen alsnog prima; alleen het
  // wachtwoord blijft dan wat het was.
  const alreadyExists =
    createError?.message?.toLowerCase().includes('already') ||
    createError?.message?.toLowerCase().includes('registered')

  if (createError && !alreadyExists) {
    console.error('[createStaffAccount]', createError)
    return { error: 'Het account kon niet aangemaakt worden.' }
  }

  const { data: linked, error: linkError } = await supabase.rpc('invite_member', {
    p_shop_id: d.shopId,
    p_email: d.email,
    p_role: d.role,
  })

  if (linkError) return { error: linkError.hint ?? 'Koppelen lukte niet.' }
  if (!(linked as { ok: boolean }).ok) return { error: 'Koppelen lukte niet.' }

  revalidatePath('/dashboard/barbers')

  return {
    message: alreadyExists
      ? 'Dit account bestond al en is nu aan de salon gekoppeld.'
      : `Account aangemaakt en gekoppeld. Geef ${d.email} het wachtwoord door.`,
  }
}
