import { Link } from '@/i18n/navigation'

import { Badge, Card } from '@/components/ui'
import BookingActions from '@/components/dashboard/BookingActions'
import { getDashboardContext } from '@/lib/dashboard'
import { createClient } from '@/lib/supabase/server'
import {
  addDays,
  formatMoney,
  formatTime,
  friendlyDay,
  isoDateInZone,
  zonedDayRange,
} from '@/lib/format'
import type { Barber, Booking, Service } from '@/lib/supabase/database.types'

export const dynamic = 'force-dynamic'

type Row = Booking & { barbers: Pick<Barber, 'display_name'> | null; services: Pick<Service, 'name'> | null }

export default async function AgendaPage({
  searchParams,
}: {
  searchParams: Promise<{ dag?: string }>
}) {
  const ctx = await getDashboardContext()
  const { dag } = await searchParams
  const supabase = await createClient()

  const tz = ctx.shop.timezone
  const today = isoDateInZone(new Date(), tz)
  const day = dag && /^\d{4}-\d{2}-\d{2}$/.test(dag) ? dag : today

  // Het dagvenster wordt omgerekend naar absolute momenten. Een kale
  // "2026-08-05T00:00:00" zou door Postgres als UTC gelezen worden en dan mist
  // de agenda in Amsterdam de eerste twee uur van de dag.
  const [from, to] = zonedDayRange(day, tz)

  const { data } = await supabase
    .from('bookings')
    .select('*, barbers(display_name), services(name)')
    .eq('shop_id', ctx.shop.id)
    .gte('starts_at', from)
    .lt('starts_at', to)
    .order('starts_at')

  const bookings = (data ?? []) as Row[]
  const active = bookings.filter((b) => b.status === 'confirmed' || b.status === 'pending')
  const revenue = active.reduce((sum, b) => sum + b.price_cents, 0)

  const days = Array.from({ length: 7 }, (_, i) => isoDateInZone(addDays(new Date(), i), tz))

  return (
    <>
      <header className="mb-6 flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Agenda</h1>
          <p className="mt-1 text-sm text-ink-400">
            {active.length} {active.length === 1 ? 'afspraak' : 'afspraken'} · omzetverwachting{' '}
            {formatMoney(revenue, ctx.shop.currency)}
          </p>
        </div>
      </header>

      <nav className="-mx-1 mb-6 flex gap-2 overflow-x-auto px-1 pb-2">
        {days.map((d) => (
          <Link
            key={d}
            href={`/dashboard?dag=${d}`}
            className={`shrink-0 rounded-[12px] border px-4 py-2.5 text-sm capitalize ${
              d === day
                ? 'border-brass-500 bg-brass-500/10 text-brass-300'
                : 'border-ink-700 text-ink-300 hover:border-ink-600'
            }`}
          >
            {friendlyDay(d, tz)}
          </Link>
        ))}
      </nav>

      {bookings.length === 0 ? (
        <Card className="text-center text-ink-400">
          Nog geen afspraken op deze dag.
        </Card>
      ) : (
        <ul className="space-y-2">
          {bookings.map((b) => (
            <li key={b.id}>
              <Card className="flex flex-wrap items-center justify-between gap-4">
                <div className="flex items-center gap-4">
                  <div className="w-16 shrink-0 text-center">
                    <p className="text-lg font-semibold text-brass-300">
                      {formatTime(b.starts_at, tz)}
                    </p>
                    <p className="text-xs text-ink-400">{formatTime(b.service_end_at, tz)}</p>
                  </div>
                  <div>
                    <p className="font-medium">{b.customer_name}</p>
                    <p className="text-sm text-ink-400">
                      {b.services?.name} · {b.barbers?.display_name}
                    </p>
                    {b.notes && <p className="mt-1 text-sm text-ink-300">“{b.notes}”</p>}
                    <p className="mt-1 text-xs text-ink-400">
                      {b.customer_phone} · {b.customer_email}
                    </p>
                  </div>
                </div>

                <div className="flex items-center gap-3">
                  <StatusBadge status={b.status} />
                  {(b.status === 'confirmed' || b.status === 'pending') && (
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

function StatusBadge({ status }: { status: Booking['status'] }) {
  const map = {
    pending: { label: 'Open', tone: 'neutral' },
    confirmed: { label: 'Bevestigd', tone: 'success' },
    completed: { label: 'Klaar', tone: 'neutral' },
    cancelled: { label: 'Geannuleerd', tone: 'danger' },
    no_show: { label: 'No-show', tone: 'danger' },
  } as const
  const item = map[status]
  return <Badge tone={item.tone}>{item.label}</Badge>
}
