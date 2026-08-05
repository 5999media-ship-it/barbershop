'use client'

import { useActionState } from 'react'

import { Alert, Badge, Button, Card, Field, Input } from '@/components/ui'
import {
  setShopPublished,
  togglePlatformAdmin,
  type ActionState,
} from '@/actions/dashboard'
import type { AdminShopRow } from '@/app/[locale]/dashboard/platform/page'

export default function PlatformAdmin({
  shops,
  currentEmail,
}: {
  shops: AdminShopRow[]
  currentEmail: string
}) {
  const [pubState, pubAction] = useActionState<ActionState, FormData>(setShopPublished, {})
  const [adminState, adminAction, adminPending] = useActionState<ActionState, FormData>(
    togglePlatformAdmin,
    {},
  )

  return (
    <div className="space-y-8">
      {pubState.error && <Alert>{pubState.error}</Alert>}
      {pubState.message && <Alert tone="success">{pubState.message}</Alert>}

      <section>
        <h2 className="mb-3 text-sm font-medium uppercase tracking-wider text-ink-400">
          Salons ({shops.length})
        </h2>

        {shops.length === 0 ? (
          <Card className="text-center text-ink-400">Er zijn nog geen salons aangemaakt.</Card>
        ) : (
          <ul className="space-y-2">
            {shops.map((shop) => (
              <li key={shop.id}>
                <Card className="flex flex-wrap items-center justify-between gap-4">
                  <div>
                    <p className="flex items-center gap-2 font-medium">
                      {shop.name}
                      {shop.is_published ? (
                        <Badge tone="success">Live</Badge>
                      ) : (
                        <Badge>Concept</Badge>
                      )}
                      {!shop.is_active && <Badge tone="danger">Inactief</Badge>}
                    </p>
                    <p className="mt-0.5 text-sm text-ink-400">
                      {shop.city ?? '—'} · /{shop.slug}
                    </p>
                    <p className="mt-1 text-xs text-ink-400">
                      {shop.barber_count} barbers · {shop.service_count} behandelingen ·{' '}
                      {shop.booking_count} afspraken totaal · {shop.upcoming_count} aankomend
                    </p>
                  </div>

                  <form action={pubAction}>
                    <input type="hidden" name="shopId" value={shop.id} />
                    <input type="hidden" name="value" value={String(!shop.is_published)} />
                    <Button size="sm" variant={shop.is_published ? 'ghost' : 'primary'}>
                      {shop.is_published ? 'Offline halen' : 'Publiceren'}
                    </Button>
                  </form>
                </Card>
              </li>
            ))}
          </ul>
        )}
      </section>

      <section>
        <h2 className="mb-3 text-sm font-medium uppercase tracking-wider text-ink-400">
          Platformbeheerders
        </h2>

        <Card className="space-y-4">
          <p className="text-sm text-ink-400">
            Een platformbeheerder ziet en beheert alle salons. Geef dit alleen aan mensen die
            je vertrouwt met alle klantgegevens op het platform.
          </p>

          {adminState.error && <Alert>{adminState.error}</Alert>}
          {adminState.message && <Alert tone="success">{adminState.message}</Alert>}

          <form action={adminAction} className="flex flex-wrap items-end gap-3">
            <input type="hidden" name="value" value="true" />
            <div className="min-w-56 flex-1">
              <Field label="E-mailadres" hint="moet al een account hebben">
                <Input name="email" type="email" required placeholder="naam@voorbeeld.nl" />
              </Field>
            </div>
            <Button type="submit" disabled={adminPending}>
              Beheerder maken
            </Button>
          </form>

          <p className="text-xs text-ink-400">
            Je bent ingelogd als {currentEmail}. Jezelf degraderen kan niet — anders zou het
            platform zonder beheerder achterblijven.
          </p>
        </Card>
      </section>
    </div>
  )
}
