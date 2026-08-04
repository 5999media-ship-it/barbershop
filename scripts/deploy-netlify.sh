#!/usr/bin/env bash
# =============================================================================
# Deployt deze app naar Netlify zonder tussenkomst van Git.
#
#   ./scripts/deploy-netlify.sh            # preview-deploy (eigen URL)
#   ./scripts/deploy-netlify.sh --prod     # productie
#
# De eerste keer vraagt de Netlify CLI om in te loggen en een site te kiezen of
# aan te maken. Daarna onthoudt hij dat in .netlify/state.json.
# =============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROD=""
[[ "${1:-}" == "--prod" ]] && PROD="--prod"

# -----------------------------------------------------------------------------
# Controle vooraf. Zonder deze drie doet de site niets: de build slaagt wel,
# maar elke pagina die de database aanraakt geeft een 500.
# -----------------------------------------------------------------------------
missing=()
[[ -z "${SUPABASE_URL:-}${NEXT_PUBLIC_SUPABASE_URL:-}" ]] && missing+=("SUPABASE_URL")
[[ -z "${SUPABASE_ANON_KEY:-}${NEXT_PUBLIC_SUPABASE_ANON_KEY:-}" ]] && missing+=("SUPABASE_ANON_KEY")
[[ -z "${SUPABASE_SERVICE_ROLE_KEY:-}" ]] && missing+=("SUPABASE_SERVICE_ROLE_KEY")

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "⚠  Niet in je shell gevonden: ${missing[*]}"
  echo
  echo "   Dat hoeft niet erg te zijn: als je ze al in de Netlify-UI hebt gezet"
  echo "   (Site configuration → Environment variables) pikt de build ze daar op."
  echo "   Zo niet, zet ze eenmalig met:"
  echo
  echo "     netlify env:set SUPABASE_URL https://<ref>.supabase.co"
  echo "     netlify env:set SUPABASE_ANON_KEY sb_publishable_..."
  echo "     netlify env:set SUPABASE_SERVICE_ROLE_KEY <secret>   # markeer als secret"
  echo
  read -r -p "   Toch doorgaan? [j/N] " answer
  [[ "$answer" =~ ^[jJyY]$ ]] || exit 1
fi

echo "==> Dependencies installeren"
npm ci

echo "==> Bouwen en deployen"
npx netlify deploy --build $PROD

echo
echo "Klaar. Vergeet niet:"
echo "  * SITE_URL in Netlify op je definitieve domein te zetten"
echo "    (anders staan er preview-URL's in je sitemap en JSON-LD);"
echo "  * de migraties uit supabase/ te draaien als je dat nog niet deed."
