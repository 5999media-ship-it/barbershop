'use client'

import { useActionState, useState } from 'react'

import { Alert, Badge, Button, Card, Field, Input, Textarea } from '@/components/ui'
import { saveBarber, toggleBarberService, type ActionState } from '@/app/dashboard/actions'
import type { Barber, Service } from '@/lib/supabase/database.types'

export default function BarberEditor({
  shopId,
  barbers,
  services,
  links,
}: {
  shopId: string
  barbers: Barber[]
  services: Service[]
  links: Array<{ barber_id: string; service_id: string }>
}) {
  const [editing, setEditing] = useState<Barber | 'new' | null>(null)
  const [state, formAction, pending] = useActionState<ActionState, FormData>(saveBarber, {})
  const [linkState, linkAction] = useActionState<ActionState, FormData>(toggleBarberService, {})

  const current = editing === 'new' ? null : editing
  const linked = new Set(links.map((l) => `${l.barber_id}:${l.service_id}`))

  return (
    <>
      {(state.error || linkState.error) && (
        <div className="mb-4">
          <Alert>{state.error ?? linkState.error}</Alert>
        </div>
      )}
      {state.message && (
        <div className="mb-4">
          <Alert tone="success">{state.message}</Alert>
        </div>
      )}

      <div className="mb-5">
        <Button onClick={() => setEditing('new')}>Barber toevoegen</Button>
      </div>

      {editing !== null && (
        <Card className="mb-6">
          <h2 className="mb-4 text-lg font-semibold">
            {current ? `${current.display_name} bewerken` : 'Nieuwe barber'}
          </h2>
          <form action={formAction} className="space-y-4">
            <input type="hidden" name="shopId" value={shopId} />
            <input type="hidden" name="id" value={current?.id ?? ''} />

            <Field label="Naam" required>
              <Input
                name="displayName"
                defaultValue={current?.display_name ?? ''}
                required
                maxLength={80}
              />
            </Field>
            <Field label="Korte introductie" hint="staat op de publieke pagina">
              <Textarea name="bio" defaultValue={current?.bio ?? ''} maxLength={1000} />
            </Field>

            <div className="space-y-2">
              <label className="flex items-center gap-2.5 text-sm">
                <input
                  type="checkbox"
                  name="isActive"
                  defaultChecked={current?.is_active ?? true}
                  className="h-4 w-4 accent-[#c8a45c]"
                />
                Actief
              </label>
              <label className="flex items-center gap-2.5 text-sm">
                <input
                  type="checkbox"
                  name="acceptsOnline"
                  defaultChecked={current?.accepts_online_bookings ?? true}
                  className="h-4 w-4 accent-[#c8a45c]"
                />
                Online boekbaar (uit = alleen telefonisch inplannen)
              </label>
            </div>

            <div className="flex gap-3 pt-1">
              <Button type="submit" disabled={pending}>
                {pending ? 'Opslaan…' : 'Opslaan'}
              </Button>
              <Button type="button" variant="ghost" onClick={() => setEditing(null)}>
                Annuleren
              </Button>
            </div>
          </form>
        </Card>
      )}

      <div className="space-y-3">
        {barbers.map((b) => (
          <Card key={b.id}>
            <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
              <div>
                <p className="flex items-center gap-2 font-medium">
                  {b.display_name}
                  {!b.is_active && <Badge tone="danger">Inactief</Badge>}
                  {b.is_active && !b.accepts_online_bookings && <Badge>Offline</Badge>}
                </p>
                {b.bio && <p className="mt-0.5 text-sm text-ink-400">{b.bio}</p>}
              </div>
              <Button size="sm" variant="ghost" onClick={() => setEditing(b)}>
                Bewerken
              </Button>
            </div>

            <p className="mb-2 text-xs uppercase tracking-wider text-ink-400">
              Doet deze behandelingen
            </p>
            <div className="flex flex-wrap gap-2">
              {services.map((s) => {
                const on = linked.has(`${b.id}:${s.id}`)
                return (
                  <form key={s.id} action={linkAction}>
                    <input type="hidden" name="barberId" value={b.id} />
                    <input type="hidden" name="serviceId" value={s.id} />
                    <input type="hidden" name="enable" value={String(!on)} />
                    <button
                      type="submit"
                      className={`rounded-full border px-3 py-1.5 text-xs transition ${
                        on
                          ? 'border-brass-500 bg-brass-500/15 text-brass-300'
                          : 'border-ink-700 text-ink-400 hover:border-ink-600'
                      }`}
                    >
                      {s.name}
                    </button>
                  </form>
                )
              })}
              {services.length === 0 && (
                <p className="text-sm text-ink-400">Maak eerst behandelingen aan.</p>
              )}
            </div>
          </Card>
        ))}
      </div>
    </>
  )
}
