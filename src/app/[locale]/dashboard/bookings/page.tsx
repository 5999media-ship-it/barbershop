import { Badge, Card } from '@/components/ui'
import BookingActions from '@/components/dashboard/BookingActions'
import { getDashboardContext } from '@/lib/dashboard'
import { createClient } from '@/lib/supabase/server'
import { formatDateTime, formatMoney } from '@/lib/format'
import type { Barber, Booking, Service } from '@/lib/supabase/database.types'

export const dynamic = 'force-dynamic'

type Row = Booking & {
  barbers: Pick<Barber, 'display_name'> | null
  services: Pick<Service, 'name'> | null
}

export default async function BookingsPage({
  searchParams,
}: {
  searchParams: Promise<{ filter?: string }>
}) {
  const ctx = await getDashboardContext()
  const { filter } = await searchParams
  const supabase = await createClient()

  const showPast = filter === 'verleden'
  const now = new Date().toISOString()

  let query = supabase
    .from('bookings')
    .select('*, barbers(display_name), services(name)')
    .eq('shop_id', ctx.shop.id)
    .limit(100)

  query = showPast
    ? query.lt('starts_at', now).order('starts_at', { ascending: false })
    : query.gte('starts_at', now).order('starts_at')

  const { data } = await query
  const bookings = (data ?? []) as Row[]

  return (
    <>
      <header className="mb-6">
        <h1 className="text-2xl font-semibold">Afspraken</h1>
        <nav className="mt-3 flex gap-2 text-sm">
          <FilterLink active={!showPast} href="/dashboard/bookings" label="Aankomend" />
          <FilterLink
            active={showPast}
            href="/dashboard/bookings?filter=verleden"
            label="Verleden"
          />
        </nav>
      </header>

      {bookings.length === 0 ? (
        <Card className="text-center text-ink-400">Niets te zien hier.</Card>
      ) : (
        <ul className="space-y-2">
          {bookings.map((b) => (
            <li key={b.id}>
              <Card className="flex flex-wrap items-center justify-between gap-4">
                <div>
                  <p className="font-medium">
                    {b.customer_name}{' '}
                    <span className="font-normal text-ink-400">· {b.services?.name}</span>
                  </p>
                  <p className="mt-0.5 text-sm capitalize text-ink-300">
                    {formatDateTime(b.starts_at, ctx.shop.timezone)}
                  </p>
                  <p className="mt-1 text-xs text-ink-400">
                    {b.barbers?.display_name} · {b.customer_phone} ·{' '}
                    {formatMoney(b.price_cents, b.currency)}
                  </p>
                  {b.cancel_reason && (
                    <p className="mt-1 text-xs text-danger-500">Reden: {b.cancel_reason}</p>
                  )}
                </div>
                <div className="flex items-center gap-3">
                  <StatusBadge status={b.status} />
                  {!showPast && (b.status === 'confirmed' || b.status === 'pending') && (
                    <BookingActions bookingId={b.id} />
                  )}
                </div>
              </Card>
            </li>
          ))}
        </ul>
      )}
    </>
  )
}

function FilterLink({ active, href, label }: { active: boolean; href: string; label: string }) {
  return (
    <a
      href={href}
      className={`rounded-full border px-3.5 py-1.5 ${
        active
          ? 'border-brass-500 bg-brass-500/10 text-brass-300'
          : 'border-ink-700 text-ink-300 hover:border-ink-600'
      }`}
    >
      {label}
    </a>
  )
}

function StatusBadge({ status }: { status: Booking['status'] }) {
  const map = {
    pending: { label: 'Open', tone: 'neutral' },
    confirmed: { label: 'Bevestigd', tone: 'success' },
    completed: { label: 'Klaar', tone: 'neutral' },
    cancelled: { label: 'Geannuleerd', tone: 'danger' },
    no_show: { label: 'No-show', tone: 'danger' },
  } as const
  return <Badge tone={map[status].tone}>{map[status].label}</Badge>
}
