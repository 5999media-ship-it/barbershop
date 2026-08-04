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
