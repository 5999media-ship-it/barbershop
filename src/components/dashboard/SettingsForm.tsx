'use client'

import { useActionState } from 'react'

import { Alert, Button, Card, Field, Input, Textarea } from '@/components/ui'
import { saveShopSettings, type ActionState } from '@/app/dashboard/actions'
import type { Shop } from '@/lib/supabase/database.types'

export default function SettingsForm({ shop, canManage }: { shop: Shop; canManage: boolean }) {
  const [state, formAction, pending] = useActionState<ActionState, FormData>(
    saveShopSettings,
    {},
  )

  if (!canManage) {
    return <Alert tone="info">Alleen de eigenaar of manager kan deze instellingen wijzigen.</Alert>
  }

  return (
    <form action={formAction} className="space-y-6">
      <input type="hidden" name="shopId" value={shop.id} />

      {state.error && <Alert>{state.error}</Alert>}
      {state.message && <Alert tone="success">{state.message}</Alert>}

      <Card className="space-y-4">
        <h2 className="text-lg font-semibold">Profiel</h2>

        <Field label="Naam" required>
          <Input name="name" defaultValue={shop.name} required maxLength={120} />
        </Field>
        <Field label="Slogan" hint="max. 160 tekens, komt in de zoekresultaten">
          <Input name="tagline" defaultValue={shop.tagline ?? ''} maxLength={160} />
        </Field>
        <Field label="Omschrijving" hint="waar ben je goed in?">
          <Textarea name="description" defaultValue={shop.description ?? ''} maxLength={4000} />
        </Field>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Telefoon">
            <Input name="phone" defaultValue={shop.phone ?? ''} type="tel" />
          </Field>
          <Field label="E-mail">
            <Input name="email" defaultValue={shop.email ?? ''} type="email" />
          </Field>
        </div>
      </Card>

      <Card className="space-y-4">
        <h2 className="text-lg font-semibold">Adres</h2>
        <p className="-mt-2 text-sm text-ink-400">
          Zorg dat dit letterlijk overeenkomt met je Google-bedrijfsprofiel. Verschillen in
          NAP-gegevens (naam, adres, telefoon) kosten je posities in de lokale resultaten.
        </p>

        <div className="grid gap-4 sm:grid-cols-[2fr_1fr]">
          <Field label="Straat">
            <Input name="street" defaultValue={shop.street ?? ''} />
          </Field>
          <Field label="Huisnummer">
            <Input name="houseNumber" defaultValue={shop.house_number ?? ''} />
          </Field>
        </div>
        <div className="grid gap-4 sm:grid-cols-[1fr_2fr]">
          <Field label="Postcode">
            <Input name="postalCode" defaultValue={shop.postal_code ?? ''} />
          </Field>
          <Field label="Plaats">
            <Input name="city" defaultValue={shop.city ?? ''} />
          </Field>
        </div>
      </Card>

      <Card className="space-y-4">
        <h2 className="text-lg font-semibold">Boekingsbeleid</h2>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Slotinterval (min)" hint="hoe fijn het raster is">
            <select
              name="slotInterval"
              defaultValue={shop.slot_interval_minutes}
              className="w-full rounded-[10px] border border-ink-600 bg-ink-850 px-3.5 py-2.5 text-[15px]"
            >
              {[5, 10, 15, 20, 30, 60].map((v) => (
                <option key={v} value={v}>
                  {v} minuten
                </option>
              ))}
            </select>
          </Field>
          <Field label="Minimale voorbereidingstijd (min)" hint="niet binnen X minuten boeken">
            <Input
              name="minLeadMinutes"
              type="number"
              min={0}
              max={43200}
              defaultValue={shop.min_lead_minutes}
            />
          </Field>
          <Field label="Vooruit boeken (dagen)">
            <Input
              name="maxAdvanceDays"
              type="number"
              min={1}
              max={365}
              defaultValue={shop.max_advance_days}
            />
          </Field>
          <Field label="Annuleren tot (uren vooraf)">
            <Input
              name="cancelCutoffHours"
              type="number"
              min={0}
              max={168}
              defaultValue={shop.cancel_cutoff_hours}
            />
          </Field>
        </div>

        <Field label="Meldingen naar" hint="krijgt een mail bij elke nieuwe boeking">
          <Input
            name="staffNotifyEmail"
            type="email"
            defaultValue={shop.staff_notify_email ?? ''}
          />
        </Field>
      </Card>

      <Card>
        <label className="flex items-start gap-3">
          <input
            type="checkbox"
            name="isPublished"
            defaultChecked={shop.is_published}
            className="mt-1 h-4 w-4 accent-[#c8a45c]"
          />
          <span>
            <span className="block font-medium">Salon publiceren</span>
            <span className="mt-0.5 block text-sm text-ink-400">
              Zet dit aan als je klaar bent. Zolang dit uit staat is de pagina alleen voor
              jou en je team zichtbaar en kan er niemand boeken.
            </span>
          </span>
        </label>
      </Card>

      <Button type="submit" size="lg" disabled={pending}>
        {pending ? 'Opslaan…' : 'Instellingen opslaan'}
      </Button>
    </form>
  )
}
