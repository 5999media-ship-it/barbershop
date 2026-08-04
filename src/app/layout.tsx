import type { Metadata, Viewport } from 'next'

import PublicEnvScript from '@/components/PublicEnvScript'
import { siteUrl } from '@/lib/env'
import './globals.css'

// generateMetadata in plaats van een statisch object: metadataBase moet de
// echte site-URL van deze omgeving bevatten, en die kennen we pas bij runtime.
export async function generateMetadata(): Promise<Metadata> {
  return {
    metadataBase: new URL(siteUrl()),
    title: {
      default: 'Kapper afspraak maken — online boeken bij barbershops',
      template: '%s | BarberBook',
    },
    description:
      'Boek in dertig seconden een afspraak bij je barbershop. Kies je behandeling, je barber en je tijd — zonder account, zonder gedoe.',
    openGraph: {
      type: 'website',
      locale: 'nl_NL',
      siteName: 'BarberBook',
    },
    robots: { index: true, follow: true },
  }
}

export const viewport: Viewport = {
  themeColor: '#0b0b0d',
  width: 'device-width',
  initialScale: 1,
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="nl">
      <body>
        <PublicEnvScript />
        <a href="#main" className="skip-link">
          Naar de inhoud
        </a>
        <div id="main">{children}</div>
      </body>
    </html>
  )
}
