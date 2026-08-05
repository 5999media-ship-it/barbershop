-- =============================================================================
-- supabase/scripts/accounts_overzicht.sql
-- Wie heeft er een account, en wat mag die?
-- =============================================================================
-- Draai dit in de SQL Editor als je wilt controleren dat er niemand is
-- binnengeglipt. Zolang "Allow new users to sign up" uitstaat, hoort deze lijst
-- alleen accounts te bevatten die jij zelf hebt aangemaakt.
--
-- Een regel met salons = 0 en beheerder = false is ongevaarlijk: zo iemand ziet
-- niets anders dan de publieke salonpagina's. Maar hij hóórt er ook niet te
-- staan, dus behandel hem als een signaal dat de aanmeldknop weer aanstaat.
-- =============================================================================

select
  u.email,
  u.created_at                                    as aangemaakt,
  u.last_sign_in_at                               as laatst_ingelogd,
  coalesce(p.is_platform_admin, false)            as beheerder,
  (select count(*) from public.shop_members m
    where m.user_id = u.id and m.is_active)       as salons,
  (select string_agg(s.name || ' (' || m.role || ')', ', ' order by s.name)
     from public.shop_members m
     join public.shops s on s.id = m.shop_id
    where m.user_id = u.id and m.is_active)       as rollen
from auth.users u
left join public.profiles p on p.id = u.id
order by u.created_at desc;
