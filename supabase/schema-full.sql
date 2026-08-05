-- =============================================================================
-- schema-full.sql — alle migraties achter elkaar, voor de Supabase SQL Editor.
-- GEGENEREERD BESTAND. Pas supabase/migrations/*.sql aan, niet dit bestand.
-- Opnieuw genereren: npm run db:bundle
-- =============================================================================

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
-- 20260804000100_init_schema.sql
-- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
-- =============================================================================
-- 20260804000100_init_schema.sql
-- Barber Booking Platform — multi-tenant kernschema
-- =============================================================================
-- Ontwerpprincipes:
--  1. Tenant = shop. Elke rij die bij een tenant hoort draagt shop_id.
--  2. Integriteit wordt in de database afgedwongen, niet in de applicatie.
--     De EXCLUDE-constraint op bookings maakt dubbelboeken fysiek onmogelijk,
--     ook bij gelijktijdige requests (race conditions).
--  3. Geen enkele publieke rol mag rechtstreeks in bookings schrijven; dat gaat
--     uitsluitend via SECURITY DEFINER RPC's (zie migratie 000400).
-- =============================================================================

-- Extensies staan op Supabase in het schema `extensions`; die moet in de
-- search_path staan voor operator- en opclass-resolutie (btree_gist!).
set search_path = public, extensions;


create extension if not exists "pgcrypto"   with schema extensions;
create extension if not exists "btree_gist"  with schema extensions;
-- Bewust géén citext: e-mailadressen en slugs worden bij binnenkomst
-- genormaliseerd naar lowercase. Dat is portabeler en voorkomt gedoe met
-- operator-resolutie wanneer de extensie in een ander schema staat.

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
do $$ begin
  create type public.app_role as enum ('platform_admin', 'shop_owner', 'manager', 'barber');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.booking_status as enum ('pending', 'confirmed', 'completed', 'cancelled', 'no_show');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.notification_channel as enum ('email', 'sms', 'whatsapp');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.notification_status as enum ('queued', 'sending', 'sent', 'failed', 'cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.notification_template as enum (
    'booking_confirmation',
    'booking_reminder_24h',
    'booking_reminder_2h',
    'booking_cancelled',
    'booking_rescheduled',
    'staff_new_booking'
  );
exception when duplicate_object then null; end $$;

-- -----------------------------------------------------------------------------
-- Generieke updated_at trigger
-- -----------------------------------------------------------------------------
create or replace function public.tg_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- profiles — 1-op-1 met auth.users
-- -----------------------------------------------------------------------------
create table if not exists public.profiles (
  id                uuid primary key references auth.users (id) on delete cascade,
  full_name         text,
  phone             text,
  email             text,
  avatar_url        text,
  -- Platform-admin vlag. Wordt beschermd door tg_profiles_guard: een gebruiker
  -- kan zichzelf nooit promoveren, ook niet met een geknutselde PATCH.
  is_platform_admin boolean not null default false,
  locale            text not null default 'nl',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

comment on table public.profiles is 'Publiek profiel per auth-gebruiker. is_platform_admin is alleen door service_role te zetten.';

create or replace function public.tg_profiles_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_role text;
begin
  -- LET OP: hier stond eerst current_user. Binnen een SECURITY DEFINER functie
  -- is current_user altijd de eigenaar (postgres), waardoor de check nooit
  -- aansloeg en iedere ingelogde gebruiker zichzelf platform_admin kon maken.
  -- session_user is de rol waarmee de verbinding daadwerkelijk is opgezet.
  v_role := coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
    current_setting('request.jwt.claim.role', true)
  );

  if new.is_platform_admin is distinct from old.is_platform_admin
     and v_role is distinct from 'service_role'
     and session_user not in ('postgres', 'supabase_admin') then
    new.is_platform_admin := old.is_platform_admin;
  end if;
  new.id := old.id;
  return new;
end;
$$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard
  before update on public.profiles
  for each row execute function public.tg_profiles_guard();

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.tg_set_updated_at();

-- Automatisch profiel aanmaken bij signup
create or replace function public.tg_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name, email, phone)
  values (
    new.id,
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), ''),
    new.email,
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'phone', '')), '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.tg_handle_new_user();

-- -----------------------------------------------------------------------------
-- shops — de tenant
-- -----------------------------------------------------------------------------
create table if not exists public.shops (
  id                    uuid primary key default gen_random_uuid(),
  slug                  text not null unique
                          check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) between 3 and 60),
  name                  text not null check (char_length(btrim(name)) between 2 and 120),
  tagline               text check (char_length(tagline) <= 160),
  description           text check (char_length(description) <= 4000),

  -- NAP-gegevens: essentieel voor lokale SEO en schema.org LocalBusiness
  phone                 text,
  email                 text,
  website               text,
  street                text,
  house_number          text,
  postal_code           text,
  city                  text,
  region                text,
  country_code          char(2) not null default 'NL',
  latitude              numeric(9,6) check (latitude between -90 and 90),
  longitude             numeric(9,6) check (longitude between -180 and 180),
  google_place_id       text,
  instagram_url         text,

  timezone              text not null default 'Europe/Amsterdam',
  currency              char(3) not null default 'EUR',
  logo_url              text,
  cover_url             text,

  -- Boekingsbeleid
  slot_interval_minutes smallint not null default 15
                          check (slot_interval_minutes in (5, 10, 15, 20, 30, 60)),
  min_lead_minutes      integer  not null default 60  check (min_lead_minutes between 0 and 43200),
  max_advance_days      smallint not null default 60  check (max_advance_days between 1 and 365),
  cancel_cutoff_hours   smallint not null default 12  check (cancel_cutoff_hours between 0 and 168),
  max_open_per_customer smallint not null default 3   check (max_open_per_customer between 1 and 20),

  is_active             boolean not null default true,
  is_published          boolean not null default false,

  created_by            uuid references auth.users (id) on delete set null,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),

  -- Timezone moet een geldige IANA-zone zijn
  constraint shops_timezone_valid check (now() at time zone timezone is not null)
);

create index if not exists shops_city_idx      on public.shops (lower(city)) where is_published;
create index if not exists shops_published_idx on public.shops (is_published, is_active);

drop trigger if exists shops_set_updated_at on public.shops;
create trigger shops_set_updated_at before update on public.shops
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- shop_members — wie mag wat binnen een shop
-- -----------------------------------------------------------------------------
create table if not exists public.shop_members (
  id         uuid primary key default gen_random_uuid(),
  shop_id    uuid not null references public.shops (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       public.app_role not null default 'barber' check (role <> 'platform_admin'),
  is_active  boolean not null default true,
  invited_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (shop_id, user_id)
);

create index if not exists shop_members_user_idx on public.shop_members (user_id) where is_active;

drop trigger if exists shop_members_set_updated_at on public.shop_members;
create trigger shop_members_set_updated_at before update on public.shop_members
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- barbers — het personeelslid dat geboekt wordt
-- Losgekoppeld van auth.users zodat een shop ook barbers kan inplannen
-- die (nog) geen account hebben.
-- -----------------------------------------------------------------------------
create table if not exists public.barbers (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  user_id      uuid references auth.users (id) on delete set null,
  slug         text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  display_name text not null check (char_length(btrim(display_name)) between 2 and 80),
  bio          text check (char_length(bio) <= 1000),
  avatar_url   text,
  instagram    text,
  is_active    boolean not null default true,
  accepts_online_bookings boolean not null default true,
  sort_order   smallint not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (shop_id, slug),
  unique (shop_id, user_id),
  -- Nodig voor de samengestelde foreign key vanuit bookings: die dwingt af dat
  -- een boeking, zijn barber en zijn dienst altijd bij dezelfde shop horen.
  unique (id, shop_id)
);

create index if not exists barbers_shop_idx on public.barbers (shop_id) where is_active;

drop trigger if exists barbers_set_updated_at on public.barbers;
create trigger barbers_set_updated_at before update on public.barbers
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- services — de behandelingen
-- -----------------------------------------------------------------------------
create table if not exists public.services (
  id                    uuid primary key default gen_random_uuid(),
  shop_id               uuid not null references public.shops (id) on delete cascade,
  slug                  text not null check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name                  text not null check (char_length(btrim(name)) between 2 and 100),
  description           text check (char_length(description) <= 1000),
  category              text,
  duration_minutes      smallint not null check (duration_minutes between 5 and 480),
  -- Opruimtijd na de behandeling. Telt mee voor de bezetting, niet voor de prijs.
  buffer_after_minutes  smallint not null default 0 check (buffer_after_minutes between 0 and 120),
  price_cents           integer not null check (price_cents >= 0),
  is_active             boolean not null default true,
  sort_order            smallint not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (shop_id, slug),
  unique (id, shop_id)
);

create index if not exists services_shop_idx on public.services (shop_id) where is_active;

drop trigger if exists services_set_updated_at on public.services;
create trigger services_set_updated_at before update on public.services
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- barber_services — welke barber doet welke dienst (met optionele afwijking)
-- -----------------------------------------------------------------------------
create table if not exists public.barber_services (
  barber_id        uuid not null references public.barbers (id)  on delete cascade,
  service_id       uuid not null references public.services (id) on delete cascade,
  price_cents      integer  check (price_cents >= 0),
  duration_minutes smallint check (duration_minutes between 5 and 480),
  primary key (barber_id, service_id)
);

create index if not exists barber_services_service_idx on public.barber_services (service_id);

-- -----------------------------------------------------------------------------
-- working_hours — terugkerend rooster per barber (lokale tijd van de shop)
-- Meerdere rijen per weekdag => gebroken diensten (bv. 09:00-13:00 en 14:00-18:00)
-- -----------------------------------------------------------------------------
create table if not exists public.working_hours (
  id         uuid primary key default gen_random_uuid(),
  barber_id  uuid not null references public.barbers (id) on delete cascade,
  -- 0 = zondag ... 6 = zaterdag (gelijk aan Postgres EXTRACT(DOW))
  weekday    smallint not null check (weekday between 0 and 6),
  start_time time not null,
  end_time   time not null,
  created_at timestamptz not null default now(),
  constraint working_hours_order check (end_time > start_time)
);

create index if not exists working_hours_barber_idx on public.working_hours (barber_id, weekday);

-- -----------------------------------------------------------------------------
-- time_off — vakantie, ziekte, geblokkeerde tijd van één barber
-- -----------------------------------------------------------------------------
create table if not exists public.time_off (
  id         uuid primary key default gen_random_uuid(),
  barber_id  uuid not null references public.barbers (id) on delete cascade,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  reason     text check (char_length(reason) <= 200),
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  constraint time_off_order check (ends_at > starts_at)
);

create index if not exists time_off_barber_idx on public.time_off using gist (barber_id, tstzrange(starts_at, ends_at, '[)'));

-- -----------------------------------------------------------------------------
-- shop_closures — feestdagen / hele shop dicht
-- -----------------------------------------------------------------------------
create table if not exists public.shop_closures (
  id         uuid primary key default gen_random_uuid(),
  shop_id    uuid not null references public.shops (id) on delete cascade,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  reason     text check (char_length(reason) <= 200),
  created_at timestamptz not null default now(),
  constraint shop_closures_order check (ends_at > starts_at)
);

create index if not exists shop_closures_shop_idx on public.shop_closures using gist (shop_id, tstzrange(starts_at, ends_at, '[)'));

-- -----------------------------------------------------------------------------
-- bookings — het hart
-- -----------------------------------------------------------------------------
create table if not exists public.bookings (
  id               uuid primary key default gen_random_uuid(),
  shop_id          uuid not null references public.shops (id)    on delete cascade,
  barber_id        uuid not null references public.barbers (id)  on delete restrict,
  service_id       uuid not null references public.services (id) on delete restrict,

  -- Ingelogde klant is optioneel: gastboekingen zijn expliciet ondersteund.
  customer_id      uuid references auth.users (id) on delete set null,
  customer_name    text   not null check (char_length(btrim(customer_name)) between 2 and 100),
  customer_email   text not null check (customer_email ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'),
  customer_phone   text   not null check (char_length(regexp_replace(customer_phone, '\D', '', 'g')) between 6 and 15),

  starts_at        timestamptz not null,
  -- ends_at is inclusief buffer: dit is het blok dat de agenda bezet houdt.
  ends_at          timestamptz not null,
  service_end_at   timestamptz not null, -- einde van de behandeling zelf (voor de klant)

  status           public.booking_status not null default 'confirmed',
  price_cents      integer not null check (price_cents >= 0),
  currency         char(3) not null default 'EUR',

  notes            text check (char_length(notes) <= 1000),           -- door de klant
  internal_note    text check (char_length(internal_note) <= 1000),   -- alleen personeel

  -- Geheime sleutel waarmee een gast zijn afspraak kan bekijken/annuleren
  -- zonder account. Wordt nooit via RLS blootgesteld, alleen via RPC.
  manage_token     uuid not null default gen_random_uuid(),

  source           text not null default 'web' check (source in ('web', 'dashboard', 'phone', 'walk_in', 'api')),
  cancelled_at     timestamptz,
  cancelled_by     text check (cancelled_by in ('customer', 'shop', 'system')),
  cancel_reason    text check (char_length(cancel_reason) <= 500),
  created_ip_hash  text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint bookings_time_order check (ends_at > starts_at and service_end_at > starts_at and service_end_at <= ends_at),

  -- Tenant-integriteit. Zonder deze twee constraints kan een boeking met een
  -- UPDATE naar een andere shop verplaatst worden terwijl barber en dienst bij
  -- de oorspronkelijke shop blijven horen — een cross-tenant lek dat met RLS
  -- alleen niet te dichten is.
  constraint bookings_barber_same_shop
    foreign key (barber_id, shop_id) references public.barbers (id, shop_id) on delete restrict,
  constraint bookings_service_same_shop
    foreign key (service_id, shop_id) references public.services (id, shop_id) on delete restrict,

  -- ===========================================================================
  -- DE belangrijkste regel van dit hele systeem.
  -- Twee actieve boekingen bij dezelfde barber kunnen elkaar nooit overlappen.
  -- Postgres dwingt dit af met een GiST-index, dus ook wanneer twee klanten
  -- op exact hetzelfde moment op "bevestigen" drukken.
  -- ===========================================================================
  constraint bookings_no_overlap exclude using gist (
    barber_id with =,
    tstzrange(starts_at, ends_at, '[)') with &&
  ) where (status in ('pending', 'confirmed'))
);

create index if not exists bookings_shop_time_idx    on public.bookings (shop_id, starts_at desc);
create index if not exists bookings_barber_time_idx  on public.bookings (barber_id, starts_at);
create index if not exists bookings_customer_idx     on public.bookings (customer_id) where customer_id is not null;
create index if not exists bookings_email_idx        on public.bookings (customer_email, starts_at desc);
create unique index if not exists bookings_manage_token_idx on public.bookings (manage_token);
create index if not exists bookings_upcoming_idx     on public.bookings (starts_at)
  where status in ('pending', 'confirmed');

drop trigger if exists bookings_set_updated_at on public.bookings;
create trigger bookings_set_updated_at before update on public.bookings
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- notifications — outbox pattern
-- Nooit direct versturen tijdens een transactie; altijd in de wachtrij zetten en
-- door een aparte dispatcher laten verwerken. Dat maakt retries en idempotentie
-- mogelijk en houdt de boeking snel.
-- -----------------------------------------------------------------------------
create table if not exists public.notifications (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops (id) on delete cascade,
  booking_id   uuid references public.bookings (id) on delete cascade,
  channel      public.notification_channel not null,
  template     public.notification_template not null,
  recipient    text not null,
  payload      jsonb not null default '{}'::jsonb,
  send_after   timestamptz not null default now(),
  status       public.notification_status not null default 'queued',
  attempts     smallint not null default 0,
  last_error   text,
  sent_at      timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  -- Idempotentie: exact één notificatie per (boeking, template, kanaal)
  unique (booking_id, template, channel)
);

create index if not exists notifications_due_idx on public.notifications (send_after)
  where status = 'queued';

drop trigger if exists notifications_set_updated_at on public.notifications;
create trigger notifications_set_updated_at before update on public.notifications
  for each row execute function public.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- booking_attempts — rate limiting op databaseniveau
-- -----------------------------------------------------------------------------
create table if not exists public.booking_attempts (
  id         bigserial primary key,
  shop_id    uuid references public.shops (id) on delete cascade,
  identifier text not null,          -- gehashte e-mail of IP
  kind       text not null default 'create',
  created_at timestamptz not null default now()
);

create index if not exists booking_attempts_lookup_idx on public.booking_attempts (identifier, created_at desc);

-- -----------------------------------------------------------------------------
-- audit_log — wie deed wat
-- -----------------------------------------------------------------------------
create table if not exists public.audit_log (
  id          bigserial primary key,
  shop_id     uuid references public.shops (id) on delete cascade,
  actor_id    uuid references auth.users (id) on delete set null,
  actor_label text,
  action      text not null,
  entity      text not null,
  entity_id   uuid,
  diff        jsonb,
  created_at  timestamptz not null default now()
);

create index if not exists audit_log_shop_idx on public.audit_log (shop_id, created_at desc);

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
-- 20260804000200_rls_policies.sql
-- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
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

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
-- 20260804000300_availability.sql
-- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
-- =============================================================================
-- 20260804000300_availability.sql
-- Beschikbaarheidsberekening in de database
-- =============================================================================
-- Waarom in SQL en niet in JavaScript?
--  * Eén bron van waarheid. De frontend, het dashboard en de create_booking-RPC
--    gebruiken exact dezelfde logica; er kan geen drift ontstaan.
--  * De data zit al hier. Één query in plaats van drie roundtrips.
--  * DST gaat automatisch goed: werktijden staan als lokale `time` opgeslagen en
--    worden per kalenderdag met AT TIME ZONE omgezet. Op de laatste zondag van
--    oktober levert dat vanzelf het juiste absolute tijdstip op.
-- =============================================================================

-- Extensies staan op Supabase in het schema `extensions`; die moet in de
-- search_path staan voor operator- en opclass-resolutie (btree_gist!).
set search_path = public, extensions;


drop function if exists public.available_slots(uuid, uuid, date, date, uuid);
drop function if exists public.available_slots(uuid, uuid, date, date, uuid, uuid);
drop function if exists public.available_days(uuid, uuid, date, date, uuid);
drop function if exists public.available_days(uuid, uuid, date, date, uuid, uuid);

create or replace function public.available_slots(
  p_shop_id    uuid,
  p_service_id uuid,
  p_date_from  date,
  p_date_to    date,
  p_barber_id  uuid default null,
  -- Bij het verzetten van een afspraak moet het eigen blok genegeerd worden,
  -- anders blokkeert de afspraak zichzelf.
  p_exclude_booking_id uuid default null
)
returns table (
  barber_id    uuid,
  slot_start   timestamptz,
  slot_end     timestamptz,
  block_end    timestamptz,
  price_cents  integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
-- Kolomnamen winnen van gelijknamige OUT-parameters (barber_id, price_cents).
#variable_conflict use_column
declare
  v_shop    public.shops%rowtype;
  v_service public.services%rowtype;
begin
  -- Eén en dezelfde fout voor "bestaat niet" en "mag je niet zien". Zou je die
  -- twee uit elkaar houden, dan heb je een orakel waarmee een buitenstaander
  -- kan aftasten welke shop-id's bestaan en welke in preview staan.
  select * into v_shop from public.shops where id = p_shop_id;
  if not found
     or not v_shop.is_active
     or not (v_shop.is_published or public.is_shop_staff(v_shop.id)) then
    raise exception 'shop_not_available' using errcode = 'P0001';
  end if;

  select * into v_service
  from public.services
  where id = p_service_id and shop_id = p_shop_id and is_active;
  if not found then
    raise exception 'service_not_found' using errcode = 'P0002';
  end if;

  if p_date_to < p_date_from then
    raise exception 'invalid_date_range' using errcode = '22023';
  end if;
  -- Bovengrens tegen resource-uitputting: iemand die 10 jaar opvraagt
  -- kan anders de database laten zweten.
  if (p_date_to - p_date_from) > 62 then
    raise exception 'date_range_too_large' using errcode = '22023';
  end if;

  return query
  with cal as (
    select d::date as day
    from generate_series(p_date_from::timestamp, p_date_to::timestamp, interval '1 day') d
  ),
  cand as (
    select
      b.id                                                              as barber_id,
      coalesce(bs.duration_minutes, v_service.duration_minutes)::int    as dur,
      (coalesce(bs.duration_minutes, v_service.duration_minutes)
        + v_service.buffer_after_minutes)::int                          as block,
      coalesce(bs.price_cents, v_service.price_cents)::int              as price_cents
    from public.barbers b
    join public.barber_services bs
      on bs.barber_id = b.id and bs.service_id = p_service_id
    where b.shop_id = p_shop_id
      and b.is_active
      and b.accepts_online_bookings
      and (p_barber_id is null or b.id = p_barber_id)
  ),
  windows as (
    select
      c.barber_id, c.dur, c.block, c.price_cents,
      ((cal.day + wh.start_time) at time zone v_shop.timezone) as win_start,
      ((cal.day + wh.end_time)   at time zone v_shop.timezone) as win_end
    from cand c
    join public.working_hours wh on wh.barber_id = c.barber_id
    join cal on wh.weekday = extract(dow from cal.day)::smallint
  ),
  slots as (
    select
      w.barber_id,
      w.price_cents,
      gs                                       as slot_start,
      gs + make_interval(mins => w.dur)        as slot_end,
      gs + make_interval(mins => w.block)      as block_end
    from windows w
    cross join lateral generate_series(
      w.win_start,
      w.win_end - make_interval(mins => w.block),
      make_interval(mins => v_shop.slot_interval_minutes)
    ) gs
  )
  select s.barber_id, s.slot_start, s.slot_end, s.block_end, s.price_cents
  from slots s
  where
    -- minimale voorbereidingstijd
    s.slot_start >= now() + make_interval(mins => v_shop.min_lead_minutes)
    -- niet verder vooruit dan het beleid toestaat
    and s.slot_start <= now() + make_interval(days => v_shop.max_advance_days::int)
    -- geen overlap met bestaande afspraken
    and not exists (
      select 1 from public.bookings bk
      where bk.barber_id = s.barber_id
        and bk.status in ('pending', 'confirmed')
        and (p_exclude_booking_id is null or bk.id <> p_exclude_booking_id)
        and tstzrange(bk.starts_at, bk.ends_at, '[)')
            && tstzrange(s.slot_start, s.block_end, '[)')
    )
    -- geen overlap met vrije tijd van de barber
    and not exists (
      select 1 from public.time_off t
      where t.barber_id = s.barber_id
        and tstzrange(t.starts_at, t.ends_at, '[)')
            && tstzrange(s.slot_start, s.block_end, '[)')
    )
    -- geen overlap met sluitingsdagen van de shop
    and not exists (
      select 1 from public.shop_closures cl
      where cl.shop_id = p_shop_id
        and tstzrange(cl.starts_at, cl.ends_at, '[)')
            && tstzrange(s.slot_start, s.block_end, '[)')
    )
  order by s.slot_start, s.barber_id;
end;
$$;

comment on function public.available_slots is
  'Vrije tijdsloten voor een dienst binnen een shop. Geeft nooit slots terug uit niet-gepubliceerde shops aan buitenstaanders.';

-- -----------------------------------------------------------------------------
-- Compacte variant voor de kalender: welke dagen hebben überhaupt ruimte?
-- Scheelt de frontend het binnenhalen van duizenden slots.
-- -----------------------------------------------------------------------------
create or replace function public.available_days(
  p_shop_id    uuid,
  p_service_id uuid,
  p_date_from  date,
  p_date_to    date,
  p_barber_id  uuid default null,
  p_exclude_booking_id uuid default null
)
returns table (day date, slot_count integer, first_slot timestamptz)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    (s.slot_start at time zone sh.timezone)::date as day,
    count(*)::int                                 as slot_count,
    min(s.slot_start)                             as first_slot
  from public.available_slots(p_shop_id, p_service_id, p_date_from, p_date_to,
                              p_barber_id, p_exclude_booking_id) s
  cross join lateral (select timezone from public.shops where id = p_shop_id) sh
  group by 1
  order by 1;
$$;

grant execute on function public.available_slots(uuid, uuid, date, date, uuid, uuid) to anon, authenticated;
grant execute on function public.available_days(uuid, uuid, date, date, uuid, uuid)  to anon, authenticated;

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
-- 20260804000400_booking_rpc.sql
-- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
-- =============================================================================
-- 20260804000400_booking_rpc.sql
-- Boeken, annuleren en verzetten — uitsluitend via gecontroleerde RPC's
-- =============================================================================
-- Waarom geen directe INSERT vanuit de browser?
-- Omdat de client dan de prijs, de duur, de barber en het tijdstip zelf bepaalt.
-- Elke validatie in React is cosmetisch: met curl en de anon key omzeil je hem.
-- Deze functies draaien als SECURITY DEFINER en zijn het enige pad naar de
-- bookings-tabel voor niet-personeel. Prijs en duur worden serverside opnieuw
-- uit de database gehaald — nooit uit de request overgenomen.
--
-- Alle functies geven jsonb terug. Dat voorkomt naamconflicten tussen
-- OUT-parameters en kolommen (een klassieke, stille bron van PL/pgSQL-bugs)
-- en levert de frontend meteen één schoon object op.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Pseudonieme identifier voor rate limiting (nooit het e-mailadres zelf opslaan
-- in de rate-limit-tabel)
-- -----------------------------------------------------------------------------
-- Extensies staan op Supabase in het schema `extensions`; die moet in de
-- search_path staan voor operator- en opclass-resolutie (btree_gist!).
set search_path = public, extensions;


create or replace function public.hash_identifier(p_value text)
returns text
language sql
immutable
set search_path = public, extensions, pg_temp
as $$
  select case
    when coalesce(btrim(p_value), '') = '' then null
    else encode(digest(lower(btrim(p_value)) || '::bb.v1', 'sha256'), 'hex')
  end;
$$;

-- -----------------------------------------------------------------------------
-- Telefoonnummer normaliseren naar E.164-achtige vorm
-- -----------------------------------------------------------------------------
create or replace function public.normalize_phone(p_phone text, p_country char(2) default 'NL')
returns text
language plpgsql
immutable
as $$
declare
  v text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
begin
  if v = '' then return null; end if;
  if left(v, 2) = '00' then v := '+' || substr(v, 3); end if;
  if left(v, 1) <> '+' then
    v := case p_country
           when 'BE' then '+32' when 'DE' then '+49' when 'FR' then '+33'
           when 'GB' then '+44' when 'ES' then '+34' when 'CW' then '+599'
           else '+31'
         end || case when left(v, 1) = '0' then substr(v, 2) else v end;
  end if;
  return v;
end;
$$;

-- =============================================================================
-- register_booking_attempt — eerste laag rate limiting
-- =============================================================================
-- Wordt door de server aangeroepen in een eigen transactie, vóór create_booking.
-- Daardoor telt ook een mislukte poging mee: die commit staat los van de
-- rollback die een fout in create_booking veroorzaakt.
-- Geeft true terug als er geboekt mag worden, false bij een overschrijding.
-- =============================================================================
create or replace function public.register_booking_attempt(
  p_shop_id     uuid,
  p_email       text,
  p_fingerprint text default null,
  p_max_per_hour int default 8
)
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_ids text[];
  v_cnt int;
begin
  v_ids := array_remove(
    array[public.hash_identifier(p_email), public.hash_identifier(p_fingerprint)],
    null
  );
  if array_length(v_ids, 1) is null then
    return false;
  end if;

  select count(*) into v_cnt
  from public.booking_attempts ba
  where ba.identifier = any (v_ids)
    and ba.created_at > now() - interval '1 hour';

  insert into public.booking_attempts (shop_id, identifier, kind)
  select p_shop_id, x, 'create' from unnest(v_ids) x;

  return v_cnt < greatest(1, least(p_max_per_hour, 100));
end;
$$;

revoke all on function public.register_booking_attempt(uuid, text, text, int) from public, anon, authenticated;
grant execute on function public.register_booking_attempt(uuid, text, text, int) to service_role;

-- =============================================================================
-- create_booking
-- =============================================================================
drop function if exists public.create_booking(uuid, uuid, timestamptz, text, text, text, uuid, text, text);

create or replace function public.create_booking(
  p_shop_id            uuid,
  p_service_id         uuid,
  p_starts_at          timestamptz,
  p_customer_name      text,
  p_customer_email     text,
  p_customer_phone     text,
  p_barber_id          uuid  default null,   -- null = "maakt niet uit"
  p_notes              text  default null,
  p_client_fingerprint text  default null,   -- IP, aangeleverd door de server
  p_customer_id        uuid  default null    -- alleen de server zet deze, na getUser()
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_shop        public.shops%rowtype;
  v_service     public.services%rowtype;
  v_name        text := btrim(coalesce(p_customer_name, ''));
  v_email       text := lower(btrim(coalesce(p_customer_email, '')));
  v_phone       text;
  v_notes       text := nullif(btrim(coalesce(p_notes, '')), '');
  v_ident       text;
  v_fp          text := public.hash_identifier(p_client_fingerprint);
  v_attempts    int;
  v_open        int;
  v_barber      uuid;
  v_price       int;
  v_slot_end    timestamptz;
  v_block_end   timestamptz;
  v_local_day   date;
  v_id          uuid;
  v_token       uuid;
  v_barber_name text;
begin
  ---------------------------------------------------------------------------
  -- 1. Shop en dienst ophalen en valideren
  ---------------------------------------------------------------------------
  select * into v_shop from public.shops where id = p_shop_id;
  if not found or not v_shop.is_active
     or not (v_shop.is_published or public.is_shop_staff(v_shop.id)) then
    raise exception 'shop_not_available'
      using errcode = 'P0001', hint = 'Deze salon neemt op dit moment geen online boekingen aan.';
  end if;

  select * into v_service
  from public.services
  where id = p_service_id and shop_id = p_shop_id and is_active;
  if not found then
    raise exception 'service_not_found'
      using errcode = 'P0001', hint = 'Deze behandeling bestaat niet (meer).';
  end if;

  ---------------------------------------------------------------------------
  -- 2. Invoer normaliseren en valideren
  ---------------------------------------------------------------------------
  if char_length(v_name) < 2 or char_length(v_name) > 100 then
    raise exception 'invalid_name' using errcode = 'P0001', hint = 'Vul een geldige naam in.';
  end if;
  if v_email !~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then
    raise exception 'invalid_email' using errcode = 'P0001', hint = 'Vul een geldig e-mailadres in.';
  end if;

  v_phone := public.normalize_phone(p_customer_phone, v_shop.country_code);
  if v_phone is null or char_length(regexp_replace(v_phone, '\D', '', 'g')) < 8 then
    raise exception 'invalid_phone' using errcode = 'P0001', hint = 'Vul een geldig telefoonnummer in.';
  end if;

  if v_notes is not null and char_length(v_notes) > 1000 then
    v_notes := left(v_notes, 1000);
  end if;

  -- Tijdstip op hele minuten; secondes uit de request negeren.
  p_starts_at := date_trunc('minute', p_starts_at);

  ---------------------------------------------------------------------------
  -- 3. Rate limiting
  --
  --    Twee lagen, want geen van beide is op zichzelf genoeg:
  --
  --    a) booking_attempts. De registratie gebeurt óók in
  --       register_booking_attempt(), die de server in een eigen transactie
  --       aanroept. Dat is nodig omdat een exception hieronder de hele
  --       transactie terugdraait, inclusief de zojuist geschreven poging — een
  --       aanvaller die expres fouten uitlokt zou anders nooit geteld worden.
  --
  --    b) Een harde bovengrens op daadwerkelijk aangemaakte boekingen per
  --       fingerprint. Die rijen zijn wél gecommit en rollen dus niet mee
  --       terug. Dit is de rem die voorkomt dat iemand met roterende
  --       e-mailadressen een hele agenda volzet.
  ---------------------------------------------------------------------------
  v_ident := public.hash_identifier(v_email);

  select count(*) into v_attempts
  from public.booking_attempts ba
  where ba.identifier = any (array_remove(array[v_ident, v_fp], null))
    and ba.created_at > now() - interval '1 hour';

  if v_attempts > 12 then
    raise exception 'rate_limited'
      using errcode = 'P0001', hint = 'Te veel pogingen. Probeer het over een uur opnieuw of bel de salon.';
  end if;

  insert into public.booking_attempts (shop_id, identifier, kind)
  select p_shop_id, x, 'create'
  from unnest(array_remove(array[v_ident, v_fp], null)) x;

  if v_fp is not null then
    select count(*) into v_attempts
    from public.bookings b
    where b.created_ip_hash = v_fp
      and b.created_at > now() - interval '1 hour';

    if v_attempts >= 6 then
      raise exception 'rate_limited'
        using errcode = 'P0001', hint = 'Te veel boekingen vanaf dit adres. Bel de salon even.';
    end if;
  end if;

  ---------------------------------------------------------------------------
  -- 4. Maximaal aantal openstaande afspraken per klant
  ---------------------------------------------------------------------------
  select count(*) into v_open
  from public.bookings b
  where b.shop_id = p_shop_id
    and b.customer_email = v_email
    and b.status in ('pending', 'confirmed')
    and b.starts_at > now();

  if v_open >= v_shop.max_open_per_customer then
    raise exception 'too_many_open_bookings'
      using errcode = 'P0001',
            hint = format('Je hebt al %s openstaande afspraken bij deze salon.', v_open);
  end if;

  ---------------------------------------------------------------------------
  -- 5. Slot valideren tegen exact dezelfde bron als de UI gebruikt
  ---------------------------------------------------------------------------
  v_local_day := (p_starts_at at time zone v_shop.timezone)::date;

  select s.barber_id, s.price_cents, s.slot_end, s.block_end
    into v_barber, v_price, v_slot_end, v_block_end
  from public.available_slots(p_shop_id, p_service_id, v_local_day, v_local_day, p_barber_id) s
  where s.slot_start = p_starts_at
  order by
    -- Eerlijke verdeling bij "maakt niet uit": de barber met de minste
    -- afspraken die dag krijgt de klant.
    (select count(*) from public.bookings b2
      where b2.barber_id = s.barber_id
        and b2.status in ('pending', 'confirmed')
        and (b2.starts_at at time zone v_shop.timezone)::date = v_local_day) asc,
    s.barber_id asc
  limit 1;

  if v_barber is null then
    raise exception 'slot_unavailable'
      using errcode = 'P0001', hint = 'Dit tijdstip is niet (meer) beschikbaar. Kies een ander moment.';
  end if;

  ---------------------------------------------------------------------------
  -- 6. Wegschrijven. De EXCLUDE-constraint is de laatste verdedigingslinie:
  --    tussen stap 5 en 6 kan een concurrent hetzelfde slot pakken.
  ---------------------------------------------------------------------------
  begin
    insert into public.bookings (
      shop_id, barber_id, service_id, customer_id,
      customer_name, customer_email, customer_phone,
      starts_at, ends_at, service_end_at,
      status, price_cents, currency, notes, source, created_ip_hash
    )
    values (
      p_shop_id, v_barber, p_service_id, coalesce(p_customer_id, auth.uid()),
      v_name, v_email, v_phone,
      p_starts_at, v_block_end, v_slot_end,
      'confirmed', v_price, v_shop.currency, v_notes, 'web', v_fp
    )
    returning bookings.id, bookings.manage_token into v_id, v_token;
  exception
    when exclusion_violation then
      raise exception 'slot_taken'
        using errcode = 'P0001', hint = 'Iemand was je net voor. Kies een ander tijdstip.';
  end;

  select b.display_name into v_barber_name from public.barbers b where b.id = v_barber;

  insert into public.audit_log (shop_id, actor_id, actor_label, action, entity, entity_id)
  values (p_shop_id, coalesce(p_customer_id, auth.uid()), v_email, 'booking.created', 'bookings', v_id);

  return jsonb_build_object(
    'booking_id',   v_id,
    'manage_token', v_token,
    'barber_id',    v_barber,
    'barber_name',  v_barber_name,
    'service_name', v_service.name,
    'starts_at',    p_starts_at,
    'ends_at',      v_slot_end,
    'price_cents',  v_price,
    'currency',     v_shop.currency,
    'shop_slug',    v_shop.slug,
    'timezone',     v_shop.timezone
  );
end;
$$;

comment on function public.create_booking is
  'Enige toegestane manier voor bezoekers om te boeken. Valideert slot, prijs en limieten serverside.';

-- =============================================================================
-- get_booking_by_token — gast bekijkt zijn afspraak
-- =============================================================================
create or replace function public.get_booking_by_token(p_token uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'id',              b.id,
    'status',          b.status,
    'starts_at',       b.starts_at,
    'service_end_at',  b.service_end_at,
    'service_name',    sv.name,
    'barber_name',     br.display_name,
    'shop_name',       sh.name,
    'shop_slug',       sh.slug,
    'shop_city',       sh.city,
    'shop_phone',      sh.phone,
    'shop_timezone',   sh.timezone,
    'shop_address',    concat_ws(', ',
                          nullif(btrim(concat_ws(' ', sh.street, sh.house_number)), ''),
                          nullif(btrim(concat_ws(' ', sh.postal_code, sh.city)), '')),
    'customer_name',   b.customer_name,
    'customer_email',  b.customer_email,
    'price_cents',     b.price_cents,
    'currency',        b.currency,
    'notes',           b.notes,
    'cancel_deadline', b.starts_at - make_interval(hours => sh.cancel_cutoff_hours::int),
    'can_modify',      (b.status in ('pending', 'confirmed')
                        and b.starts_at - make_interval(hours => sh.cancel_cutoff_hours::int) > now())
  )
  from public.bookings b
  join public.shops    sh on sh.id = b.shop_id
  join public.barbers  br on br.id = b.barber_id
  join public.services sv on sv.id = b.service_id
  where b.manage_token = p_token
  limit 1;
$$;

-- =============================================================================
-- cancel_booking_by_token
-- =============================================================================
create or replace function public.cancel_booking_by_token(
  p_token  uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking public.bookings%rowtype;
  v_cutoff  smallint;
begin
  select b.* into v_booking from public.bookings b where b.manage_token = p_token;
  if not found then
    -- Geen onderscheid maken tussen "bestaat niet" en "mag niet": zo kan
    -- niemand met brute force tokens aftasten.
    raise exception 'booking_not_found'
      using errcode = 'P0001', hint = 'Deze afspraak bestaat niet of de link is verlopen.';
  end if;

  if v_booking.status not in ('pending', 'confirmed') then
    raise exception 'booking_not_cancellable'
      using errcode = 'P0001', hint = 'Deze afspraak is al afgerond of geannuleerd.';
  end if;

  select sh.cancel_cutoff_hours into v_cutoff from public.shops sh where sh.id = v_booking.shop_id;

  if v_booking.starts_at - make_interval(hours => v_cutoff::int) <= now() then
    raise exception 'cancel_window_closed'
      using errcode = 'P0001',
            hint = format('Online annuleren kan tot %s uur van tevoren. Bel de salon.', v_cutoff);
  end if;

  update public.bookings b
     set status        = 'cancelled',
         cancelled_at  = now(),
         cancelled_by  = 'customer',
         cancel_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 500)
   where b.id = v_booking.id;

  insert into public.audit_log (shop_id, actor_label, action, entity, entity_id)
  values (v_booking.shop_id, v_booking.customer_email, 'booking.cancelled', 'bookings', v_booking.id);

  return jsonb_build_object('ok', true, 'booking_id', v_booking.id);
end;
$$;

-- =============================================================================
-- reschedule_booking_by_token
-- =============================================================================
create or replace function public.reschedule_booking_by_token(
  p_token     uuid,
  p_starts_at timestamptz,
  p_barber_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_booking   public.bookings%rowtype;
  v_shop      public.shops%rowtype;
  v_local_day date;
  v_barber    uuid;
  v_price     int;
  v_slot_end  timestamptz;
  v_block_end timestamptz;
begin
  select b.* into v_booking from public.bookings b where b.manage_token = p_token;
  if not found or v_booking.status not in ('pending', 'confirmed') then
    raise exception 'booking_not_found'
      using errcode = 'P0001', hint = 'Deze afspraak kan niet meer verzet worden.';
  end if;

  select * into v_shop from public.shops sh where sh.id = v_booking.shop_id;

  if v_booking.starts_at - make_interval(hours => v_shop.cancel_cutoff_hours::int) <= now() then
    raise exception 'reschedule_window_closed'
      using errcode = 'P0001', hint = 'Verzetten kan niet meer online. Bel de salon.';
  end if;

  p_starts_at := date_trunc('minute', p_starts_at);
  v_local_day := (p_starts_at at time zone v_shop.timezone)::date;

  -- Het eigen blok uitsluiten in plaats van de afspraak tijdelijk te
  -- annuleren. Die truc leek onschuldig, maar liet de statustrigger vuren:
  -- de klant kreeg een annuleringsmail en zijn herinneringen werden
  -- ingetrokken. Een parameter is simpeler én correcter.
  select s.barber_id, s.price_cents, s.slot_end, s.block_end
    into v_barber, v_price, v_slot_end, v_block_end
  from public.available_slots(v_booking.shop_id, v_booking.service_id, v_local_day, v_local_day,
                              coalesce(p_barber_id, v_booking.barber_id), v_booking.id) s
  where s.slot_start = p_starts_at
  limit 1;

  if v_barber is null then
    raise exception 'slot_unavailable'
      using errcode = 'P0001', hint = 'Dit tijdstip is niet (meer) beschikbaar.';
  end if;

  begin
    update public.bookings b
       set barber_id      = v_barber,
           starts_at      = p_starts_at,
           ends_at        = v_block_end,
           service_end_at = v_slot_end,
           -- Prijs opnieuw vastleggen: barbers kunnen een afwijkend tarief
           -- hebben. Zonder deze regel kon je bij de goedkoopste boeken en
           -- daarna gratis naar de duurste verzetten.
           price_cents    = v_price
     where b.id = v_booking.id;
  exception
    when exclusion_violation then
      raise exception 'slot_taken'
        using errcode = 'P0001', hint = 'Iemand was je net voor. Kies een ander tijdstip.';
  end;

  -- Herinneringen die nog in de wachtrij staan opnieuw inplannen.
  update public.notifications n
     set send_after = case n.template
                        when 'booking_reminder_24h' then p_starts_at - interval '24 hours'
                        when 'booking_reminder_2h'  then p_starts_at - interval '2 hours'
                        else n.send_after end
   where n.booking_id = v_booking.id and n.status = 'queued';

  insert into public.audit_log (shop_id, actor_label, action, entity, entity_id, diff)
  values (v_booking.shop_id, v_booking.customer_email, 'booking.rescheduled', 'bookings', v_booking.id,
          jsonb_build_object('from', v_booking.starts_at, 'to', p_starts_at));

  return jsonb_build_object('ok', true, 'booking_id', v_booking.id, 'starts_at', p_starts_at);
end;
$$;

-- =============================================================================
-- Rechten
-- =============================================================================
-- create_booking is NIET meer aan anon gegeven. Anders roept een aanvaller de
-- RPC rechtstreeks aan met de publieke key en omzeilt hij in één klap de
-- honeypot, het echte IP-adres en register_booking_attempt(). Alle boekingen
-- lopen nu verplicht via POST /api/book, waar de server het IP kent.
revoke all on function public.create_booking(uuid, uuid, timestamptz, text, text, text, uuid, text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.create_booking(uuid, uuid, timestamptz, text, text, text, uuid, text, text, uuid)
  to service_role;

revoke all on function public.get_booking_by_token(uuid) from public, anon, authenticated;
grant execute on function public.get_booking_by_token(uuid) to anon, authenticated;

revoke all on function public.cancel_booking_by_token(uuid, text) from public, anon, authenticated;
grant execute on function public.cancel_booking_by_token(uuid, text) to anon, authenticated;

revoke all on function public.reschedule_booking_by_token(uuid, timestamptz, uuid) from public, anon, authenticated;
grant execute on function public.reschedule_booking_by_token(uuid, timestamptz, uuid) to anon, authenticated;

-- `revoke ... from anon, authenticated` alleen is niet genoeg: die rollen erven
-- het impliciete EXECUTE-recht van PUBLIC. Dat moet er expliciet af.
revoke all on function public.hash_identifier(text) from public, anon, authenticated;
revoke all on function public.normalize_phone(text, char) from public, anon, authenticated;
grant execute on function public.normalize_phone(text, char) to service_role;

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
-- 20260804000500_notifications.sql
-- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
-- =============================================================================
-- 20260804000500_notifications.sql
-- Notificaties volgens het outbox-pattern
-- =============================================================================
-- Nooit een e-mail of SMS versturen midden in een databasetransactie. Als de
-- mailprovider traag is wacht de klant; als hij faalt na een commit is de mail
-- voorgoed weg. In plaats daarvan schrijft een trigger een rij in de wachtrij,
-- en pikt een aparte dispatcher (Edge Function op een cron) die op. Retries,
-- idempotentie en observability krijg je er gratis bij.
-- =============================================================================

-- Extensies staan op Supabase in het schema `extensions`; die moet in de
-- search_path staan voor operator- en opclass-resolutie (btree_gist!).
set search_path = public, extensions;


alter table public.shops
  add column if not exists notify_email_enabled boolean not null default true,
  add column if not exists notify_sms_enabled   boolean not null default false,
  add column if not exists reminder_hours       smallint[] not null default '{24,2}',
  add column if not exists staff_notify_email   text,
  add column if not exists reply_to_email       text;

-- -----------------------------------------------------------------------------
-- Wachtrij vullen bij een nieuwe boeking
-- -----------------------------------------------------------------------------
create or replace function public.tg_booking_queue_notifications()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_shop public.shops%rowtype;
  v_hour smallint;
  v_tmpl public.notification_template;
begin
  select * into v_shop from public.shops s where s.id = new.shop_id;
  if not found then return new; end if;

  if new.status not in ('pending', 'confirmed') then
    return new;
  end if;

  -- Bevestiging naar de klant
  if v_shop.notify_email_enabled then
    insert into public.notifications (shop_id, booking_id, channel, template, recipient, send_after)
    values (new.shop_id, new.id, 'email', 'booking_confirmation', new.customer_email, now())
    on conflict (booking_id, template, channel) do nothing;
  end if;

  if v_shop.notify_sms_enabled then
    insert into public.notifications (shop_id, booking_id, channel, template, recipient, send_after)
    values (new.shop_id, new.id, 'sms', 'booking_confirmation', new.customer_phone, now())
    on conflict (booking_id, template, channel) do nothing;
  end if;

  -- Interne melding naar de salon
  if v_shop.staff_notify_email is not null then
    insert into public.notifications (shop_id, booking_id, channel, template, recipient, send_after)
    values (new.shop_id, new.id, 'email', 'staff_new_booking', v_shop.staff_notify_email, now())
    on conflict (booking_id, template, channel) do nothing;
  end if;

  -- Herinneringen. Alleen inplannen als het moment nog in de toekomst ligt,
  -- anders staat er meteen een achterstallige rij in de wachtrij.
  foreach v_hour in array v_shop.reminder_hours loop
    v_tmpl := case v_hour
                when 24 then 'booking_reminder_24h'::public.notification_template
                when 2  then 'booking_reminder_2h'::public.notification_template
                else null end;
    if v_tmpl is null then continue; end if;

    if new.starts_at - make_interval(hours => v_hour::int) > now() then
      if v_shop.notify_email_enabled then
        insert into public.notifications (shop_id, booking_id, channel, template, recipient, send_after)
        values (new.shop_id, new.id, 'email', v_tmpl, new.customer_email,
                new.starts_at - make_interval(hours => v_hour::int))
        on conflict (booking_id, template, channel) do nothing;
      end if;
      if v_shop.notify_sms_enabled and v_hour = 2 then
        insert into public.notifications (shop_id, booking_id, channel, template, recipient, send_after)
        values (new.shop_id, new.id, 'sms', v_tmpl, new.customer_phone,
                new.starts_at - make_interval(hours => v_hour::int))
        on conflict (booking_id, template, channel) do nothing;
      end if;
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists booking_queue_notifications on public.bookings;
create trigger booking_queue_notifications
  after insert on public.bookings
  for each row execute function public.tg_booking_queue_notifications();

-- -----------------------------------------------------------------------------
-- Statuswijziging: annulering melden en openstaande herinneringen intrekken
-- -----------------------------------------------------------------------------
create or replace function public.tg_booking_status_notifications()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_shop public.shops%rowtype;
begin
  if new.status is not distinct from old.status then
    return new;
  end if;

  select * into v_shop from public.shops s where s.id = new.shop_id;

  if new.status in ('cancelled', 'no_show') then
    -- Herinneringen die nog niet verstuurd zijn hebben geen zin meer.
    update public.notifications n
       set status = 'cancelled'
     where n.booking_id = new.id
       and n.status = 'queued'
       and n.template in ('booking_reminder_24h', 'booking_reminder_2h');

    if new.status = 'cancelled' and v_shop.notify_email_enabled then
      insert into public.notifications (shop_id, booking_id, channel, template, recipient, send_after)
      values (new.shop_id, new.id, 'email', 'booking_cancelled', new.customer_email, now())
      on conflict (booking_id, template, channel) do nothing;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists booking_status_notifications on public.bookings;
create trigger booking_status_notifications
  after update of status on public.bookings
  for each row execute function public.tg_booking_status_notifications();

-- -----------------------------------------------------------------------------
-- Dispatcher-API: batch claimen met FOR UPDATE SKIP LOCKED zodat meerdere
-- workers elkaar niet in de weg zitten.
-- -----------------------------------------------------------------------------
create or replace function public.claim_due_notifications(p_limit int default 50)
returns setof jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  return query
  with due as (
    select n.id
    from public.notifications n
    where n.status = 'queued'
      and n.send_after <= now()
      and n.attempts < 5
    order by n.send_after
    for update skip locked
    limit greatest(1, least(p_limit, 200))
  ),
  claimed as (
    update public.notifications n
       set status = 'sending', attempts = n.attempts + 1
      from due
     where n.id = due.id
     returning n.*
  )
  select jsonb_build_object(
    'id',            c.id,
    'channel',       c.channel,
    'template',      c.template,
    'recipient',     c.recipient,
    'attempts',      c.attempts,
    'shop', jsonb_build_object(
      'name', sh.name, 'slug', sh.slug, 'phone', sh.phone, 'timezone', sh.timezone,
      'address', concat_ws(', ',
        nullif(btrim(concat_ws(' ', sh.street, sh.house_number)), ''),
        nullif(btrim(concat_ws(' ', sh.postal_code, sh.city)), '')),
      'reply_to', sh.reply_to_email, 'logo_url', sh.logo_url),
    'booking', jsonb_build_object(
      'id', b.id, 'starts_at', b.starts_at, 'service_end_at', b.service_end_at,
      'status', b.status, 'price_cents', b.price_cents, 'currency', b.currency,
      'customer_name', b.customer_name, 'customer_email', b.customer_email,
      'customer_phone', b.customer_phone, 'notes', b.notes,
      'manage_token', b.manage_token,
      'service_name', sv.name, 'barber_name', br.display_name)
  )
  from claimed c
  join public.bookings b  on b.id  = c.booking_id
  join public.shops    sh on sh.id = c.shop_id
  join public.barbers  br on br.id = b.barber_id
  join public.services sv on sv.id = b.service_id;
end;
$$;

create or replace function public.mark_notification_sent(p_id uuid)
returns void
language sql volatile security definer set search_path = public, pg_temp
as $$
  update public.notifications set status = 'sent', sent_at = now(), last_error = null where id = p_id;
$$;

create or replace function public.mark_notification_failed(p_id uuid, p_error text)
returns void
language sql volatile security definer set search_path = public, pg_temp
as $$
  update public.notifications
     set status     = case when attempts >= 5 then 'failed'::public.notification_status
                           else 'queued'::public.notification_status end,
         -- exponentiële backoff: 1, 4, 9, 16, 25 minuten
         send_after = now() + make_interval(mins => (attempts * attempts)),
         last_error = left(coalesce(p_error, 'unknown'), 1000)
   where id = p_id;
$$;

-- Alleen de dispatcher (service_role) mag hierbij.
revoke all on function public.claim_due_notifications(int)      from public, anon, authenticated;
revoke all on function public.mark_notification_sent(uuid)      from public, anon, authenticated;
revoke all on function public.mark_notification_failed(uuid, text) from public, anon, authenticated;
grant execute on function public.claim_due_notifications(int)      to service_role;
grant execute on function public.mark_notification_sent(uuid)      to service_role;
grant execute on function public.mark_notification_failed(uuid, text) to service_role;

-- -----------------------------------------------------------------------------
-- Onderhoud: afgelopen afspraken afronden en oude rate-limit-rijen opruimen
-- -----------------------------------------------------------------------------
create or replace function public.run_maintenance()
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp
as $$
declare
  v_completed int;
  v_pruned    int;
begin
  update public.bookings
     set status = 'completed'
   where status = 'confirmed'
     and ends_at < now() - interval '2 hours';
  get diagnostics v_completed = row_count;

  delete from public.booking_attempts where created_at < now() - interval '7 days';
  get diagnostics v_pruned = row_count;

  delete from public.notifications
   where status in ('sent', 'cancelled') and created_at < now() - interval '90 days';

  return jsonb_build_object('completed', v_completed, 'attempts_pruned', v_pruned);
end;
$$;

revoke all on function public.run_maintenance() from public, anon, authenticated;
grant execute on function public.run_maintenance() to service_role;

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
-- 20260804000600_seed_demo.sql
-- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
-- =============================================================================
-- 20260804000600_seed_demo.sql
-- Demodata — veilig om over te slaan in productie
-- =============================================================================
-- Vaste UUID's zodat de seed idempotent is en je 'm zonder gedoe opnieuw kunt
-- draaien. Verwijder dit bestand voordat je live gaat, of draai:
--   delete from public.shops where id = '11111111-1111-4111-8111-111111111111';
-- =============================================================================

-- Extensies staan op Supabase in het schema `extensions`; die moet in de
-- search_path staan voor operator- en opclass-resolutie (btree_gist!).
set search_path = public, extensions;


do $$
declare
  v_shop uuid := '11111111-1111-4111-8111-111111111111';
  v_b1   uuid := '22222222-2222-4222-8222-222222222221';
  v_b2   uuid := '22222222-2222-4222-8222-222222222222';
  v_b3   uuid := '22222222-2222-4222-8222-222222222223';
  v_s1   uuid := '33333333-3333-4333-8333-333333333331';
  v_s2   uuid := '33333333-3333-4333-8333-333333333332';
  v_s3   uuid := '33333333-3333-4333-8333-333333333333';
  v_s4   uuid := '33333333-3333-4333-8333-333333333334';
  v_s5   uuid := '33333333-3333-4333-8333-333333333335';
  b      uuid;
begin
  insert into public.shops (
    id, slug, name, tagline, description,
    phone, email, street, house_number, postal_code, city, country_code,
    latitude, longitude, timezone, currency,
    slot_interval_minutes, min_lead_minutes, max_advance_days, cancel_cutoff_hours,
    is_active, is_published, staff_notify_email
  ) values (
    v_shop, 'junique-fades', 'Junique Fades',
    'Precisiekapsels in hartje Amsterdam',
    'Junique Fades is een moderne barbershop gespecialiseerd in skin fades, baardsculptuur en klassieke herenkapsels. Onze barbers werken uitsluitend op afspraak zodat je nooit hoeft te wachten.',
    '+31201234567', 'hello@juniquefades.example',
    'Ferdinand Bolstraat', '42', '1072 LK', 'Amsterdam', 'NL',
    52.354200, 4.891400, 'Europe/Amsterdam', 'EUR',
    15, 60, 60, 12,
    true, true, 'hello@juniquefades.example'
  ) on conflict (id) do update set
      name = excluded.name, tagline = excluded.tagline, is_published = true;

  insert into public.barbers (id, shop_id, slug, display_name, bio, sort_order) values
    (v_b1, v_shop, 'marley', 'Marley',  'Fade-specialist. Tien jaar ervaring, oog voor symmetrie.', 1),
    (v_b2, v_shop, 'sefa',   'Sefa',    'Baard- en scheerwerk met warme handdoek en scheermes.',     2),
    (v_b3, v_shop, 'noah',   'Noah',    'Klassieke coupes, schaartechniek en kinderkapsels.',        3)
  on conflict (id) do update set display_name = excluded.display_name, bio = excluded.bio;

  insert into public.services (id, shop_id, slug, name, description, category, duration_minutes, buffer_after_minutes, price_cents, sort_order) values
    (v_s1, v_shop, 'skin-fade',       'Skin Fade',            'Strakke fade tot op de huid, inclusief styling.',        'Knippen', 45, 5, 3500, 1),
    (v_s2, v_shop, 'knippen-baard',   'Knippen + Baard',      'Volledige behandeling: kapsel en baard in lijn.',        'Combi',   60, 5, 4750, 2),
    (v_s3, v_shop, 'baard-trim',      'Baard Trim',           'Contouren, trimmen en verzorgen met olie.',              'Baard',   30, 0, 2000, 3),
    (v_s4, v_shop, 'kids-cut',        'Kids Cut (t/m 12 jr)', 'Rustig en snel, met een spiegel op ooghoogte.',          'Knippen', 30, 5, 2250, 4),
    (v_s5, v_shop, 'hot-towel-shave', 'Hot Towel Shave',      'Klassiek scheren met mes, warme handdoek en aftershave.','Scheren', 40, 5, 3250, 5)
  on conflict (id) do update set name = excluded.name, price_cents = excluded.price_cents;

  -- Wie doet wat
  insert into public.barber_services (barber_id, service_id) values
    (v_b1, v_s1), (v_b1, v_s2), (v_b1, v_s3),
    (v_b2, v_s2), (v_b2, v_s3), (v_b2, v_s5),
    (v_b3, v_s1), (v_b3, v_s4), (v_b3, v_s2)
  on conflict do nothing;

  -- Marley rekent iets meer voor een skin fade
  update public.barber_services set price_cents = 4000
   where barber_id = v_b1 and service_id = v_s1;

  -- Werktijden. 1 = maandag ... 6 = zaterdag, 0 = zondag.
  delete from public.working_hours where barber_id in (v_b1, v_b2, v_b3);

  foreach b in array array[v_b1, v_b2, v_b3] loop
    -- dinsdag t/m vrijdag, met lunchpauze
    insert into public.working_hours (barber_id, weekday, start_time, end_time)
    select b, d, t.s, t.e
    from generate_series(2, 5) d
    cross join (values ('09:30'::time, '13:00'::time), ('13:45'::time, '18:30'::time)) as t(s, e);

    -- zaterdag doorlopend
    insert into public.working_hours (barber_id, weekday, start_time, end_time)
    values (b, 6, '09:00', '17:00');
  end loop;

  -- Marley werkt ook maandagmiddag
  insert into public.working_hours (barber_id, weekday, start_time, end_time)
  values (v_b1, 1, '13:00', '19:00');
end $$;

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
-- 20260804000700_roles_storage.sql
-- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
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

-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
-- 20260804000800_admin_only_shops.sql
-- <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
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
