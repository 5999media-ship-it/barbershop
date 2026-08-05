import type { Metadata } from 'next'

import NewShopForm from '@/components/dashboard/NewShopForm'

// Niet prerenderen: de runtime-configuratie wordt in de layout geïnjecteerd en
// zou anders met bouwtijd-waarden in de statische HTML belanden.
export const dynamic = 'force-dynamic'

export const metadata: Metadata = {
  title: 'Salon aanmaken',
  robots: { index: false, follow: false },
}

/**
 * Landingspagina voor een nieuwe gebruiker zonder salon.
 * Staat bewust BUITEN /dashboard: die layout eist een actieve shop en zou hier
 * anders in een oneindige redirect-lus belanden.
 */
export default function NewShopPage() {
  return (
    <main className="mx-auto max-w-md px-5 py-20">
      <h1 className="text-3xl font-semibold tracking-tight">Je eerste salon</h1>
      <p className="mt-3 mb-8 text-ink-300">
        Geef je zaak een naam en plaats. De rest — behandelingen, team, werktijden — vul je
        daarna in het dashboard aan. Je salon staat pas online als je hem publiceert.
      </p>
      <NewShopForm />
    </main>
  )
}
