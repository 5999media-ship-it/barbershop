'use client'

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import Link from 'next/link'

import { Alert, Badge, Button, Field, Input, Spinner, Textarea, cn } from '@/components/ui'
import { createClient } from '@/lib/supabase/client'
import type {
  AvailableDay,
  AvailableSlot,
  Barber,
  CreatedBooking,
  Service,
  Shop,
} from '@/lib/supabase/database.types'
import {
  addDays,
  formatDuration,
  formatMoney,
  formatTime,
  friendlyDay,
  isoDateInZone,
} from '@/lib/format'

const STEPS = ['Behandeling', 'Barber', 'Tijd', 'Gegevens'] as const

interface Props {
  shop: Shop
  services: Service[]
  barbers: Barber[]
  serviceBarbers: Record<string, string[]>
  preselectedServiceSlug?: string
}

export default function BookingWizard({
  shop,
  services,
  barbers,
  serviceBarbers,
  preselectedServiceSlug,
}: Props) {
  const supabase = useMemo(() => createClient(), [])

  const [step, setStep] = useState(0)
  const [serviceId, setServiceId] = useState<string | null>(
    services.find((s) => s.slug === preselectedServiceSlug)?.id ?? null,
  )
  const [barberId, setBarberId] = useState<string | null>(null) // null = geen voorkeur
  const [day, setDay] = useState<string | null>(null)
  const [slot, setSlot] = useState<AvailableSlot | null>(null)

  const [days, setDays] = useState<AvailableDay[] | null>(null)
  const [slots, setSlots] = useState<AvailableSlot[] | null>(null)
  const [loadingDays, setLoadingDays] = useState(false)
  const [loadingSlots, setLoadingSlots] = useState(false)

  const [form, setForm] = useState({ name: '', email: '', phone: '', notes: '', website: '' })
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [result, setResult] = useState<CreatedBooking | null>(null)

  const headingRef = useRef<HTMLHeadingElement>(null)

  const service = services.find((s) => s.id === serviceId) ?? null
  const eligibleBarbers = useMemo(
    () =>
      serviceId
        ? barbers.filter((b) => (serviceBarbers[serviceId] ?? []).includes(b.id))
        : barbers,
    [barbers, serviceBarbers, serviceId],
  )

  // Focus naar de stapkop verplaatsen: schermlezers moeten de wisseling horen.
  useEffect(() => {
    headingRef.current?.focus()
  }, [step])

  // ---------------------------------------------------------------------
  // Beschikbare dagen ophalen
  // ---------------------------------------------------------------------
  useEffect(() => {
    if (!serviceId || step < 2) return
    let cancelled = false

    const load = async () => {
      setLoadingDays(true)
      setError(null)
      const from = isoDateInZone(new Date(), shop.timezone)
      const to = isoDateInZone(
        addDays(new Date(), Math.min(shop.max_advance_days, 62)),
        shop.timezone,
      )
      const { data, error: rpcError } = await supabase.rpc('available_days', {
        p_shop_id: shop.id,
        p_service_id: serviceId,
        p_date_from: from,
        p_date_to: to,
        p_barber_id: barberId,
      })
      if (cancelled) return
      setLoadingDays(false)
      if (rpcError) {
        setError('De agenda kon niet geladen worden. Ververs de pagina.')
        return
      }
      const list = (data ?? []) as AvailableDay[]
      setDays(list)
      setDay((current) => current ?? list[0]?.day ?? null)
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, shop.id, shop.timezone, shop.max_advance_days, serviceId, barberId, step])

  // ---------------------------------------------------------------------
  // Slots ophalen voor de gekozen dag
  // ---------------------------------------------------------------------
  useEffect(() => {
    if (!serviceId || !day) return
    let cancelled = false

    const load = async () => {
      setLoadingSlots(true)
      const { data, error: rpcError } = await supabase.rpc('available_slots', {
        p_shop_id: shop.id,
        p_service_id: serviceId,
        p_date_from: day,
        p_date_to: day,
        p_barber_id: barberId,
      })
      if (cancelled) return
      setLoadingSlots(false)
      if (rpcError) {
        setError('De tijden konden niet geladen worden.')
        return
      }
      setSlots((data ?? []) as AvailableSlot[])
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, shop.id, serviceId, day, barberId])

  // Bij "geen voorkeur" één knop per tijdstip tonen, niet één per barber.
  const uniqueSlots = useMemo(() => {
    if (!slots) return []
    const seen = new Map<string, AvailableSlot>()
    for (const s of slots) if (!seen.has(s.slot_start)) seen.set(s.slot_start, s)
    return [...seen.values()]
  }, [slots])

  const refreshAvailability = useCallback(() => {
    setSlot(null)
    setSlots(null)
    setDays(null)
    setDay(null)
  }, [])

  // ---------------------------------------------------------------------
  // Versturen
  // ---------------------------------------------------------------------
  async function submit() {
    if (!service || !slot) return
    setSubmitting(true)
    setError(null)

    try {
      const response = await fetch('/api/book', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          shopId: shop.id,
          serviceId: service.id,
          barberId: barberId ?? slot.barber_id,
          startsAt: slot.slot_start,
          name: form.name,
          email: form.email,
          phone: form.phone,
          notes: form.notes,
          website: form.website, // honeypot
        }),
      })

      const payload = (await response.json()) as
        | { ok: true; booking: CreatedBooking }
        | { ok: false; error: string; recoverable?: boolean }

      if (!response.ok || !payload.ok) {
        const message = 'error' in payload ? payload.error : 'Er ging iets mis.'
        setError(message)
        // Slot weggekaapt? Agenda opnieuw ophalen zodat de klant meteen
        // een geldige keuze ziet in plaats van dezelfde dode knop.
        if ('recoverable' in payload && payload.recoverable) {
          refreshAvailability()
          setStep(2)
        }
        return
      }

      setResult(payload.booking)
    } catch {
      setError('Geen verbinding. Controleer je internet en probeer opnieuw.')
    } finally {
      setSubmitting(false)
    }
  }

  // ---------------------------------------------------------------------
  // Bevestiging
  // ---------------------------------------------------------------------
  if (result) {
    return (
      <div className="mx-auto max-w-md text-center">
        <div className="mx-auto mb-5 flex h-14 w-14 items-center justify-center rounded-full bg-success-500/15 text-2xl text-success-500">
          ✓
        </div>
        <h2 className="text-2xl font-semibold">Je afspraak staat</h2>
        <p className="mt-2 text-ink-300">
          We hebben een bevestiging gestuurd naar {form.email}.
        </p>

        <dl className="card mt-6 space-y-3 p-5 text-left text-sm">
          <Row label="Wanneer" value={`${friendlyDay(day ?? '', shop.timezone)} om ${formatTime(result.starts_at, shop.timezone)}`} />
          <Row label="Behandeling" value={result.service_name} />
          <Row label="Barber" value={result.barber_name} />
          <Row label="Prijs" value={formatMoney(result.price_cents, result.currency)} />
        </dl>

        <Link href={`/afspraak/${result.manage_token}`} className="mt-6 inline-block w-full">
          <Button className="w-full" size="lg">
            Afspraak bekijken of wijzigen
          </Button>
        </Link>
        <p className="mt-3 text-xs text-ink-400">
          Bewaar deze link. Hiermee kun je zonder account je afspraak verzetten of annuleren.
        </p>
      </div>
    )
  }

  // ---------------------------------------------------------------------
  // Wizard
  // ---------------------------------------------------------------------
  const canContinue = [
    Boolean(serviceId),
    true, // barber mag "geen voorkeur" zijn
    Boolean(slot),
    form.name.trim().length >= 2 && form.email.includes('@') && form.phone.trim().length >= 6,
  ][step]

  return (
    <div className="mx-auto max-w-xl">
      {/* Voortgang */}
      <ol className="mb-8 flex items-center gap-1.5" aria-label="Voortgang">
        {STEPS.map((label, i) => (
          <li key={label} className="flex flex-1 flex-col gap-1.5">
            <span
              className={cn(
                'h-1 rounded-full',
                i < step ? 'bg-brass-500' : i === step ? 'bg-brass-400' : 'bg-ink-700',
              )}
            />
            <span className={cn('text-[11px]', i <= step ? 'text-brass-300' : 'text-ink-400')}>
              {label}
            </span>
          </li>
        ))}
      </ol>

      {error && (
        <div className="mb-5">
          <Alert>{error}</Alert>
        </div>
      )}

      {/* Stap 1 — behandeling */}
      {step === 0 && (
        <section>
          <h2 ref={headingRef} tabIndex={-1} className="mb-4 text-xl font-semibold">
            Wat komt er gebeuren?
          </h2>
          <div className="space-y-2">
            {services.map((s) => (
              <button
                key={s.id}
                type="button"
                onClick={() => {
                  setServiceId(s.id)
                  setBarberId(null)
                  refreshAvailability()
                  setStep(1)
                }}
                aria-pressed={serviceId === s.id}
                className={cn(
                  'card flex w-full items-center justify-between gap-4 p-4 text-left transition',
                  serviceId === s.id ? 'border-brass-500' : 'hover:border-ink-600',
                )}
              >
                <span>
                  <span className="block font-medium">{s.name}</span>
                  {s.description && (
                    <span className="mt-0.5 block text-sm text-ink-400">{s.description}</span>
                  )}
                  <span className="mt-1 block text-xs text-ink-400">
                    {formatDuration(s.duration_minutes)}
                  </span>
                </span>
                <span className="shrink-0 font-semibold text-brass-300">
                  {formatMoney(s.price_cents, shop.currency)}
                </span>
              </button>
            ))}
          </div>
        </section>
      )}

      {/* Stap 2 — barber */}
      {step === 1 && (
        <section>
          <h2 ref={headingRef} tabIndex={-1} className="mb-1 text-xl font-semibold">
            Bij wie?
          </h2>
          <p className="mb-4 text-sm text-ink-400">
            Geen voorkeur geeft je de meeste keuze in tijden.
          </p>
          <div className="space-y-2">
            <SelectableRow
              selected={barberId === null}
              onClick={() => {
                setBarberId(null)
                refreshAvailability()
                setStep(2)
              }}
              title="Geen voorkeur"
              subtitle="De eerstvolgende beschikbare barber"
            />
            {eligibleBarbers.map((b) => (
              <SelectableRow
                key={b.id}
                selected={barberId === b.id}
                onClick={() => {
                  setBarberId(b.id)
                  refreshAvailability()
                  setStep(2)
                }}
                title={b.display_name}
                subtitle={b.bio ?? undefined}
              />
            ))}
          </div>
        </section>
      )}

      {/* Stap 3 — datum en tijd */}
      {step === 2 && (
        <section>
          <h2 ref={headingRef} tabIndex={-1} className="mb-4 text-xl font-semibold">
            Wanneer schikt het?
          </h2>

          {loadingDays && !days && <Spinner label="Agenda laden…" />}

          {days && days.length === 0 && (
            <Alert tone="info">
              Er zijn de komende weken geen vrije plekken voor deze combinatie.
              Probeer een andere barber of bel de salon.
            </Alert>
          )}

          {days && days.length > 0 && (
            <>
              <div
                className="-mx-1 mb-5 flex snap-x gap-2 overflow-x-auto px-1 pb-2"
                role="tablist"
                aria-label="Beschikbare dagen"
              >
                {days.map((d) => (
                  <button
                    key={d.day}
                    type="button"
                    role="tab"
                    aria-selected={day === d.day}
                    onClick={() => {
                      setDay(d.day)
                      setSlot(null)
                    }}
                    className={cn(
                      'shrink-0 snap-start rounded-[12px] border px-4 py-3 text-left transition',
                      day === d.day
                        ? 'border-brass-500 bg-brass-500/10'
                        : 'border-ink-700 hover:border-ink-600',
                    )}
                  >
                    <span className="block text-sm font-medium capitalize">
                      {friendlyDay(d.day, shop.timezone)}
                    </span>
                    <span className="mt-0.5 block text-xs text-ink-400">
                      {d.slot_count} {d.slot_count === 1 ? 'plek' : 'plekken'}
                    </span>
                  </button>
                ))}
              </div>

              {loadingSlots && <Spinner label="Tijden laden…" />}

              {!loadingSlots && uniqueSlots.length > 0 && (
                <div className="grid grid-cols-3 gap-2 sm:grid-cols-4">
                  {uniqueSlots.map((s) => {
                    const active = slot?.slot_start === s.slot_start
                    return (
                      <button
                        key={s.slot_start}
                        type="button"
                        onClick={() => setSlot(s)}
                        aria-pressed={active}
                        className={cn(
                          'rounded-[10px] border py-2.5 text-sm font-medium transition',
                          active
                            ? 'border-brass-500 bg-brass-500 text-ink-950'
                            : 'border-ink-700 hover:border-brass-500 hover:text-brass-300',
                        )}
                      >
                        {formatTime(s.slot_start, shop.timezone)}
                      </button>
                    )
                  })}
                </div>
              )}

              {!loadingSlots && uniqueSlots.length === 0 && day && (
                <Alert tone="info">Op deze dag is niets meer vrij. Kies een andere dag.</Alert>
              )}
            </>
          )}
        </section>
      )}

      {/* Stap 4 — gegevens */}
      {step === 3 && service && slot && (
        <section>
          <h2 ref={headingRef} tabIndex={-1} className="mb-4 text-xl font-semibold">
            Bijna klaar
          </h2>

          <div className="card mb-6 space-y-2 p-4 text-sm">
            <div className="flex justify-between">
              <span className="text-ink-400">Wanneer</span>
              <span className="capitalize">
                {friendlyDay(day ?? '', shop.timezone)} · {formatTime(slot.slot_start, shop.timezone)}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-ink-400">Behandeling</span>
              <span>{service.name}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-ink-400">Barber</span>
              <span>
                {barbers.find((b) => b.id === (barberId ?? slot.barber_id))?.display_name ??
                  'Wordt toegewezen'}
              </span>
            </div>
            <div className="flex justify-between border-t border-ink-800 pt-2 font-semibold">
              <span>Te betalen in de zaak</span>
              <span className="text-brass-300">
                {formatMoney(slot.price_cents, shop.currency)}
              </span>
            </div>
          </div>

          <form
            className="space-y-4"
            onSubmit={(e) => {
              e.preventDefault()
              void submit()
            }}
          >
            <Field label="Naam" required>
              <Input
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
                autoComplete="name"
                required
                minLength={2}
                maxLength={100}
              />
            </Field>
            <Field label="E-mail" hint="voor je bevestiging" required>
              <Input
                type="email"
                value={form.email}
                onChange={(e) => setForm({ ...form, email: e.target.value })}
                autoComplete="email"
                inputMode="email"
                required
              />
            </Field>
            <Field label="Telefoon" hint="voor als er iets verandert" required>
              <Input
                type="tel"
                value={form.phone}
                onChange={(e) => setForm({ ...form, phone: e.target.value })}
                autoComplete="tel"
                inputMode="tel"
                required
              />
            </Field>
            <Field label="Opmerking" hint="optioneel">
              <Textarea
                value={form.notes}
                onChange={(e) => setForm({ ...form, notes: e.target.value })}
                maxLength={1000}
                placeholder="Bijvoorbeeld: nummer 2 aan de zijkanten, bovenop laten."
              />
            </Field>

            {/* Honeypot — onzichtbaar voor mensen, onweerstaanbaar voor bots */}
            <div aria-hidden className="absolute left-[-9999px]">
              <label>
                Website
                <input
                  tabIndex={-1}
                  autoComplete="off"
                  value={form.website}
                  onChange={(e) => setForm({ ...form, website: e.target.value })}
                />
              </label>
            </div>

            <Button type="submit" size="lg" className="w-full" disabled={submitting || !canContinue}>
              {submitting ? 'Bezig met vastleggen…' : 'Afspraak bevestigen'}
            </Button>
            <p className="text-center text-xs text-ink-400">
              Gratis annuleren tot {shop.cancel_cutoff_hours} uur van tevoren. Je betaalt in de zaak.
            </p>
          </form>
        </section>
      )}

      {/* Navigatie */}
      <div className="mt-8 flex items-center justify-between">
        <Button
          variant="ghost"
          onClick={() => setStep((s) => Math.max(0, s - 1))}
          disabled={step === 0 || submitting}
        >
          Terug
        </Button>
        {step < 3 && (
          <Button onClick={() => setStep((s) => Math.min(3, s + 1))} disabled={!canContinue}>
            Verder
          </Button>
        )}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
function SelectableRow({
  selected,
  onClick,
  title,
  subtitle,
}: {
  selected: boolean
  onClick: () => void
  title: string
  subtitle?: string
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={selected}
      className={cn(
        'card flex w-full items-center justify-between gap-4 p-4 text-left transition',
        selected ? 'border-brass-500' : 'hover:border-ink-600',
      )}
    >
      <span>
        <span className="block font-medium">{title}</span>
        {subtitle && <span className="mt-0.5 block text-sm text-ink-400">{subtitle}</span>}
      </span>
      {selected && <Badge tone="brass">Gekozen</Badge>}
    </button>
  )
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between gap-4">
      <dt className="text-ink-400">{label}</dt>
      <dd className="text-right font-medium">{value}</dd>
    </div>
  )
}
