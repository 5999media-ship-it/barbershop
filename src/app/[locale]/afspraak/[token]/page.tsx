import type { Metadata } from 'next'
import { Link } from '@/i18n/navigation'
import { notFound } from 'next/navigation'

import ManageBooking from '@/components/booking/ManageBooking'
import { createClient } from '@/lib/supabase/server'
import type { BookingDetail } from '@/lib/supabase/database.types'

type Params = Promise<{ token: string }>

// Deze pagina bevat persoonsgegevens: nooit indexeren, nooit cachen.
export const metadata: Metadata = {
  title: 'Jouw afspraak',
  robots: { index: false, follow: false, nocache: true },
}
export const dynamic = 'force-dynamic'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export default async function ManageBookingPage({ params }: { params: Params }) {
  const { token } = await params
  if (!UUID.test(token)) notFound()

  const supabase = await createClient()
  const { data } = await supabase.rpc('get_booking_by_token', { p_token: token })
  const booking = data as BookingDetail | null

  if (!booking) {
    return (
      <main className="mx-auto max-w-md px-5 py-20 text-center">
        <h1 className="text-2xl font-semibold">Afspraak niet gevonden</h1>
        <p className="mt-3 text-ink-300">
          Deze link klopt niet of is verlopen. Staat je afspraak wel in je mailbox?
          Gebruik dan de link uit de bevestigingsmail.
        </p>
        <Link href="/" className="mt-6 inline-block text-brass-300 hover:underline">
          Naar de homepage
        </Link>
      </main>
    )
  }

  return (
    <main className="mx-auto max-w-lg px-5 pb-24 pt-12">
      <ManageBooking token={token} booking={booking} />
    </main>
  )
}
