import Link from 'next/link'

/**
 * Wortel-404.
 *
 * Dit bestand is een vangnet, geen sierstuk. De wortel-layout
 * (`src/app/layout.tsx`) geeft bewust alleen `children` terug: <html> en <body>
 * staan in `[locale]/layout.tsx`, omdat het lang-attribuut pas bekend is zodra
 * de taal uit de URL is gelezen.
 *
 * Gevolg: een 404 die búiten `[locale]` valt, heeft géén <html> om in te
 * hangen. Next.js valt dan terug op zijn ingebouwde foutpagina, en die
 * verwacht wél een compleet document. Lokaal levert dat een nette 404 op, maar
 * op een serverless platform loopt het renderen stuk en krijgt de bezoeker een
 * 500 — een serverfout op je voorpagina, wat het slechtst denkbare visitekaartje
 * is en bovendien je indexering schaadt.
 *
 * Dit bestand rendert daarom zelf een volledig HTML-document. Zolang de
 * middleware doet wat hij hoort te doen (`/` → `/nl`) komt niemand hier ooit;
 * gaat er iets mis met de middleware, dan ziet de bezoeker een 404 met een weg
 * terug in plaats van een serverfout.
 */
export default function RootNotFound() {
  return (
    <html lang="nl">
      <body
        style={{
          margin: 0,
          minHeight: '100vh',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          background: '#0b0b0d',
          color: '#faf9f7',
          fontFamily:
            'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
        }}
      >
        <main style={{ maxWidth: '32rem', padding: '2rem', textAlign: 'center' }}>
          <p
            style={{
              margin: 0,
              fontSize: '0.75rem',
              letterSpacing: '0.2em',
              textTransform: 'uppercase',
              color: '#c9a227',
            }}
          >
            404
          </p>
          <h1 style={{ margin: '0.75rem 0 0', fontSize: '1.75rem', lineHeight: 1.2 }}>
            Deze pagina bestaat niet
          </h1>
          <p style={{ margin: '0.75rem 0 1.75rem', color: '#a1a1aa', lineHeight: 1.6 }}>
            Misschien is de link verouderd. Kies hieronder je taal en boek gewoon verder.
          </p>
          <nav style={{ display: 'flex', gap: '0.75rem', justifyContent: 'center', flexWrap: 'wrap' }}>
            {[
              { href: '/nl', label: 'Nederlands' },
              { href: '/en', label: 'English' },
              { href: '/es', label: 'Español' },
              { href: '/pap', label: 'Papiamentu' },
            ].map((item) => (
              <Link
                key={item.href}
                href={item.href}
                style={{
                  padding: '0.6rem 1.1rem',
                  borderRadius: '9999px',
                  border: '1px solid #2a2a2e',
                  color: '#faf9f7',
                  textDecoration: 'none',
                  fontSize: '0.9rem',
                }}
              >
                {item.label}
              </Link>
            ))}
          </nav>
        </main>
      </body>
    </html>
  )
}
