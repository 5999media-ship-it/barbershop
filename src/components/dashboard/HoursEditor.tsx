'use client'

import { useActionState } from 'react'
import { useRouter } from 'next/navigation'

import { Alert, Button, Card } from '@/components/ui'
import { saveWorkingHours, type ActionState } from '@/actions/dashboard'
import { WEEKDAYS_NL } from '@/lib/format'
import type { Barber, WorkingHour } from '@/lib/supabase/database.types'

const DAY_ORDER = [1, 2, 3, 4, 5, 6, 0] // maandag eerst, zoals in Nederland

export default function HoursEditor({
  barbers,
  selected,
  hours,
}: {
  barbers: Barber[]
  selected: Barber
  hours: WorkingHour[]
}) {
  const router = useRouter()
  const [state, formAction, pending] = useActionState<ActionState, FormData>(
    saveWorkingHours,
    {},
  )

  // Per dag maximaal twee blokken tonen, gesorteerd op starttijd.
  const byDay = new Map<number, WorkingHour[]>()
  for (const h of hours) {
    const list = byDay.get(h.weekday) ?? []
    list.push(h)
    byDay.set(h.weekday, list)
  }
  for (const list of byDay.values()) list.sort((a, b) => a.start_time.localeCompare(b.start_time))

  return (
    <>
      {barbers.length > 1 && (
        <div className="mb-5 flex flex-wrap gap-2">
          {barbers.map((b) => (
            <button
              key={b.id}
              type="button"
              onClick={() => router.push(`/dashboard/hours?barber=${b.id}`)}
              className={`rounded-full border px-3.5 py-1.5 text-sm ${
                b.id === selected.id
                  ? 'border-brass-500 bg-brass-500/10 text-brass-300'
                  : 'border-ink-700 text-ink-300 hover:border-ink-600'
              }`}
            >
              {b.display_name}
            </button>
          ))}
        </div>
      )}

      {state.error && (
        <div className="mb-4">
          <Alert>{state.error}</Alert>
        </div>
      )}
      {state.message && (
        <div className="mb-4">
          <Alert tone="success">{state.message}</Alert>
        </div>
      )}

      <Card>
        <form action={formAction} className="space-y-1">
          <input type="hidden" name="barberId" value={selected.id} />

          <div className="hidden grid-cols-[7rem_1fr_1fr] gap-3 pb-2 text-xs uppercase tracking-wider text-ink-400 sm:grid">
            <span>Dag</span>
            <span>Ochtendblok</span>
            <span>Middagblok</span>
          </div>

          {DAY_ORDER.map((weekday) => {
            const blocks = byDay.get(weekday) ?? []
            return (
              <div
                key={weekday}
                className="grid gap-3 border-b border-ink-800 py-3 last:border-0 sm:grid-cols-[7rem_1fr_1fr] sm:items-center"
              >
                <span className="text-sm font-medium capitalize">{WEEKDAYS_NL[weekday]}</span>
                <TimeRange weekday={weekday} block="a" value={blocks[0]} />
                <TimeRange weekday={weekday} block="b" value={blocks[1]} />
              </div>
            )
          })}

          <div className="pt-4">
            <Button type="submit" disabled={pending}>
              {pending ? 'Opslaan…' : 'Rooster opslaan'}
            </Button>
          </div>
        </form>
      </Card>
    </>
  )
}

function TimeRange({
  weekday,
  block,
  value,
}: {
  weekday: number
  block: 'a' | 'b'
  value?: WorkingHour
}) {
  return (
    <div className="flex items-center gap-2">
      <input
        type="time"
        name={`start_${weekday}_${block}`}
        defaultValue={value?.start_time.slice(0, 5) ?? ''}
        aria-label={`Starttijd blok ${block} op dag ${weekday}`}
        className="w-full rounded-[8px] border border-ink-600 bg-ink-850 px-2.5 py-2 text-sm"
      />
      <span className="text-ink-400">–</span>
      <input
        type="time"
        name={`end_${weekday}_${block}`}
        defaultValue={value?.end_time.slice(0, 5) ?? ''}
        aria-label={`Eindtijd blok ${block} op dag ${weekday}`}
        className="w-full rounded-[8px] border border-ink-600 bg-ink-850 px-2.5 py-2 text-sm"
      />
    </div>
  )
}
