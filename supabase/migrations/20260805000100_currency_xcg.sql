-- =============================================================================
-- 20260805000100_currency_xcg.sql
-- ANG bestaat niet meer: Curaçao en Sint Maarten rekenen in XCG
-- =============================================================================
-- Per 31 maart 2025 is de Antilliaanse gulden (ANG) vervangen door de
-- Caribische gulden (XCG), één op één, met dezelfde koppeling aan de dollar.
-- XCG is de officiële ISO 4217-code; ANG is ingetrokken.
--
-- Dit is geen cosmetisch detail. `Intl.NumberFormat` kent XCG en toont "Cg.",
-- terwijl ANG als kale lettercode blijft staan. Betaaldienstverleners die je
-- later koppelt weigeren bovendien een ingetrokken code.
--
-- Idempotent: twee keer draaien verandert niets extra's.
-- =============================================================================

set search_path = public, extensions;

-- -----------------------------------------------------------------------------
-- Bestaande gegevens omzetten. De koers is 1:1, dus bedragen blijven gelijk;
-- alleen het label klopt weer.
-- -----------------------------------------------------------------------------
update public.shops    set currency = 'XCG' where currency = 'ANG';
update public.bookings set currency = 'XCG' where currency = 'ANG';

-- -----------------------------------------------------------------------------
-- De standaardwaarde van admin_create_shop bijstellen. De rest van de functie
-- blijft ongewijzigd; alleen `p_currency` krijgt een andere default.
-- -----------------------------------------------------------------------------
create or replace function public.admin_create_shop(
  p_name        text,
  p_city        text,
  p_owner_email text default null,
  p_timezone    text default 'America/Curacao',
  p_currency    char(3) default 'XCG'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_slug  text;
  v_base  text;
  v_shop  uuid;
  v_owner uuid;
  v_n     int := 0;
begin
  if not public.is_platform_admin() then
    raise exception 'forbidden'
      using errcode = 'P0001', hint = 'Alleen de platformbeheerder kan een salon aanmaken.';
  end if;

  if char_length(btrim(coalesce(p_name, ''))) < 2 then
    raise exception 'invalid_name' using errcode = 'P0001', hint = 'Vul een naam in.';
  end if;
  if char_length(btrim(coalesce(p_city, ''))) < 2 then
    raise exception 'invalid_city' using errcode = 'P0001', hint = 'Vul een plaats in.';
  end if;

  v_base := regexp_replace(lower(btrim(p_name)), '[^a-z0-9]+', '-', 'g');
  v_base := btrim(v_base, '-');
  if char_length(v_base) < 3 then v_base := 'salon-' || v_base; end if;
  v_base := left(v_base, 50);
  v_slug := v_base;

  while exists (select 1 from public.shops s where s.slug = v_slug) loop
    v_n := v_n + 1;
    v_slug := v_base || '-' || v_n;
    if v_n > 50 then
      raise exception 'slug_exhausted'
        using errcode = 'P0001', hint = 'Kies een iets andere naam.';
    end if;
  end loop;

  insert into public.shops (slug, name, city, timezone, currency, created_by)
  values (v_slug, btrim(p_name), btrim(p_city), p_timezone, p_currency, auth.uid())
  returning id into v_shop;

  if nullif(btrim(coalesce(p_owner_email, '')), '') is not null then
    select id into v_owner
    from auth.users
    where lower(email) = lower(btrim(p_owner_email))
    limit 1;

    if v_owner is null then
      return jsonb_build_object(
        'ok', true,
        'shop_id', v_shop,
        'slug', v_slug,
        'warning', 'no_account',
        'hint', 'De salon is aangemaakt, maar er bestaat nog geen account met dat e-mailadres. Koppel de eigenaar later bij Team.'
      );
    end if;

    insert into public.shop_members (shop_id, user_id, role, invited_by)
    values (v_shop, v_owner, 'shop_owner', auth.uid())
    on conflict (shop_id, user_id) do update set role = 'shop_owner', is_active = true;
  end if;

  insert into public.audit_log (shop_id, actor_id, action, entity, entity_id, diff)
  values (v_shop, auth.uid(), 'shop.created', 'shops', v_shop,
          jsonb_build_object('name', p_name, 'city', p_city, 'owner', p_owner_email));

  return jsonb_build_object('ok', true, 'shop_id', v_shop, 'slug', v_slug);
end;
$$;

revoke all on function public.admin_create_shop(text, text, text, text, char) from public, anon;
grant execute on function public.admin_create_shop(text, text, text, text, char) to authenticated;
