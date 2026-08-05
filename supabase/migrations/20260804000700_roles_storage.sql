-- =============================================================================
-- 20260804000700_roles_storage.sql
-- Zelfbeheer voor kappers + opslag voor logo's en profielfoto's
-- =============================================================================
-- Uitbreiding op het rollenmodel:
--   platform_admin  jij, ziet en beheert alles
--   shop_owner      eigenaar van een salon
--   manager         mag alles binnen een salon behalve eigenaarschap
--   barber          beheert zijn eigen profiel, rooster, agenda en tarief
--
-- De kunst zit hem in "eigen tarief". Een kapper mag zijn prijs bepalen, maar
-- niet welke behandelingen er bestaan, niet hoe lang ze duren, en al helemaal
-- niet zichzelf aan de dienst van een andere salon koppelen. RLS alleen is
-- daar te grofmazig voor: een policy ziet de nieuwe rij, maar niet wélke
-- kolom er veranderd is. Vandaar opnieuw de combinatie policy + trigger.
-- =============================================================================

set search_path = public, extensions;

-- -----------------------------------------------------------------------------
-- tg_profiles_guard bijwerken
--
-- De guard blokkeert is_platform_admin voor iedereen behalve service_role en de
-- databaseowner. Dat is terecht, maar het blokkeert óók set_platform_admin()
-- hieronder: SECURITY DEFINER verandert current_user, niet session_user, dus
-- die functie ziet er van binnen uit als een gewone gebruiker.
--
-- Oplossing: een transactie-lokale vlag die alleen die ene functie zet. Een
-- client kan hem niet zelf zetten — daar is geen RPC voor.
-- -----------------------------------------------------------------------------
create or replace function public.tg_profiles_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text;
begin
  v_role := coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    current_setting('request.jwt.claim.role', true)
  );

  if new.is_platform_admin is distinct from old.is_platform_admin
     and coalesce(current_setting('bb.allow_admin_flag', true), '') <> '1'
     and v_role is distinct from 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    new.is_platform_admin := old.is_platform_admin;
  end if;
  new.id := old.id;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Kapper mag zijn eigen tarief aanpassen
-- -----------------------------------------------------------------------------
drop policy if exists barber_services_own_price on public.barber_services;
create policy barber_services_own_price on public.barber_services
  for update to authenticated
  using (
    exists (select 1 from public.barbers b
             where b.id = barber_id and b.user_id = auth.uid())
  )
  with check (
    exists (select 1 from public.barbers b
             where b.id = barber_id and b.user_id = auth.uid())
  );

create or replace function public.tg_barber_services_guard()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v_shop uuid;
begin
  select shop_id into v_shop from public.barbers where id = old.barber_id;

  if public.can_manage_shop(v_shop) then
    return new;
  end if;

  -- Een kapper mag uitsluitend price_cents aanraken.
  new.barber_id        := old.barber_id;
  new.service_id       := old.service_id;
  new.duration_minutes := old.duration_minutes;
  return new;
end;
$$;

drop trigger if exists barber_services_guard on public.barber_services;
create trigger barber_services_guard
  before update on public.barber_services
  for each row execute function public.tg_barber_services_guard();

-- -----------------------------------------------------------------------------
-- Kapper mag zijn eigen afspraken afhandelen
-- (bookings_update_staff dekte dit al; hier alleen expliciet gedocumenteerd)
-- -----------------------------------------------------------------------------
comment on policy bookings_update_staff on public.bookings is
  'Managers beheren alle afspraken van de salon; een kapper alleen die van zichzelf.';

