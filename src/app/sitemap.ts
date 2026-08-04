import type { MetadataRoute } from 'next'
import { citySlug, listPublishedShops } from '@/lib/shop-queries'
import { siteUrl } from '@/lib/env'

export const revalidate = 3600

/**
 * Dynamische sitemap. Elke gepubliceerde salon en elke stad staat erin, met
 * lastModified uit de database — zo weet Google precies wat er veranderd is.
 */
export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const base = siteUrl()
  const shops = await listPublishedShops()

  const cities = [...new Set(shops.map((s) => citySlug(s.city)))]

  return [
    { url: base, changeFrequency: 'daily', priority: 1 },
    ...cities.map((city) => ({
      url: `${base}/kapper/${city}`,
      changeFrequency: 'weekly' as const,
      priority: 0.8,
    })),
    ...shops.map((shop) => ({
      url: `${base}/kapper/${citySlug(shop.city)}/${shop.slug}`,
      lastModified: new Date(shop.updated_at),
      changeFrequency: 'weekly' as const,
      priority: 0.9,
    })),
  ]
}
