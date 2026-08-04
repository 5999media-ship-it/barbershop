-- =============================================================================
-- 01_smoke.sql — functionele en beveiligingstests
-- Draaien met:  psql -d bbtest -v ON_ERROR_STOP=1 -f supabase/tests/01_smoke.sql
-- =============================================================================
\set QUIET on
\pset pager off

do $$
declare
  v_shop  uuid := '11111111-1111-4111-8111-111111111111';
  v_svc   uuid := '33333333-3333-4333-8333-333333333331'; -- Skin Fade
  v_slot  timestamptz;
  v_bar   uuid;
  v_res   jsonb;
  v_token uuid;
  v_cnt   int;
  v_ok    boolean;
begin
  ---------------------------------------------------------------------------
  raise notice '--- TEST 1: beschikbaarheid wordt berekend';
  select s.slot_start, s.barber_id into v_slot, v_bar
  from public.available_slots(v_shop, v_svc, current_date, current_date + 14) s
  order by s.slot_start limit 1;

  if v_slot is null then
    raise exception 'FAAL: geen enkel slot gevonden in 14 dagen';
  end if;
  raise notice '    OK — eerste vrije slot: % (barber %)', v_slot, v_bar;

  ---------------------------------------------------------------------------
  raise notice '--- TEST 2: boeking aanmaken via RPC';
  v_res := public.create_booking(
    v_shop, v_svc, v_slot,
    'Ehrlich van Uytrecht', 'Ehrlich@Example.COM', '06 12345678',
    null, 'Graag kort aan de zijkanten.', '203.0.113.9'
  );
  v_token := (v_res ->> 'manage_token')::uuid;
  if v_token is null then raise exception 'FAAL: geen manage_token terug'; end if;
  raise notice '    OK — geboekt bij % voor % (% cent)',
    v_res ->> 'barber_name', v_res ->> 'starts_at', v_res ->> 'price_cents';

  ---------------------------------------------------------------------------
  raise notice '--- TEST 3: e-mail is genormaliseerd naar lowercase';
  select count(*) into v_cnt from public.bookings
   where customer_email = 'ehrlich@example.com';
  if v_cnt <> 1 then raise exception 'FAAL: e-mail niet genormaliseerd'; end if;
  raise notice '    OK';

  ---------------------------------------------------------------------------
  raise notice '--- TEST 4: telefoonnummer genormaliseerd naar E.164';
  select count(*) into v_cnt from public.bookings where customer_phone = '+31612345678';
  if v_cnt <> 1 then
    raise exception 'FAAL: telefoon niet genormaliseerd (%)',
      (select customer_phone from public.bookings limit 1);
  end if;
  raise notice '    OK';

  ---------------------------------------------------------------------------
  raise notice '--- TEST 5: hetzelfde slot bij dezelfde barber is weg';
  begin
    perform public.create_booking(v_shop, v_svc, v_slot,
      'Tweede Klant', 'tweede@example.com', '0687654321', v_bar, null, '203.0.113.10');
    raise exception 'FAAL: dubbele boeking werd geaccepteerd!';
  exception when sqlstate 'P0001' then
    if sqlerrm not in ('slot_unavailable', 'slot_taken') then raise; end if;
    raise notice '    OK — geweigerd met: %', sqlerrm;
  end;

  ---------------------------------------------------------------------------
  raise notice '--- TEST 6: EXCLUDE-constraint blokkeert ook een directe INSERT';
  begin
    insert into public.bookings (shop_id, barber_id, service_id, customer_name,
      customer_email, customer_phone, starts_at, ends_at, service_end_at, price_cents)
    values (v_shop, v_bar, v_svc, 'Sluiproute', 'hack@example.com', '+31600000000',
            v_slot + interval '10 minutes', v_slot + interval '55 minutes',
            v_slot + interval '55 minutes', 1);
    raise exception 'FAAL: overlappende INSERT werd geaccepteerd!';
  exception when exclusion_violation then
    raise notice '    OK — Postgres weigerde de overlap';
  end;

  ---------------------------------------------------------------------------
  raise notice '--- TEST 7: het slot verdwijnt uit de beschikbaarheid';
  select count(*) into v_cnt
  from public.available_slots(v_shop, v_svc, (v_slot at time zone 'Europe/Amsterdam')::date,
                              (v_slot at time zone 'Europe/Amsterdam')::date, v_bar) s
  where s.slot_start = v_slot;
  if v_cnt <> 0 then raise exception 'FAAL: geboekt slot wordt nog aangeboden'; end if;
  raise notice '    OK';

  ---------------------------------------------------------------------------
  raise notice '--- TEST 8: prijs komt uit de database, niet uit de request';
  select price_cents into v_cnt from public.bookings where manage_token = v_token;
  if v_cnt <> 4000 then  -- Marley heeft een afwijkende prijs; anders 3500
    if v_cnt <> 3500 then raise exception 'FAAL: onverwachte prijs %', v_cnt; end if;
  end if;
  raise notice '    OK — % cent', v_cnt;

  ---------------------------------------------------------------------------
  raise notice '--- TEST 9: notificaties staan in de wachtrij';
  select count(*) into v_cnt from public.notifications n
   where n.booking_id = (v_res ->> 'booking_id')::uuid;
  if v_cnt < 2 then raise exception 'FAAL: te weinig notificaties (%)', v_cnt; end if;
  raise notice '    OK — % notificaties gequeued', v_cnt;

  ---------------------------------------------------------------------------
  raise notice '--- TEST 10: afspraak ophalen met token';
  v_res := public.get_booking_by_token(v_token);
  if v_res ->> 'shop_name' is null then raise exception 'FAAL: token-lookup leeg'; end if;
  raise notice '    OK — % bij % op %',
    v_res ->> 'service_name', v_res ->> 'barber_name', v_res ->> 'starts_at';

  ---------------------------------------------------------------------------
  raise notice '--- TEST 11: onbekend token geeft nette fout, geen datalek';
  begin
    perform public.cancel_booking_by_token('00000000-0000-4000-8000-000000000000');
    raise exception 'FAAL: onbekend token werd geaccepteerd';
  exception when sqlstate 'P0001' then
    raise notice '    OK — %', sqlerrm;
  end;

  ---------------------------------------------------------------------------
  raise notice '--- TEST 12: rate limiting slaat toe';
  declare v_blocked int := 0;
  begin
    for i in 1..12 loop
      if not public.register_booking_attempt(v_shop, 'spam@example.com', '198.51.100.7', 8) then
        v_blocked := i;
        exit;
      end if;
    end loop;
    if v_blocked = 0 then raise exception 'FAAL: rate limit sloeg nooit aan'; end if;
    raise notice '    OK — geblokkeerd bij poging %', v_blocked;
  end;

  ---------------------------------------------------------------------------
  raise notice '--- TEST 13: annuleren met token';
  v_res := public.cancel_booking_by_token(v_token, 'Toch verhinderd');
  select status = 'cancelled' into v_ok from public.bookings where manage_token = v_token;
  if not v_ok then raise exception 'FAAL: status niet gewijzigd'; end if;
  raise notice '    OK';

  ---------------------------------------------------------------------------
  raise notice '--- TEST 14: herinneringen zijn ingetrokken na annulering';
  select count(*) into v_cnt from public.notifications n
   where n.booking_id = (public.get_booking_by_token(v_token) ->> 'id')::uuid
     and n.template in ('booking_reminder_24h', 'booking_reminder_2h')
     and n.status = 'queued';
  if v_cnt <> 0 then raise exception 'FAAL: % herinnering(en) nog actief', v_cnt; end if;
  raise notice '    OK';

  ---------------------------------------------------------------------------
  raise notice '--- TEST 15: het slot is weer vrij na annulering';
  select count(*) into v_cnt
  from public.available_slots(v_shop, v_svc, (v_slot at time zone 'Europe/Amsterdam')::date,
                              (v_slot at time zone 'Europe/Amsterdam')::date, v_bar) s
  where s.slot_start = v_slot;
  if v_cnt <> 1 then raise exception 'FAAL: slot niet vrijgegeven'; end if;
  raise notice '    OK';

  raise notice '';
  raise notice '*** ALLE FUNCTIONELE TESTS GESLAAGD ***';
