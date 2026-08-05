import type { MetadataRoute } from 'next'

import { citySlug, listPublishedShops } from '@/lib/shop-queries'
import { siteUrl } from '@/lib/env'
import { routing } from '@/i18n/routing'

export const revalidate = 3600
export const dynamic = 'force-dynamic'

/**
 * Sitemap met hreflang.
 *
 * Elke pagina komt één keer voor, met een `alternates.languages`-blok dat naar
 * alle taalversies wijst. Dat is precies wat Google nodig heeft om een Spaanse
 * zoeker de Spaanse versie te tonen zonder de pagina's als duplicaat te zien.
 *
 * Nederlands heeft geen prefix (localePrefix 'as-needed'), dus die krijgt de
 * kale URL. De rest wel.
 */
export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const base = siteUrl()
  const shops = await listPublishedShops()
  const cities = [...new Set(shops.map((s) => citySlug(s.city)))]

  const url = (locale: string, path: string) =>
    locale === routing.defaultLocale ? `${base}${path}` : `${base}/${locale}${path}`

  const languagesFor = (path: string) =>
    Object.fromEntries(routing.locales.map((locale) => [locale, url(locale, path)]))

  const entry = (path: string, priority: number, lastModified?: Date) => ({
    url: url(routing.defaultLocale, path),
    lastModified,
    changeFrequency: 'weekly' as const,
    priority,
    alternates: { languages: { ...languagesFor(path), 'x-default': url('nl', path) } },
  })

  return [
    { ...entry('/', 1), changeFrequency: 'daily' as const },
    ...cities.map((city) => entry(`/kapper/${city}`, 0.8)),
    ...shops.map((shop) =>
      entry(
        `/kapper/${citySlug(shop.city)}/${shop.slug}`,
        0.9,
        new Date(shop.updated_at),
      ),
    ),
  ]
}
