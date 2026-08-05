import { getLocale } from 'next-intl/server'

import LocaleSwitcher from '@/components/LocaleSwitcher'
import ThemeToggle from '@/components/ThemeToggle'
import { getThemeChoice } from '@/lib/theme'
import type { Locale } from '@/i18n/routing'

/**
 * Onopvallende balk onderaan elke pagina met de taal- en themakeuze.
 *
 * Bewust onderaan en niet in een header: bezoekers komen hier om een afspraak
 * te maken, niet om instellingen te wijzigen. Wie de taal zoekt, scrollt.
 */
export default async function SiteChrome() {
  const locale = (await getLocale()) as Locale
  const theme = await getThemeChoice()

  return (
    <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-center gap-3 px-5 py-8">
      <LocaleSwitcher current={locale} />
      <ThemeToggle initial={theme} />
    </div>
  )
}
