'use client'

import { useActionState } from 'react'

import { Button } from '@/components/ui'
import { updateBookingStatus, type ActionState } from '@/app/dashboard/actions'

/**
 * Statusknoppen bij een afspraak. Bewust drie losse forms in plaats van één
 * form met een select: één klik, geen bevestigingsdialoog nodig voor iets dat
 * volledig omkeerbaar is.
 */
export default function BookingActions({ bookingId }: { bookingId: string }) {
  const [state, formAction, pending] = useActionState<ActionState, FormData>(
    updateBookingStatus,
    {},
  )

  return (
    <div className="flex items-center gap-2">
      {state.error && <span className="text-xs text-danger-500">{state.error}</span>}

      <form action={formAction}>
        <input type="hidden" name="bookingId" value={bookingId} />
        <input type="hidden" name="status" value="completed" />
        <Button size="sm" variant="subtle" type="submit" disabled={pending}>
          Klaar
        </Button>
      </form>

      <form action={formAction}>
        <input type="hidden" name="bookingId" value={bookingId} />
        <input type="hidden" name="status" value="no_show" />
        <Button size="sm" variant="ghost" type="submit" disabled={pending}>
          No-show
        </Button>
      </form>

      <form action={formAction}>
        <input type="hidden" name="bookingId" value={bookingId} />
        <input type="hidden" name="status" value="cancelled" />
        <Button size="sm" variant="danger" type="submit" disabled={pending}>
          Annuleren
        </Button>
      </form>
    </div>
  )
}
