import { NextResponse, type NextRequest } from 'next/server'

import { createClient } from '@/lib/supabase/server'
import { cancelRequestSchema, humanizeDbError, rescheduleRequestSchema } from '@/lib/validation'

export const runtime = 'nodejs'
export const dynamic = 'force-dynamic'

type Ctx = { params: Promise<{ token: string }> }

/** DELETE /api/booking/:token — annuleren */
export async function DELETE(request: NextRequest, { params }: Ctx) {
  const { token } = await params
  let reason = ''
  try {
    const body = (await request.json()) as { reason?: string }
    reason = body.reason ?? ''
  } catch {
    // body is optioneel
  }

  const parsed = cancelRequestSchema.safeParse({ token, reason })
  if (!parsed.success) {
    return NextResponse.json({ ok: false, error: 'Ongeldige link.' }, { status: 400 })
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('cancel_booking_by_token', {
    p_token: parsed.data.token,
    p_reason: parsed.data.reason || null,
  })

  if (error) {
    return NextResponse.json(
      { ok: false, error: humanizeDbError(error.message, error.hint) },
      { status: 400 },
    )
  }

  return NextResponse.json({ ok: true })
}

/** PATCH /api/booking/:token — verzetten */
export async function PATCH(request: NextRequest, { params }: Ctx) {
  const { token } = await params

  let body: unknown
  try {
    body = await request.json()
  } catch {
    return NextResponse.json({ ok: false, error: 'Ongeldig verzoek.' }, { status: 400 })
  }

  const parsed = rescheduleRequestSchema.safeParse({ ...(body as object), token })
  if (!parsed.success) {
    return NextResponse.json({ ok: false, error: 'Kies een geldig tijdstip.' }, { status: 422 })
  }

  const supabase = await createClient()
  const { error } = await supabase.rpc('reschedule_booking_by_token', {
    p_token: parsed.data.token,
    p_starts_at: parsed.data.startsAt,
    p_barber_id: parsed.data.barberId ?? null,
  })

  if (error) {
    return NextResponse.json(
      { ok: false, error: humanizeDbError(error.message, error.hint) },
      { status: 400 },
    )
  }

  return NextResponse.json({ ok: true })
}
