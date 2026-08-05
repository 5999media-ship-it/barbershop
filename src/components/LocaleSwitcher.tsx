'use client'

import { useTransition } from 'react'
import { useTranslations } from 'next-intl'
import { useParams } from 'next/navigation'

import { usePathname, useRouter } from '@/i18n/navigation'
import { routing, LOCALE_LABEL, type Locale } from '@/i18n/routing'

/**
 * Taalkiezer. Houdt de huidige pagina vast: sta je op de boekingspagina van een
 * salon, dan kom je op diezelfde pagina in de nieuwe taal uit — niet op de
 * homepage. Dat klinkt vanzelfsprekend maar gaat op veel sites mis.
 */
export default function LocaleSwitcher({ current }: { current: Locale }) {
  const t = useTranslations('language')
  const router = useRouter()
  const pathname = usePathname()
  const params = useParams()
  const [pending, startTransition] = useTransition()

  return (
    <label className="inline-flex items-center gap-2 text-xs text-ink-400">
      <span className="sr-only">{t('label')}</span>
      <select
        value={current}
        disabled={pending}
        onChange={(event) => {
          const next = event.target.value as Locale
          startTransition(() => {
            router.replace(
              // @ts-expect-error — pathname en params horen bij elkaar,
              // maar dat kan het typesysteem hier niet bewijzen.
              { pathname, params },
              { locale: next },
            )
          })
        }}
        className="rounded-full border border-ink-700 bg-transparent px-2.5 py-1 text-xs text-ink-300"
      >
        {routing.locales.map((locale) => (
          <option key={locale} value={locale}>
            {LOCALE_LABEL[locale]}
          </option>
        ))}
      </select>
    </label>
  )
}
