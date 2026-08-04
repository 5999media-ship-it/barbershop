import type { MetadataRoute } from 'next'

import { siteUrl } from '@/lib/env'

// Niet prerenderen: de site-URL komt uit de runtime-omgeving van de deploy.
export const dynamic = 'force-dynamic'

export default function robots(): MetadataRoute.Robots {
  const base = siteUrl()
  return {
    rules: [
      {
        userAgent: '*',
        allow: '/',
        // Persoonsgegevens en flows die geen zoekwaarde hebben.
        disallow: ['/afspraak/', '/dashboard/', '/api/', '/login'],
      },
    ],
    sitemap: `${base}/sitemap.xml`,
  }
}
