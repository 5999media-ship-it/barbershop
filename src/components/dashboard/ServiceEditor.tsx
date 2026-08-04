'use client'

import { useActionState, useState } from 'react'

import { Alert, Badge, Button, Card, Field, Input, Textarea } from '@/components/ui'
import { saveService, type ActionState } from '@/app/dashboard/actions'
import { formatDuration, formatMoney } from '@/lib/format'
import type { Service } from '@/lib/supabase/database.types'

export default function ServiceEditor({
  shopId,
  services,
}: {
  shopId: string
  services: Service[]
}) {
  const [editing, setEditing] = useState<Service | 'new' | null>(null)
  const [state, formAction, pending] = useActionState<ActionState, FormData>(saveService, {})

  const current = editing === 'new' ? null : editing

  return (
    <>
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

      <div className="mb-5">
        <Button onClick={() => setEditing('new')}>Nieuwe behandeling</Button>
      </div>

      {editing !== null && (
        <Card className="mb-6">
          <h2 className="mb-4 text-lg font-semibold">
            {current ? `“${current.name}” bewerken` : 'Nieuwe behandeling'}
          </h2>

          <form action={formAction} className="space-y-4">
            <input type="hidden" name="shopId" value={shopId} />
            <input type="hidden" name="id" value={current?.id ?? ''} />

            <Field label="Naam" required>
              <Input name="name" defaultValue={current?.name ?? ''} required maxLength={100} />
            </Field>

            <Field label="Omschrijving" hint="verschijnt op de publieke pagina">
              <Textarea
                name="description"
                defaultValue={current?.description ?? ''}
                maxLength={1000}
              />
            </Field>

            <div className="grid gap-4 sm:grid-cols-3">
              <Field label="Duur (min)" required>
                <Input
                  name="durationMinutes"
                  type="number"
                  min={5}
                  max={480}
                  step={5}
                  defaultValue={current?.duration_minutes ?? 30}
                  required
                />
              </Field>
              <Field label="Opruimtijd (min)" hint="buffer erna">
                <Input
                  name="bufferMinutes"
                  type="number"
                  min={0}
                  max={120}
                  step={5}
                  defaultValue={current?.buffer_after_minutes ?? 0}
                />
              </Field>
              <Field label="Prijs (€)" required>
                <Input
                  name="priceEuro"
                  type="number"
                  min={0}
                  step="0.05"
                  defaultValue={((current?.price_cents ?? 0) / 100).toFixed(2)}
                  required
                />
              </Field>
            </div>

            <label className="flex items-center gap-2.5 text-sm">
              <input
                type="checkbox"
                name="isActive"
                defaultChecked={current?.is_active ?? true}
                className="h-4 w-4 accent-[#c8a45c]"
              />
              Zichtbaar en boekbaar
            </label>

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

      <ul className="space-y-2">
        {services.map((s) => (
          <li key={s.id}>
            <Card className="flex flex-wrap items-center justify-between gap-4">
              <div>
                <p className="flex items-center gap-2 font-medium">
                  {s.name}
                  {!s.is_active && <Badge>Verborgen</Badge>}
                </p>
                <p className="mt-0.5 text-sm text-ink-400">
                  {formatDuration(s.duration_minutes)}
                  {s.buffer_after_minutes > 0 && ` + ${s.buffer_after_minutes} min opruimen`}
                </p>
              </div>
              <div className="flex items-center gap-4">
                <span className="font-semibold text-brass-300">
                  {formatMoney(s.price_cents)}
                </span>
                <Button size="sm" variant="ghost" onClick={() => setEditing(s)}>
                  Bewerken
                </Button>
              </div>
            </Card>
          </li>
        ))}
      </ul>
    </>
  )
}