end $$;

-- =============================================================================
-- Beveiligingstests met echte rolwissels
-- =============================================================================
\echo '--- TEST 16: anon mag geen boekingen lezen'
set role anon;
do $$
declare v_cnt int;
begin
  select count(*) into v_cnt from public.bookings;
  if v_cnt > 0 then
    raise exception 'FAAL: anon ziet % boekingen!', v_cnt;
  end if;
  raise notice '    OK — anon ziet 0 rijen';
exception when insufficient_privilege then
  raise notice '    OK — anon krijgt permission denied';
end $$;
reset role;

\echo '--- TEST 17: anon mag niet rechtstreeks in bookings schrijven'
set role anon;
do $$
begin
  insert into public.bookings (shop_id, barber_id, service_id, customer_name,
    customer_email, customer_phone, starts_at, ends_at, service_end_at, price_cents)
  values ('11111111-1111-4111-8111-111111111111',
          '22222222-2222-4222-8222-222222222221',
          '33333333-3333-4333-8333-333333333331',
          'Gratis Knip', 'gratis@example.com', '+31600000000',
          now() + interval '30 days', now() + interval '30 days 45 minutes',
          now() + interval '30 days 45 minutes', 0);
  raise exception 'FAAL: anon kon een boeking wegschrijven!';
exception
  when insufficient_privilege then raise notice '    OK — permission denied';
  when others then
    if sqlstate = '42501' then raise notice '    OK — RLS blokkeerde de insert';
    else raise; end if;
end $$;
reset role;

\echo '--- TEST 18: anon ziet publieke shopdata wel'
set role anon;
do $$
declare v_cnt int;
begin
  select count(*) into v_cnt from public.services;
  if v_cnt < 1 then raise exception 'FAAL: anon ziet geen diensten'; end if;
  raise notice '    OK — anon ziet % diensten', v_cnt;
end $$;
reset role;

\echo '--- TEST 19: anon ziet geen vrije dagen / afwezigheid van personeel'
set role anon;
do $$
declare v_cnt int;
begin
  begin
    select count(*) into v_cnt from public.time_off;
    if v_cnt > 0 then raise exception 'FAAL: anon ziet time_off'; end if;
    raise notice '    OK — 0 rijen';
  exception when insufficient_privilege then
    raise notice '    OK — permission denied';
  end;
end $$;
reset role;

\echo '--- TEST 20: anon kan de rate-limit-tabel niet uitlezen'
set role anon;
do $$
declare v_cnt int;
begin
  select count(*) into v_cnt from public.booking_attempts;
  raise exception 'FAAL: anon las booking_attempts (% rijen)', v_cnt;
exception
  when insufficient_privilege then raise notice '    OK — permission denied';
end $$;
reset role;

\echo ''
\echo '*** ALLE BEVEILIGINGSTESTS GESLAAGD ***'
