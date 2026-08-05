import { defineRouting } from 'next-intl/routing'

/**
 * Talen en URL-structuur.
 *
 * Nederlands staat op de hoofd-URL zonder voorvoegsel (`/kapper/...`), de rest
 * krijgt een prefix (`/en/kapper/...`). Dat is `localePrefix: 'as-needed'`.
 *
 * Waarom taal in de URL en niet in een cookie? Omdat Google elke taal dan als
 * een eigen pagina kan indexeren. Met een cookie ziet de crawler maar één
 * versie en gooi je het grootste voordeel van meertaligheid weg. Bovendien kun
 * je nu een Spaanstalige link delen die ook echt Spaans opent.
 */
export const routing = defineRouting({
  locales: ['nl', 'en', 'es', 'pap'],
  defaultLocale: 'nl',
  localePrefix: 'as-needed',
  localeDetection: true,
})

export type Locale = (typeof routing.locales)[number]

/** Voor het `lang`-attribuut en Intl. Papiamentu heeft geen eigen Intl-data. */
export const HTML_LANG: Record<Locale, string> = {
  nl: 'nl-NL',
  en: 'en',
  es: 'es',
  pap: 'pap',
}

/** Fallback voor datum- en getalopmaak: Papiamentu leunt op Nederlands. */
export const INTL_LOCALE: Record<Locale, string> = {
  nl: 'nl-NL',
  en: 'en-GB',
  es: 'es-ES',
  pap: 'nl-NL',
}

export const LOCALE_LABEL: Record<Locale, string> = {
  nl: 'Nederlands',
  en: 'English',
  es: 'Español',
  pap: 'Papiamentu',
}
