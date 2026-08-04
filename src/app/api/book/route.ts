import { NextResponse, type NextRequest } from 'next/server'

import { createAdminClient } from '@/lib/supabase/admin'
import { createClient } from '@/lib/supabase/server'
import { bookingRequestSchema, humanizeDbError } from '@/lib/validation'
import type { CreatedBooking } from '@/lib/supabase/database.types'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

/** Fouten waarbij het zinvol is de agenda opnieuw te laden. */
const RECOVERABLE = new Set(['slot_taken', 'slot_unavailable'])

/**
 * POST /api/book
 *
 * Waarom loopt dit via de server en niet rechtstreeks vanuit de browser naar
 * Supabase?
 *  1. Het IP-adres is alleen hier bekend. Rate limiting op alleen e-mail is
 *     waardeloos — die verzin je zo.
 *  2. register_booking_attempt() moet in een eigen transactie committen, ook
 *     als create_booking daarna faalt. Dat kan alleen met twee losse calls.
 *  3. De honeypot en de foutvertaling horen niet in de client-bundle.
 */
export async function POST(request: NextRequest) {
  let body: unknown
  try {
    body = await request.json()
  } catch {
    return NextResponse.json({ ok: false, error: 'Ongeldig verzoek.' }, { status: 400 })
  }

  const parsed = bookingRequestSchema.safeParse(body)
  if (!parsed.success) {
    const first = parsed.error.issues[0]
    return NextResponse.json(
      { ok: false, error: first?.message ?? 'Controleer je gegevens.' },
      { status: 422 },
    )
  }

  const input = parsed.data

  // Honeypot: een echt mens ziet dit veld nooit. Bewust dezelfde succesvorm
  // teruggeven zou beter zijn tegen slimme bots, maar dan denkt een gebruiker
  // met een agressieve autofill dat hij geboekt heeft. Dus: nette weigering.
  if (input.website) {
    return NextResponse.json({ ok: false, error: 'Verzoek geweigerd.' }, { status: 400 })
  }

  const ip = clientIp(request)

  // --- Laag 1: rate limiting in een eigen transactie ------------------------
  const admin = createAdminClient()
  const { data: allowed, error: rateError } = await admin.rpc('register_booking_attempt', {
    p_shop_id: input.shopId,
    p_email: input.email,
    p_fingerprint: ip,
    p_max_per_hour: 8,
  })

  if (rateError) {
    console.error('[book] rate limit check faalde', rateError)
    return NextResponse.json(
      { ok: false, error: 'Er ging iets mis. Probeer het zo nog eens.' },
      { status: 500 },
    )
  }

  if (allowed === false) {
    return NextResponse.json(
      {
        ok: false,
        error: 'Te veel pogingen vanaf dit adres. Probeer het over een uur opnieuw of bel de salon.',
      },
      { status: 429 },
    )
  }

  // --- Laag 2: de boeking zelf ---------------------------------------------
  // create_booking is bewust NIET aan anon gegeven. Zou dat wel zo zijn, dan
  // roept een aanvaller de RPC rechtstreeks aan met de publieke key en slaat
  // hij de honeypot, het echte IP en de rate limiting hierboven volledig over.
  // Daarom gaat de aanroep via service_role — de functie zelf is SECURITY
  // DEFINER en valideert alles alsnog serverside.
  //
  // Is de bezoeker ingelogd, dan koppelen we de boeking aan zijn account. Het
  // id komt uit getUser() (dat het token bij Supabase verifieert), nooit uit
  // de request body.
  const supabase = await createClient()
  const {
    data: { user },
  } = await supabase.auth.getUser()

  const { data, error } = await admin.rpc('create_booking', {
    p_shop_id: input.shopId,
    p_service_id: input.serviceId,
    p_starts_at: input.startsAt,
    p_customer_name: input.name,
    p_customer_email: input.email,
    p_customer_phone: input.phone,
    p_barber_id: input.barberId ?? null,
    p_notes: input.notes || null,
    p_client_fingerprint: ip,
    p_customer_id: user?.id ?? null,
  })

  if (error) {
    const code = error.message
    const status = RECOVERABLE.has(code) ? 409 : code === 'rate_limited' ? 429 : 400
    return NextResponse.json(
      {
        ok: false,
        error: humanizeDbError(code, error.hint),
        recoverable: RECOVERABLE.has(code),
      },
      { status },
    )
  }

  return NextResponse.json({ ok: true, booking: data as CreatedBooking }, { status: 201 })
}

/**
 * Achter Vercel/Cloudflare is x-forwarded-for een lijst; het eerste adres is
 * de client. Val terug op een vaste string zodat de rate limiter nooit stuk
 * gaat op een ontbrekende header (in dat geval wordt er alleen op e-mail
 * gelimiteerd).
 */
function clientIp(request: NextRequest): string {
  // Op Vercel is x-vercel-forwarded-for door het platform gezet en niet door
  // de client te vervalsen; die heeft dus voorrang. Draai je elders, gebruik
  // dan de header die jouw proxy garandeert en vertrouw x-forwarded-for niet
  // blind — die is spoofbaar zodra verkeer de proxy kan omzeilen.
  const trusted = request.headers.get('x-vercel-forwarded-for')
  if (trusted) return trusted.split(',')[0]!.trim()

  const forwarded = request.headers.get('x-forwarded-for')
  if (forwarded) {
    const first = forwarded.split(',')[0]?.trim()
    if (first) return first
  }
  return request.headers.get('x-real-ip') ?? 'unknown'
}
