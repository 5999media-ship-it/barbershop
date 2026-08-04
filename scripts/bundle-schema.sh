#!/usr/bin/env bash
set -euo pipefail
out=supabase/schema-full.sql
{
  echo "-- ============================================================================="
  echo "-- schema-full.sql — alle migraties achter elkaar, voor de Supabase SQL Editor."
  echo "-- GEGENEREERD BESTAND. Pas supabase/migrations/*.sql aan, niet dit bestand."
  echo "-- Opnieuw genereren: npm run db:bundle"
  echo "-- ============================================================================="
  for f in supabase/migrations/*.sql; do
    echo
    echo "-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"
    echo "-- $(basename "$f")"
    echo "-- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<"
    cat "$f"
  done
} > "$out"
echo "geschreven: $out ($(wc -l < "$out") regels)"
