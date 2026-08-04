import { z } from 'zod'

/**
 * Validatieschema's. Deze draaien op de server (Route Handler) én in de browser.
 *
 * Let op: dit is geen beveiliging, het is gebruiksvriendelijkheid. De echte
 * grens ligt in Postgres — create_booking() valideert alles nog een keer en
 * negeert wat de client over prijs of duur beweert.
 */

export const bookingRequestSchema = z.object({
  shopId: z.string().uuid(),
  serviceId: z.string().uuid(),
  barberId: z.string().uuid().nullable().optional(),
  startsAt: z.string().datetime({ offset: true }),
  name: z
    .string()
    .trim()
    .min(2, 'Vul je naam in')
    .max(100, 'Naam is te lang'),
  email: z
    .string()
    .trim()
    .toLowerCase()
    .email('Vul een geldig e-mailadres in')
    .max(160),
  phone: z
    .string()
    .trim()
    .min(6, 'Vul een geldig telefoonnummer in')
    .max(20)
    .regex(/^[0-9+()\-.\s]+$/, 'Alleen cijfers en + ( ) -'),
  notes: z.string().trim().max(1000).optional().or(z.literal('')),
  // Honeypot: onzichtbaar veld dat alleen bots invullen.
  website: z.string().max(0).optional(),
})

export type BookingRequest = z.infer<typeof bookingRequestSchema>

export const cancelRequestSchema = z.object({
  token: z.string().uuid(),
  reason: z.string().trim().max(500).optional().or(z.literal('')),
})

export const rescheduleRequestSchema = z.object({
  token: z.string().uuid(),
  startsAt: z.string().datetime({ offset: true }),
  barberId: z.string().uuid().nullable().optional(),
})

export const credentialsSchema = z.object({
  email: z.string().trim().toLowerCase().email('Vul een geldig e-mailadres in'),
  password: z.string().min(10, 'Minimaal 10 tekens').max(200),
})

/** Vertaalt Postgres-foutcodes naar begrijpelijke Nederlandse tekst. */
export function humanizeDbError(message: string, hint?: string | null): string {
  const map: Record<string, string> = {
    shop_not_available: 'Deze salon neemt op dit moment geen online boekingen aan.',
    service_not_found: 'Deze behandeling bestaat niet meer.',
    invalid_name: 'Vul een geldige naam in.',
    invalid_email: 'Vul een geldig e-mailadres in.',
    invalid_phone: 'Vul een geldig telefoonnummer in.',
    rate_limited: 'Te veel pogingen. Probeer het over een uur opnieuw of bel de salon.',
    too_many_open_bookings: 'Je hebt al meerdere openstaande afspraken bij deze salon.',
    slot_unavailable: 'Dit tijdstip is niet meer beschikbaar. Kies een ander moment.',
    slot_taken: 'Iemand was je net voor. Kies een ander tijdstip.',
    booking_not_found: 'Deze afspraak bestaat niet of de link is verlopen.',
    booking_not_cancellable: 'Deze afspraak is al afgerond of geannuleerd.',
    cancel_window_closed: 'Online annuleren kan niet meer. Bel de salon even.',
    reschedule_window_closed: 'Online verzetten kan niet meer. Bel de salon even.',
  }
  return hint || map[message] || 'Er ging iets mis. Probeer het zo nog eens.'
}
