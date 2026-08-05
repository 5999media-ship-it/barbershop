'use client'

import { useActionState } from 'react'

import { Alert, Button, Card, Field, Input, Textarea } from '@/components/ui'
import ImageUpload from '@/components/ImageUpload'
import {
  saveBarberAvatar,
  saveOwnPrice,
  saveOwnProfile,
  type ActionState,
} from '@/actions/dashboard'
import { formatDuration, formatMoney } from '@/lib/format'
import type { Barber, Service } from '@/lib/supabase/database.types'

export default function OwnProfile({
  barber,
  services,
  prices,
  currency,
}: {
  barber: Barber
  services: Service[]
  prices: Array<{ service_id: string; price_cents: number | null }>
  currency: string
}) {
  const [state, formAction, pending] = useActionState<ActionState, FormData>(saveOwnProfile, {})
  const [priceState, priceAction] = useActionState<ActionState, FormData>(saveOwnPrice, {})

  const priceFor = new Map(prices.map((p) => [p.service_id, p.price_cents]))
  const mine = services.filter((s) => priceFor.has(s.id))

  return (
    <div className="space-y-6">
      {state.error && <Alert>{state.error}</Alert>}
      {state.message && <Alert tone="success">{state.message}</Alert>}

      <Card className="space-y-5">
        <ImageUpload
          kind="barbers"
          ownerId={barber.id}
          currentUrl={barber.avatar_url}
          label="Profielfoto"
          onUploaded={async (url) => {
            await saveBarberAvatar(barber.id, url)
          }}
        />

        <form action={formAction} className="space-y-4">
          <input type="hidden" name="barberId" value={barber.id} />

          <Field label="Introductie" hint="wat maakt jouw stoel de moeite waard?">
            <Textarea name="bio" defaultValue={barber.bio ?? ''} maxLength={1000} />
          </Field>
          <Field label="Instagram" hint="zonder @">
            <Input name="instagram" defaultValue={barber.instagram ?? ''} maxLength={100} />
          </Field>

          <Button type="submit" disabled={pending}>
            {pending ? 'Opslaan…' : 'Opslaan'}
          </Button>
        </form>
      </Card>

      <Card>
        <h2 className="text-lg font-semibold">Mijn tarieven</h2>
        <p className="mb-4 mt-1 text-sm text-ink-400">
          Laat je een tarief leeg, dan geldt de standaardprijs van de salon.
        </p>

        {priceState.error && (
          <div className="mb-3">
            <Alert>{priceState.error}</Alert>
          </div>
        )}

        {mine.length === 0 ? (
          <p className="text-sm text-ink-400">
            Er zijn nog geen behandelingen aan je gekoppeld. Dat doet de eigenaar bij Team.
          </p>
        ) : (
          <ul className="space-y-2">
            {mine.map((s) => {
              const own = priceFor.get(s.id)
              return (
                <li
                  key={s.id}
                  className="flex flex-wrap items-center justify-between gap-3 border-b border-ink-800 pb-3 last:border-0"
                >
                  <div>
                    <p className="font-medium">{s.name}</p>
                    <p className="text-xs text-ink-400">
                      {formatDuration(s.duration_minutes)} · standaard{' '}
                      {formatMoney(s.price_cents, currency)}
                    </p>
                  </div>
                  <form action={priceAction} className="flex items-center gap-2">
                    <input type="hidden" name="barberId" value={barber.id} />
                    <input type="hidden" name="serviceId" value={s.id} />
                    <Input
                      name="priceEuro"
                      type="number"
                      min={0}
                      step="0.05"
                      defaultValue={((own ?? s.price_cents) / 100).toFixed(2)}
                      className="w-28"
                      aria-label={`Tarief voor ${s.name}`}
                    />
                    <Button size="sm" variant="subtle" type="submit">
                      Opslaan
                    </Button>
                  </form>
                </li>
              )
            })}
          </ul>
        )}
      </Card>
    </div>
  )
}
