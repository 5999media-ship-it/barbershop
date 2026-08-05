/**
 * Formatteerhulpjes. Alles gaat expliciet via de tijdzone van de shop, niet die
 * van de bezoeker. Een klant in Curaçao die een afspraak in Amsterdam boekt moet
 * de Amsterdamse tijd zien — anders staat hij zes uur te vroeg voor de deur.
 */

const WEEKDAYS_NL = ['zondag', 'maandag', 'dinsdag', 'woensdag', 'donderdag', 'vrijdag', 'zaterdag']

export function formatMoney(cents: number, currency = 'EUR', locale = 'nl-NL'): string {
  return new Intl.NumberFormat(locale, { style: 'currency', currency }).format(cents / 100)
}

export function formatTime(iso: string, timeZone: string, locale = 'nl-NL'): string {
  return new Intl.DateTimeFormat(locale, {
    hour: '2-digit',
    minute: '2-digit',
    timeZone,
  }).format(new Date(iso))
}

export function formatDate(iso: string, timeZone: string, locale = 'nl-NL'): string {
  return new Intl.DateTimeFormat(locale, {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    timeZone,
  }).format(new Date(iso))
}

/** Datum en tijd achter elkaar. `at` is het verbindingswoord uit de vertaling. */
export function formatDateTime(
  iso: string,
  timeZone: string,
  locale = 'nl-NL',
  at = 'om',
): string {
  return `${formatDate(iso, timeZone, locale)} ${at} ${formatTime(iso, timeZone, locale)}`
}

/** Duur in minuten; "min" en "u" zijn internationaal genoeg om te laten staan. */
export function formatDuration(minutes: number): string {
  if (minutes < 60) return `${minutes} min`
  const h = Math.floor(minutes / 60)
  const m = minutes % 60
  return m === 0 ? `${h} u` : `${h} u ${m} min`
}

/** Naam van een weekdag (0 = zondag) in de gevraagde taal. */
export function weekdayName(weekday: number, locale = 'nl-NL'): string {
  // 2024-01-07 was een zondag; zo hoeven we geen lijst per taal bij te houden.
  const d = new Date(Date.UTC(2024, 0, 7 + (weekday % 7)))
  return new Intl.DateTimeFormat(locale, { weekday: 'long', timeZone: 'UTC' }).format(d)
}

/** ISO-datum (yyyy-mm-dd) in een specifieke tijdzone. */
export function isoDateInZone(date: Date, timeZone: string): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    timeZone,
  }).format(date)
  return parts
}

export function addDays(date: Date, days: number): Date {
  const d = new Date(date)
  d.setDate(d.getDate() + days)
  return d
}

/**
 * "vandaag" / "morgen" / "zaterdag 9 augustus".
 *
 * De labels voor vandaag en morgen komen uit de vertalingen; de datum zelf
 * laat Intl opmaken. Papiamentu kent Intl niet, dus daar valt de opmaak terug
 * op Nederlands (zie INTL_LOCALE) — de woorden eromheen zijn wél Papiamentu.
 */
export function friendlyDay(
  isoDay: string,
  timeZone: string,
  locale = 'nl-NL',
  labels?: { today: string; tomorrow: string },
): string {
  const today = isoDateInZone(new Date(), timeZone)
  const tomorrow = isoDateInZone(addDays(new Date(), 1), timeZone)
  if (isoDay === today) return labels?.today ?? 'Vandaag'
  if (isoDay === tomorrow) return labels?.tomorrow ?? 'Morgen'
  const d = new Date(`${isoDay}T12:00:00Z`)
  return new Intl.DateTimeFormat(locale, {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    timeZone: 'UTC',
  }).format(d)
}

/**
 * Offset (in ms) van een tijdzone op een bepaald moment.
 * Intl is de enige betrouwbare bron hiervoor in de browser; een hardgecodeerde
 * +1/+2 gaat twee keer per jaar mis.
 */
function zoneOffsetMs(date: Date, timeZone: string): number {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone,
    hour12: false,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
  const parts = Object.fromEntries(
    dtf.formatToParts(date).map((p) => [p.type, p.value]),
  ) as Record<string, string>

  const asUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour) % 24,
    Number(parts.minute),
    Number(parts.second),
  )
  return asUtc - date.getTime()
}

/**
 * Zet een lokale datum + tijd in een tijdzone om naar een absoluut moment.
 * Twee iteraties, want de offset hangt af van het moment dat we juist zoeken —
 * rond de DST-overgang klopt de eerste schatting anders net niet.
 */
export function zonedToUtc(isoDay: string, time: string, timeZone: string): Date {
  const naive = new Date(`${isoDay}T${time}Z`)
  let result = new Date(naive.getTime() - zoneOffsetMs(naive, timeZone))
  result = new Date(naive.getTime() - zoneOffsetMs(result, timeZone))
  return result
}

/** Volgende kalenderdag als yyyy-mm-dd, zonder tijdzonegedoe. */
export function nextIsoDay(isoDay: string): string {
  const d = new Date(`${isoDay}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() + 1)
  return d.toISOString().slice(0, 10)
}

/**
 * [begin, eind) van een lokale kalenderdag als absolute ISO-momenten.
 * Werkt ook op dagen van 23 of 25 uur, omdat we het einde uit de volgende
 * kalenderdag afleiden en niet uit "+24 uur".
 */
export function zonedDayRange(isoDay: string, timeZone: string): [string, string] {
  return [
    zonedToUtc(isoDay, '00:00:00', timeZone).toISOString(),
    zonedToUtc(nextIsoDay(isoDay), '00:00:00', timeZone).toISOString(),
  ]
}

export { WEEKDAYS_NL }
