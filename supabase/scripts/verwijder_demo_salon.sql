-- =============================================================================
-- supabase/scripts/verwijder_demo_salon.sql
-- De demo-salon "Junique Fades" weghalen
-- =============================================================================
-- Migratie 20260804000600_seed_demo.sql zet één voorbeeldsalon in de database:
-- Junique Fades in Amsterdam, met kappers, behandelingen en werktijden. Die is
-- er om het boekingsscherm te kunnen testen zonder dat je eerst handmatig een
-- salon moet inrichten — niet om live te staan.
--
-- Zodra je je eigen salons hebt aangemaakt, mag hij weg. Alles wat eraan hangt
-- verdwijnt mee via `on delete cascade`: kappers, behandelingen, werktijden,
-- boekingen en berichten.
--
-- Wil je hem alleen tijdelijk verbergen in plaats van wissen, gebruik dan de
-- tweede variant onderaan. Verbergen is omkeerbaar, wissen niet.
-- =============================================================================

-- --- Variant 1: definitief verwijderen ---------------------------------------
delete from public.shops
where id = '11111111-1111-4111-8111-111111111111';

-- --- Variant 2: alleen van de site halen -------------------------------------
-- Zet variant 1 in commentaar en haal deze twee regels uit commentaar.
--
-- update public.shops
-- set is_published = false, is_active = false
-- where id = '11111111-1111-4111-8111-111111111111';

-- --- Controle ----------------------------------------------------------------
select id, slug, name, city, currency, is_published
from public.shops
order by created_at;
