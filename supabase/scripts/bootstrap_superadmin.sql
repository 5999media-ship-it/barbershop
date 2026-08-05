-- =============================================================================
-- supabase/scripts/bootstrap_superadmin.sql
-- De eerste platformbeheerder aanwijzen
-- =============================================================================
-- Dit is bewust géén migratie. Een migratie beschrijft de vórm van de database
-- en moet op elke lege database kunnen draaien; dit script wijst één bestaand
-- account aan en heeft dus een account nodig dat er al is. In de migratiemap
-- zou het de hele reeks laten omvallen bij een verse installatie.
-- =============================================================================
-- Kip-en-ei: `set_platform_admin()` eist dat de aanroeper zélf al beheerder is.
-- Dat is precies de bedoeling — niemand promoveert zichzelf via de app — maar
-- het betekent dat de allereerste beheerder buiten de app om moet worden gezet.
--
-- Dat kan hier, in de SQL Editor. Daar is session_user gelijk aan `postgres`,
-- en dat is de enige uitzondering die tg_profiles_guard toestaat. Draai dit
-- script dus in de Supabase SQL Editor, niet vanuit de app.
--
-- Het script is idempotent: twee keer draaien verandert niets extra's.
-- =============================================================================

set search_path = public, extensions;

do $$
declare
  v_email text := 'boybluedesigns@gmail.com';
  v_user  uuid;
begin
  select id into v_user
  from auth.users
  where lower(email) = lower(v_email)
  limit 1;

  if v_user is null then
    raise exception
      'Er bestaat nog geen account met %. Maak het eerst aan via Authentication -> Users -> Add user (Auto Confirm User aanvinken) en draai dit script daarna opnieuw.',
      v_email
      using errcode = 'P0001';
  end if;

  -- Normaal maakt de trigger on_auth_user_created het profiel al aan. Is het
  -- account ouder dan die trigger, dan ontbreekt de rij; vandaar deze insert.
  insert into public.profiles (id, email)
  values (v_user, v_email)
  on conflict (id) do nothing;

  -- De vlag zetten mag hier omdat session_user = postgres. Vanuit de app zou
  -- tg_profiles_guard deze wijziging stilzwijgend terugdraaien.
  update public.profiles
  set is_platform_admin = true,
      email = coalesce(email, v_email)
  where id = v_user;

  insert into public.audit_log (actor_id, action, entity, entity_id, diff)
  values (v_user, 'platform_admin.granted', 'profiles', v_user,
          jsonb_build_object('email', v_email, 'bron', 'migratie 20260805000100'));

  raise notice 'Klaar: % is nu platformbeheerder (id %).', v_email, v_user;
end $$;

-- -----------------------------------------------------------------------------
-- Controle. Draai dit los als je wilt zien wie er beheerder is.
-- -----------------------------------------------------------------------------
-- select u.email, p.is_platform_admin, p.created_at
-- from public.profiles p
-- join auth.users u on u.id = p.id
-- where p.is_platform_admin
-- order by p.created_at;
