-- =============================================================================
-- 20260804000200_rls_policies.sql
-- Row Level Security — het beveiligingsfundament
-- =============================================================================
-- Uitgangspunt: deny-by-default. RLS staat overal aan, en er is geen enkele
-- policy die breder is dan strikt nodig.
--
-- Belangrijk detail: alle helper-functies zijn SECURITY DEFINER. Zou je in een
-- policy op shop_members rechtstreeks shop_members bevragen, dan krijg je
-- oneindige recursie. De SECURITY DEFINER functie omzeilt RLS en breekt die lus.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Helper-functies
-- -----------------------------------------------------------------------------
-- Extensies staan op Supabase in het schema `extensions`; die moet in de
-- search_path staan voor operator- en opclass-resolutie (btree_gist!).
set search_path = public, extensions;


create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select p.is_platform_admin from public.profiles p where p.id = auth.uid()),
    false
  );
$$;

create or replace function public.has_shop_role(p_shop_id uuid, p_roles public.app_role[])
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_platform_admin()
      or exists (
        select 1
        from public.shop_members m
        where m.shop_id = p_shop_id
          and m.user_id = auth.uid()
          and m.is_active
          and m.role = any (p_roles)
      );
$$;

create or replace function public.is_shop_staff(p_shop_id uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select public.has_shop_role(p_shop_id, array['shop_owner','manager','barber']::public.app_role[]);
$$;

create or replace function public.can_manage_shop(p_shop_id uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select public.has_shop_role(p_shop_id, array['shop_owner','manager']::public.app_role[]);
$$;

create or replace function public.is_shop_owner(p_shop_id uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select public.has_shop_role(p_shop_id, array['shop_owner']::public.app_role[]);
$$;

-- Het barber-record van de ingelogde gebruiker binnen een shop (of null).
create or replace function public.current_barber_id(p_shop_id uuid)
returns uuid
language sql stable security definer set search_path = public, pg_temp
as $$
  select b.id from public.barbers b
  where b.shop_id = p_shop_id and b.user_id = auth.uid()
  limit 1;
$$;

-- Is deze shop publiek zichtbaar? Gebruikt in policies op child-tabellen.
create or replace function public.shop_is_public(p_shop_id uuid)
returns boolean
language sql stable security definer set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.shops s
    where s.id = p_shop_id and s.is_published and s.is_active
  );
$$;

-- =============================================================================
-- RLS aanzetten
-- =============================================================================
alter table public.profiles         enable row level security;
alter table public.shops            enable row level security;
alter table public.shop_members     enable row level security;
alter table public.barbers          enable row level security;
alter table public.services         enable row level security;
alter table public.barber_services  enable row level security;
alter table public.working_hours    enable row level security;
alter table public.time_off         enable row level security;
alter table public.shop_closures    enable row level security;
alter table public.bookings         enable row level security;
alter table public.notifications    enable row level security;
alter table public.booking_attempts enable row level security;
alter table public.audit_log        enable row level security;

-- Forceer RLS ook voor de table-owner waar het om gevoelige data gaat.
alter table public.bookings         force row level security;
alter table public.booking_attempts force row level security;

-- =============================================================================
-- profiles
-- =============================================================================
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_platform_admin());

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Tweede slot op de deur naast tg_profiles_guard: kolomrechten. Een gebruiker
-- kan is_platform_admin niet eens noemen in een UPDATE.
-- Let op de volgorde: een kolom-GRANT werkt alleen als de bredere table-GRANT
-- er eerst af is. Een losse `revoke update (kolom)` is een no-op.
revoke update on public.profiles from anon, authenticated;
grant update (full_name, phone, email, avatar_url, locale) on public.profiles to authenticated;

-- =============================================================================
-- shops
-- =============================================================================
drop policy if exists shops_select_public on public.shops;
create policy shops_select_public on public.shops
  for select to anon, authenticated
  using (is_published and is_active);

drop policy if exists shops_select_staff on public.shops;
create policy shops_select_staff on public.shops
  for select to authenticated
  using (public.is_shop_staff(id));

-- Iedere ingelogde gebruiker mag een shop aanmaken (self-serve onboarding).
-- created_by wordt vastgezet op de aanmaker; de trigger hieronder maakt hem
-- meteen shop_owner.
drop policy if exists shops_insert_authenticated on public.shops;
create policy shops_insert_authenticated on public.shops
  for insert to authenticated
  with check (created_by = auth.uid());

drop policy if exists shops_update_manager on public.shops;
create policy shops_update_manager on public.shops
  for update to authenticated
  using (public.can_manage_shop(id))
  with check (public.can_manage_shop(id));

drop policy if exists shops_delete_owner on public.shops;
create policy shops_delete_owner on public.shops
  for delete to authenticated
  using (public.is_shop_owner(id));

-- Aanmaker wordt automatisch eigenaar
create or replace function public.tg_shop_bootstrap_owner()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if new.created_by is not null then
    insert into public.shop_members (shop_id, user_id, role, invited_by)
    values (new.id, new.created_by, 'shop_owner', new.created_by)
    on conflict (shop_id, user_id) do update set role = 'shop_owner', is_active = true;
  end if;
  return new;
end;
$$;

drop trigger if exists shop_bootstrap_owner on public.shops;
create trigger shop_bootstrap_owner
  after insert on public.shops
  for each row execute function public.tg_shop_bootstrap_owner();

-- =============================================================================
-- shop_members
-- =============================================================================
drop policy if exists shop_members_select on public.shop_members;
create policy shop_members_select on public.shop_members
  for select to authenticated
  using (user_id = auth.uid() or public.is_shop_staff(shop_id));

-- Aanscherping: een manager mocht eerst zichzelf tot shop_owner promoveren en
-- de eigenaar uit zijn eigen zaak verwijderen. Nu geldt:
--   * je kunt nooit je eigen rij aanpassen of verwijderen;
--   * alleen een shop_owner deelt de rollen manager en shop_owner uit;
--   * een manager kan uitsluitend barbers beheren.
drop policy if exists shop_members_write on public.shop_members;
create policy shop_members_write on public.shop_members
  for all to authenticated
  using (
    public.can_manage_shop(shop_id)
    and user_id <> auth.uid()
    and (public.is_shop_owner(shop_id) or role = 'barber')
  )
  with check (
    public.can_manage_shop(shop_id)
    and user_id <> auth.uid()
    and role <> 'platform_admin'
    and (public.is_shop_owner(shop_id) or role = 'barber')
  );

-- =============================================================================
-- barbers / services / barber_services / working_hours  (publiek leesbaar)
-- =============================================================================
drop policy if exists barbers_select_public on public.barbers;
create policy barbers_select_public on public.barbers
  for select to anon, authenticated
  using (is_active and public.shop_is_public(shop_id));

drop policy if exists barbers_select_staff on public.barbers;
create policy barbers_select_staff on public.barbers
  for select to authenticated using (public.is_shop_staff(shop_id));

drop policy if exists barbers_write_manager on public.barbers;
create policy barbers_write_manager on public.barbers
  for all to authenticated
  using (public.can_manage_shop(shop_id))
  with check (public.can_manage_shop(shop_id));

-- Barber mag zijn eigen profiel bijwerken (bio, avatar, instagram).
drop policy if exists barbers_update_self on public.barbers;
create policy barbers_update_self on public.barbers
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Een WITH CHECK is hier niet genoeg: die kijkt alleen naar de nieuwe rij en
-- kan niet zien welke kolommen er veranderd zijn. Een trigger die de velden
-- letterlijk terugzet is wél waterdicht. Zonder
-- deze trigger kon een barber zijn eigen rij naar een vreemde shop verplaatsen
-- en zo de publieke pagina van een andere salon binnenwandelen — inclusief
-- toegang tot de klantgegevens van de boekingen die daar op hem binnenkwamen.
create or replace function public.tg_barbers_guard()
returns trigger
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  -- Managers en eigenaren mogen alles binnen hun eigen shop.
  if public.can_manage_shop(old.shop_id) and public.can_manage_shop(new.shop_id) then
    return new;
  end if;

  new.shop_id                 := old.shop_id;
  new.user_id                 := old.user_id;
  new.slug                    := old.slug;
  new.display_name            := old.display_name;
  new.is_active               := old.is_active;
  new.accepts_online_bookings := old.accepts_online_bookings;
  new.sort_order              := old.sort_order;
  return new;
end;
$$;

drop trigger if exists barbers_guard on public.barbers;
create trigger barbers_guard
  before update on public.barbers
  for each row execute function public.tg_barbers_guard();

drop policy if exists services_select_public on public.services;
create policy services_select_public on public.services
  for select to anon, authenticated
  using (is_active and public.shop_is_public(shop_id));

drop policy if exists services_select_staff on public.services;
create policy services_select_staff on public.services
  for select to authenticated using (public.is_shop_staff(shop_id));

drop policy if exists services_write_manager on public.services;
create policy services_write_manager on public.services
  for all to authenticated
  using (public.can_manage_shop(shop_id))
  with check (public.can_manage_shop(shop_id));

drop policy if exists barber_services_select on public.barber_services;
create policy barber_services_select on public.barber_services
  for select to anon, authenticated
  using (exists (select 1 from public.barbers b where b.id = barber_id
                 and (public.shop_is_public(b.shop_id) or public.is_shop_staff(b.shop_id))));

-- De dienst moet bij dezelfde shop horen als de barber. Zonder die join kon
-- iemand een dienst van een andere salon aan zijn eigen barber koppelen en
-- daar een eigen prijs op zetten.
drop policy if exists barber_services_write on public.barber_services;
create policy barber_services_write on public.barber_services
  for all to authenticated
  using (
    exists (
      select 1 from public.barbers b
      join public.services sv on sv.id = service_id and sv.shop_id = b.shop_id
      where b.id = barber_id and public.can_manage_shop(b.shop_id)
    )
  )
  with check (
    exists (
      select 1 from public.barbers b
      join public.services sv on sv.id = service_id and sv.shop_id = b.shop_id
      where b.id = barber_id and public.can_manage_shop(b.shop_id)
    )
  );

drop policy if exists working_hours_select on public.working_hours;
create policy working_hours_select on public.working_hours
  for select to anon, authenticated
  using (exists (select 1 from public.barbers b where b.id = barber_id
                 and (public.shop_is_public(b.shop_id) or public.is_shop_staff(b.shop_id))));

drop policy if exists working_hours_write on public.working_hours;
create policy working_hours_write on public.working_hours
  for all to authenticated
  using (exists (select 1 from public.barbers b where b.id = barber_id
                 and (public.can_manage_shop(b.shop_id) or b.user_id = auth.uid())))
  with check (exists (select 1 from public.barbers b where b.id = barber_id
                 and (public.can_manage_shop(b.shop_id) or b.user_id = auth.uid())));

-- =============================================================================
-- time_off / shop_closures
-- Bewust NIET publiek leesbaar: "Ahmed is 3 weken op vakantie in Marokko" is
-- privégegeven. De beschikbaarheid lekt alleen als afwezig slot via de RPC.
-- =============================================================================
drop policy if exists time_off_staff on public.time_off;
create policy time_off_staff on public.time_off
  for all to authenticated
  using (exists (select 1 from public.barbers b where b.id = barber_id
                 and (public.can_manage_shop(b.shop_id) or b.user_id = auth.uid())))
  with check (exists (select 1 from public.barbers b where b.id = barber_id
                 and (public.can_manage_shop(b.shop_id) or b.user_id = auth.uid())));

drop policy if exists shop_closures_select on public.shop_closures;
create policy shop_closures_select on public.shop_closures
  for select to authenticated using (public.is_shop_staff(shop_id));

drop policy if exists shop_closures_write on public.shop_closures;
create policy shop_closures_write on public.shop_closures
  for all to authenticated
  using (public.can_manage_shop(shop_id))
  with check (public.can_manage_shop(shop_id));

-- =============================================================================
-- bookings
-- Geen enkele policy voor rol `anon`. Een gast kan dus NOOIT boekingen lezen,
-- ook niet met een geraden UUID. Gastboeken en -annuleren loopt uitsluitend via
-- SECURITY DEFINER RPC's die het manage_token verifiëren.
-- =============================================================================
drop policy if exists bookings_select_staff on public.bookings;
create policy bookings_select_staff on public.bookings
  for select to authenticated
  using (
    public.can_manage_shop(shop_id)
    or barber_id = public.current_barber_id(shop_id)
    or customer_id = auth.uid()
  );

-- Personeel mag handmatig inplannen (telefonisch, walk-in).
drop policy if exists bookings_insert_staff on public.bookings;
create policy bookings_insert_staff on public.bookings
  for insert to authenticated
  with check (
    public.is_shop_staff(shop_id)
    and (public.can_manage_shop(shop_id) or barber_id = public.current_barber_id(shop_id))
  );

drop policy if exists bookings_update_staff on public.bookings;
create policy bookings_update_staff on public.bookings
  for update to authenticated
  using (public.can_manage_shop(shop_id) or barber_id = public.current_barber_id(shop_id))
  with check (public.can_manage_shop(shop_id) or barber_id = public.current_barber_id(shop_id));

-- Verwijderen mag niet. Annuleren is een statuswijziging, zodat de historie
-- (en de no-show statistiek) intact blijft.
drop policy if exists bookings_delete_owner on public.bookings;
create policy bookings_delete_owner on public.bookings
  for delete to authenticated
  using (public.is_platform_admin());

-- =============================================================================
-- notifications / booking_attempts / audit_log — alleen lezen voor personeel
-- =============================================================================
drop policy if exists notifications_select_staff on public.notifications;
create policy notifications_select_staff on public.notifications
  for select to authenticated using (public.can_manage_shop(shop_id));

drop policy if exists audit_log_select_staff on public.audit_log;
create policy audit_log_select_staff on public.audit_log
  for select to authenticated using (public.can_manage_shop(shop_id));

-- booking_attempts: geen enkele policy => volledig dicht voor anon/authenticated.

-- =============================================================================
-- Expliciete grants (belt-and-braces bovenop RLS)
-- =============================================================================
revoke all on public.booking_attempts from anon, authenticated;
revoke all on public.audit_log        from anon, authenticated;
revoke all on public.notifications    from anon, authenticated;
grant select on public.notifications  to authenticated;
grant select on public.audit_log      to authenticated;

-- manage_token mag nooit via de REST-API uitgelezen worden.
--
-- Belangrijk Postgres-detail: `revoke select (kolom)` haalt alleen kolom-grants
-- weg. Zolang er een table-brede SELECT-grant staat (en die zet Supabase er
-- standaard op) dekt die gewoon álle kolommen — inclusief manage_token.
-- Je moet dus eerst de table-grant intrekken en daarna expliciet de toegestane
-- kolommen teruggeven.
revoke select on public.bookings from anon, authenticated;
grant select (
  id, shop_id, barber_id, service_id, customer_id,
  customer_name, customer_email, customer_phone,
  starts_at, ends_at, service_end_at,
  status, price_cents, currency, notes, internal_note, source,
  cancelled_at, cancelled_by, cancel_reason, created_at, updated_at
) on public.bookings to authenticated;

revoke insert, update, delete on public.bookings from anon;

-- shop_id van een bestaande boeking ligt vast. De samengestelde foreign keys
-- dekken dit al af, maar een expliciete fout leest prettiger dan een
-- FK-violation.
create or replace function public.tg_bookings_immutable_tenant()
returns trigger language plpgsql as $$
begin
  if new.shop_id is distinct from old.shop_id then
    raise exception 'booking_tenant_immutable'
      using errcode = 'P0001', hint = 'Een afspraak kan niet naar een andere salon verplaatst worden.';
  end if;
  return new;
end;
$$;

drop trigger if exists bookings_immutable_tenant on public.bookings;
create trigger bookings_immutable_tenant
  before update on public.bookings
  for each row execute function public.tg_bookings_immutable_tenant();
revoke all on public.time_off from anon;
revoke all on public.shop_closures from anon;
