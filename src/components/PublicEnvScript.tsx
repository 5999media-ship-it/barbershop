import { publicEnv } from '@/lib/env'

/**
 * Zet de publieke configuratie op `window` vóórdat React hydrateert.
 *
 * Dit is een server component: hij leest de echte omgevingsvariabelen bij elke
 * request. Daardoor hoeft de Supabase-URL en publishable key niet tijdens de
 * build in de JavaScript-bundle gebakken te worden en werkt hetzelfde artefact
 * op elke omgeving.
 *
 * Beide waarden zijn per definitie publiek — de anon key hoort in de browser en
 * is zonder RLS waardeloos. De service-role key komt hier uiteraard nooit in.
 *
 * JSON.stringify wordt geëscaped tegen `</script>`-injectie; de waarden komen
 * weliswaar uit onze eigen omgeving, maar dit kost niets.
 */
export default function PublicEnvScript() {
  const json = JSON.stringify(publicEnv()).replace(/</g, '\\u003c')

  return (
    <script
      id="__public_env"
      // eslint-disable-next-line react/no-danger
      dangerouslySetInnerHTML={{ __html: `window.__PUBLIC_ENV__=${json};` }}
    />
  )
}
