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
