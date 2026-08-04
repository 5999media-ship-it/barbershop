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
