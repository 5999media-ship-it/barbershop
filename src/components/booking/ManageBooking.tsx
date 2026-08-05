'use client'

import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { Link } from '@/i18n/navigation'

import { Alert, Badge, Button, Card, Textarea } from '@/components/ui'
import type { BookingDetail } from '@/lib/supabase/database.types'
import { formatDateTime, formatMoney, formatTime } from '@/lib/format'
import { citySlug } from '@/lib/slug'

const STATUS_LABEL: Record<BookingDetail['status'], { text: string; tone: 'success' | 'danger' | 'neutral' }> = {
  pending: { text: 'In afwachting', tone: 'neutral' },
  confirmed: { text: 'Bevestigd', tone: 'success' },
  completed: { text: 'Afgerond', tone: 'neutral' },
  cancelled: { text: 'Geannuleerd', tone: 'danger' },
  no_show: { text: 'Niet verschenen', tone: 'danger' },
}

export default function ManageBooking({
  token,
  booking,
}: {
  token: string
  booking: BookingDetail
}) {
  const router = useRouter()
  const [confirming, setConfirming] = useState(false)
  const [reason, setReason] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const status = STATUS_LABEL[booking.status]
  const tz = booking.shop_timezone

  async function cancel() {
    setBusy(true)
    setError(null)
    try {
      const res = await fetch(`/api/booking/${token}`, {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ reason }),
      })
      const payload = (await res.json()) as { ok: boolean; error?: string }
      if (!res.ok || !payload.ok) {
        setError(payload.error ?? 'Annuleren lukte niet.')
        return
      }
      router.refresh()
      setConfirming(false)
    } catch {
      setError('Geen verbinding. Probeer het opnieuw.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <header className="mb-7">
        <div className="mb-3 flex items-center gap-3">
          <h1 className="text-3xl font-semibold tracking-tight">Jouw afspraak</h1>
          <Badge tone={status.tone}>{status.text}</Badge>
        </div>
        <p className="text-ink-300">
          {booking.shop_name}
          {booking.shop_address ? ` · ${booking.shop_address}` : ''}
        </p>
      </header>

      {error && (
        <div className="mb-5">
          <Alert>{error}</Alert>
        </div>
      )}

      <Card className="mb-6">
        <dl className="space-y-3 text-sm">
          <Row label="Wanneer" value={formatDateTime(booking.starts_at, tz)} />
          <Row
            label="Tot ongeveer"
            value={formatTime(booking.service_end_at, tz)}
          />
          <Row label="Behandeling" value={booking.service_name} />
          <Row label="Barber" value={booking.barber_name} />
          <Row label="Op naam van" value={booking.customer_name} />
          <Row
            label="Prijs"
            value={`${formatMoney(booking.price_cents, booking.currency)} — te betalen in de zaak`}
          />
          {booking.notes && <Row label="Jouw opmerking" value={booking.notes} />}
        </dl>
      </Card>

      {booking.status === 'confirmed' || booking.status === 'pending' ? (
        booking.can_modify ? (
          <>
            {!confirming ? (
              <div className="flex flex-wrap gap-3">
                <Button variant="danger" onClick={() => setConfirming(true)}>
                  Afspraak annuleren
                </Button>
                <Link href={`/kapper/${citySlug(booking.shop_city)}/${booking.shop_slug}/boeken`}>
                  <Button variant="ghost">Nieuwe afspraak maken</Button>
                </Link>
              </div>
            ) : (
              <Card>
                <p className="mb-3 font-medium">Zeker weten dat je wilt annuleren?</p>
                <p className="mb-4 text-sm text-ink-400">
                  De plek komt direct weer vrij voor iemand anders. Je kunt daarna altijd
                  opnieuw boeken.
                </p>
                <Textarea
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  maxLength={500}
                  placeholder="Reden (optioneel) — helpt de salon om te plannen"
                />
                <div className="mt-4 flex gap-3">
                  <Button variant="danger" onClick={() => void cancel()} disabled={busy}>
                    {busy ? 'Bezig…' : 'Ja, annuleren'}
                  </Button>
                  <Button variant="ghost" onClick={() => setConfirming(false)} disabled={busy}>
                    Nee, laat maar staan
                  </Button>
                </div>
              </Card>
            )}
            <p className="mt-4 text-xs text-ink-400">
              Online annuleren kan tot {formatDateTime(booking.cancel_deadline, tz)}. Daarna
              even bellen{booking.shop_phone ? ` naar ${booking.shop_phone}` : ''}.
            </p>
          </>
        ) : (
          <Alert tone="info">
            Het is te kort dag om nog online te wijzigen. Bel de salon
            {booking.shop_phone ? (
              <>
                {' '}
                op{' '}
                <a href={`tel:${booking.shop_phone.replace(/\s/g, '')}`} className="underline">
                  {booking.shop_phone}
                </a>
              </>
            ) : null}
            .
          </Alert>
        )
      ) : (
        <Alert tone="info">
          Deze afspraak is {status.text.toLowerCase()}.{' '}
          <Link href={`/kapper/${citySlug(booking.shop_city)}/${booking.shop_slug}/boeken`} className="underline">
            Maak een nieuwe afspraak
          </Link>
          .
        </Alert>
      )}
    </>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-6">
      <dt className="shrink-0 text-ink-400">{label}</dt>
      <dd className="text-right">{value}</dd>
    </div>
  )
}
