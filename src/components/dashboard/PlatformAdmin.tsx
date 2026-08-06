'use client'

import { useActionState } from 'react'

import { Alert, Badge, Button, Card, Field, Input } from '@/components/ui'
import {
  createShop,
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
  const [newState, newAction, newPending] = useActionState<ActionState, FormData>(
    createShop,
    {},
  )
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
          Nieuwe salon
        </h2>

        <Card className="space-y-4">
          <p className="text-sm text-ink-400">
            De salon start als concept: onzichtbaar voor bezoekers tot je hem publiceert.
            Behandelingen, team en werktijden vul je daarna in bij de salon zelf.
          </p>

          {newState.error && <Alert>{newState.error}</Alert>}
          {newState.message && <Alert tone="success">{newState.message}</Alert>}

          <form action={newAction} className="space-y-4">
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Naam" required>
                <Input name="name" required maxLength={120} placeholder="Junique Fades" />
              </Field>
              <Field label="Plaats" required>
                <Input name="city" required maxLength={80} placeholder="Willemstad" />
              </Field>
            </div>

            <Field
              label="E-mail van de eigenaar"
              hint="optioneel — moet al een account hebben"
            >
              <Input name="ownerEmail" type="email" placeholder="eigenaar@salon.com" />
            </Field>

            <div className="grid gap-4 sm:grid-cols-2">
              <Field label="Tijdzone">
                <select
                  name="timezone"
                  defaultValue="America/Curacao"
                  className="w-full rounded-[10px] border border-ink-600 bg-ink-850 px-3.5 py-2.5 text-[15px]"
                >
                  <option value="America/Curacao">Curaçao / Bonaire</option>
                  <option value="America/Aruba">Aruba</option>
                  <option value="America/Santo_Domingo">Dominicaanse Republiek</option>
                  <option value="Europe/Amsterdam">Nederland</option>
                </select>
              </Field>
              <Field label="Valuta">
                <select
                  name="currency"
                  defaultValue="XCG"
                  className="w-full rounded-[10px] border border-ink-600 bg-ink-850 px-3.5 py-2.5 text-[15px]"
                >
                  <option value="XCG">XCG — Caribische gulden (Cg.)</option>
                  <option value="AWG">AWG — Arubaanse florin</option>
                  <option value="USD">USD — Amerikaanse dollar</option>
                  <option value="EUR">EUR — euro</option>
                </select>
              </Field>
            </div>

            <Button type="submit" disabled={newPending}>
              {newPending ? 'Aanmaken…' : 'Salon aanmaken'}
            </Button>
          </form>
        </Card>
      </section>

      <section>
        <h2 className="mb-3 text-sm font-medium uppercase tracking-wider text-ink-400">
          Salons ({shops.length})
        </h2>

        {shops.length === 0 ? (
          <Card className="text-center text-ink-400">
            Er zijn nog geen salons. Maak er hierboven een aan.
          </Card>
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
