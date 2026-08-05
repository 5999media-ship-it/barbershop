-- =============================================================================
-- 20260804000800_admin_only_shops.sql
-- Salons aanmaken is voorbehouden aan de platformbeheerder
-- =============================================================================
-- Tot nu toe mocht iedere ingelogde gebruiker een salon aanmaken (self-serve
-- onboarding). Dat past niet bij dit platform: jij bepaalt welke salons erop
-- staan. Iemand die zich registreert krijgt vanaf nu een account zonder salon,
-- en wacht tot jij hem koppelt.
--
-- Let op: dit is een échte beperking, geen verstopte knop. De policy hieronder
-- is wat telt. Zou ik alleen het formulier weghalen, dan kan iemand met de
-- publieke sleutel nog steeds een salon aanmaken met één REST-verzoek.
-- =============================================================================

set search_path = public, extensions;

drop policy if exists shops_insert_authenticated on public.shops;

create policy shops_insert_admin on public.shops
  for insert to authenticated
  with check (public.is_platform_admin() and created_by = auth.uid());

comment on policy shops_insert_admin on public.shops is
  'Alleen een platformbeheerder maakt salons aan. Zie migratie 000800.';

-- -----------------------------------------------------------------------------
-- Ook verwijderen blijft bij de platformbeheerder. Een shop_owner die zijn
-- eigen salon wist neemt alle afspraken en klantgegevens mee het graf in;
-- dat wil je als platform kunnen tegenhouden.
-- -----------------------------------------------------------------------------
drop policy if exists shops_delete_owner on public.shops;

create policy shops_delete_admin on public.shops
  for delete to authenticated
  using (public.is_platform_admin());

-- -----------------------------------------------------------------------------
-- Salon aanmaken én meteen aan een eigenaar hangen.
--
-- Waarom een functie en niet gewoon een INSERT vanuit de app? Omdat het één
-- handeling moet zijn: een salon zonder eigenaar is een weeskind waar niemand
-- meer bij kan, en dat is precies het soort halve toestand dat je op vrijdag
-- om zes uur ontdekt.
-- -----------------------------------------------------------------------------
create or replace function public.admin_create_shop(
  p_name        text,
  p_city        text,
  p_owner_email text default null,
  p_timezone    text default 'America/Curacao',
  p_currency    char(3) default 'ANG'
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

  -- Slug afleiden van de naam, met een oplopend achtervoegsel als hij bezet is.
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

  -- De trigger tg_shop_bootstrap_owner heeft de aanmaker al eigenaar gemaakt.
  -- Is er een ander e-mailadres opgegeven, dan gaat het eigenaarschap daarheen.
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
