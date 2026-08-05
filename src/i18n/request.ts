import { getRequestConfig } from 'next-intl/server'
import { hasLocale } from 'next-intl'

import { routing, INTL_LOCALE, type Locale } from './routing'

export default getRequestConfig(async ({ requestLocale }) => {
  const requested = await requestLocale
  const locale: Locale = hasLocale(routing.locales, requested)
    ? requested
    : routing.defaultLocale

  return {
    locale,
    messages: (await import(`../../messages/${locale}.json`)).default,
    // Tijdzone wordt per salon overschreven; dit is alleen de standaard.
    timeZone: 'America/Curacao',
    formats: {
      dateTime: {
        short: { day: 'numeric', month: 'long', weekday: 'long' },
      },
    },
    now: new Date(),
    getMessageFallback({ key }) {
      // In productie liever een lege string dan "MISSING_MESSAGE" in beeld.
      return process.env.NODE_ENV === 'production' ? '' : `⟨${key}⟩`
    },
    onError() {
      // Ontbrekende vertaling mag de pagina nooit slopen.
    },
    // Voor Intl-opmaak; zie INTL_LOCALE waarom pap op nl leunt.
    ...({ intlLocale: INTL_LOCALE[locale] } as Record<string, unknown>),
  }
})