-- =============================================================================
-- Opslag: logo per salon, profielfoto per kapper
-- =============================================================================
-- Eén publieke bucket. De mappenstructuur bepaalt wie wat mag:
--   shops/<shop_id>/logo.webp        beheerd door de admin
--   barbers/<barber_id>/avatar.webp  beheerd door de kapper zelf of de admin
--
-- Bestanden zijn publiek leesbaar — het zijn logo's op een openbare
-- salonpagina. Schrijven is streng afgeschermd.
-- =============================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 2097152, array['image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = 2097152,
      allowed_mime_types = array['image/webp'];

-- Hulpfunctie: hoort dit pad bij een salon of kapper die ik mag beheren?
create or replace function public.can_write_media(p_path text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  parts  text[] := string_to_array(p_path, '/');
  v_kind text;
  v_id   uuid;
begin
  if array_length(parts, 1) < 3 then
    return false;
  end if;

  v_kind := parts[1];

  -- Nooit blind casten: een pad als "shops/../../etc" laat de cast klappen
  -- en dat zou een 500 geven in plaats van een nette weigering.
  if parts[2] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  v_id := parts[2]::uuid;

  if v_kind = 'shops' then
    return public.can_manage_shop(v_id);
  elsif v_kind = 'barbers' then
    return exists (
      select 1 from public.barbers b
      where b.id = v_id
        and (b.user_id = auth.uid() or public.can_manage_shop(b.shop_id))
    );
  end if;

  return false;
end;
$$;

grant execute on function public.can_write_media(text) to authenticated;

drop policy if exists media_public_read   on storage.objects;
drop policy if exists media_insert_staff  on storage.objects;
drop policy if exists media_update_staff  on storage.objects;
drop policy if exists media_delete_staff  on storage.objects;

create policy media_public_read on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'media');

create policy media_insert_staff on storage.objects
  for insert to authenticated
  with check (bucket_id = 'media' and public.can_write_media(name));

create policy media_update_staff on storage.objects
  for update to authenticated
  using (bucket_id = 'media' and public.can_write_media(name))
  with check (bucket_id = 'media' and public.can_write_media(name));

create policy media_delete_staff on storage.objects
  for delete to authenticated
  using (bucket_id = 'media' and public.can_write_media(name));

-- =============================================================================
-- Platformbeheer: overzicht van alle salons voor de superadmin
-- =============================================================================
-- RLS laat een platform_admin alle shops al zien (is_platform_admin zit in
-- has_shop_role). Deze functie voegt alleen de tellingen toe die je in een
-- beheerscherm wilt zien, zonder vier losse queries vanuit de app.
-- =============================================================================
create or replace function public.admin_shop_overview()
returns table (
  id              uuid,
  slug            text,
  name            text,
  city            text,
  is_published    boolean,
  is_active       boolean,
  barber_count    integer,
  service_count   integer,
  booking_count   integer,
  upcoming_count  integer,
  created_at      timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'forbidden'
      using errcode = 'P0001', hint = 'Alleen een platformbeheerder kan dit overzicht opvragen.';
  end if;

  return query
  select
    s.id, s.slug, s.name, s.city, s.is_published, s.is_active,
    (select count(*)::int from public.barbers  b where b.shop_id = s.id and b.is_active),
    (select count(*)::int from public.services sv where sv.shop_id = s.id and sv.is_active),
    (select count(*)::int from public.bookings bk where bk.shop_id = s.id),
    (select count(*)::int from public.bookings bk where bk.shop_id = s.id
       and bk.status in ('pending','confirmed') and bk.starts_at > now()),
    s.created_at
  from public.shops s
  order by s.created_at desc;
end;
$$;

revoke all on function public.admin_shop_overview() from public, anon;
grant execute on function public.admin_shop_overview() to authenticated;

-- -----------------------------------------------------------------------------
-- Gebruiker koppelen aan een salon op e-mailadres
-- Een admin kent het user_id van zijn nieuwe kapper niet; hij kent zijn mail.
-- -----------------------------------------------------------------------------
create or replace function public.invite_member(
  p_shop_id uuid,
  p_email   text,
  p_role    public.app_role default 'barber'
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid;
  v_mail text := lower(btrim(coalesce(p_email, '')));
begin
  if not public.can_manage_shop(p_shop_id) then
    raise exception 'forbidden'
      using errcode = 'P0001', hint = 'Je hebt geen beheerrechten voor deze salon.';
  end if;

  if p_role = 'platform_admin' then
    raise exception 'forbidden'
      using errcode = 'P0001', hint = 'Deze rol kan niet worden toegekend.';
  end if;

  -- Alleen een eigenaar deelt de zwaardere rollen uit.
  if p_role in ('shop_owner', 'manager') and not public.is_shop_owner(p_shop_id) then
    raise exception 'forbidden'
      using errcode = 'P0001', hint = 'Alleen de eigenaar kan managers of eigenaren toevoegen.';
  end if;

  select id into v_user from auth.users where lower(email) = v_mail limit 1;

  if v_user is null then
    return jsonb_build_object(
      'ok', false,
      'reason', 'no_account',
      'hint', 'Deze persoon heeft nog geen account. Laat hem eerst registreren op de inlogpagina.'
    );
  end if;

  insert into public.shop_members (shop_id, user_id, role, invited_by)
  values (p_shop_id, v_user, p_role, auth.uid())
  on conflict (shop_id, user_id)
    do update set role = excluded.role, is_active = true;

  insert into public.audit_log (shop_id, actor_id, action, entity, entity_id, diff)
  values (p_shop_id, auth.uid(), 'member.invited', 'shop_members', v_user,
          jsonb_build_object('email', v_mail, 'role', p_role));

  return jsonb_build_object('ok', true, 'user_id', v_user);
end;
$$;

revoke all on function public.invite_member(uuid, text, public.app_role) from public, anon;
grant execute on function public.invite_member(uuid, text, public.app_role) to authenticated;

-- -----------------------------------------------------------------------------
-- Superadmin kan een gebruiker tot platformbeheerder maken
-- -----------------------------------------------------------------------------
create or replace function public.set_platform_admin(p_email text, p_value boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'forbidden' using errcode = 'P0001';
  end if;

  select id into v_user from auth.users where lower(email) = lower(btrim(p_email)) limit 1;
  if v_user is null then
    return jsonb_build_object('ok', false, 'reason', 'no_account');
  end if;

  -- Jezelf degraderen mag niet: anders heeft het platform ineens geen beheerder.
  if v_user = auth.uid() and p_value = false then
    raise exception 'cannot_demote_self'
      using errcode = 'P0001', hint = 'Je kunt jezelf niet als beheerder verwijderen.';
  end if;

  -- Transactie-lokale vlag: alleen hierdoor laat tg_profiles_guard de
  -- wijziging door. Wordt automatisch opgeruimd aan het eind van de transactie.
  perform set_config('bb.allow_admin_flag', '1', true);
  update public.profiles set is_platform_admin = p_value where id = v_user;
  perform set_config('bb.allow_admin_flag', '', true);

  insert into public.audit_log (actor_id, action, entity, entity_id, diff)
  values (auth.uid(), 'platform_admin.changed', 'profiles', v_user,
          jsonb_build_object('value', p_value));

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.set_platform_admin(text, boolean) from public, anon;
grant execute on function public.set_platform_admin(text, boolean) to authenticated;
