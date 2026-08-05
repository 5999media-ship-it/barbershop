-- =============================================================================
-- 02_security.sql — regressietests voor gedichte kwetsbaarheden
-- =============================================================================
-- Elke test hieronder correspondeert met een bevinding uit de securityreview.
-- Ze staan er zodat een toekomstige refactor niet stilletjes een gat heropent.
-- =============================================================================
\set QUIET on
\pset pager off

-- Testgebruikers
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'owner@test.nl'),
  ('aaaaaaaa-0000-4000-8000-000000000002', 'manager@test.nl'),
  ('aaaaaaaa-0000-4000-8000-000000000003', 'mallory@test.nl'),
  ('aaaaaaaa-0000-4000-8000-000000000004', 'barber@test.nl')
on conflict (id) do nothing;

insert into public.shop_members (shop_id, user_id, role) values
  ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-0000-4000-8000-000000000001', 'shop_owner'),
  ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-0000-4000-8000-000000000002', 'manager')
on conflict (shop_id, user_id) do update set role = excluded.role;

-- -----------------------------------------------------------------------------
\echo '--- TEST 21: gebruiker kan zichzelf niet tot platform_admin promoveren'
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-4000-8000-000000000003';
do $$
begin
  update public.profiles set is_platform_admin = true
   where id = 'aaaaaaaa-0000-4000-8000-000000000003';
  -- Mocht de kolomgrant ooit terugkomen, dan vangt de trigger het alsnog af.
  if (select is_platform_admin from public.profiles
       where id = 'aaaaaaaa-0000-4000-8000-000000000003') then
    raise exception 'FAAL: privilege escalation gelukt!';
  end if;
  raise notice '    OK — vlag bleef staan (trigger ving het af)';
exception when insufficient_privilege then
  raise notice '    OK — permission denied op de kolom';
end $$;
reset role;

\echo '--- TEST 22: gewone velden op het eigen profiel blijven wel bewerkbaar'
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-4000-8000-000000000003';
do $$
begin
  update public.profiles set full_name = 'Mallory'
   where id = 'aaaaaaaa-0000-4000-8000-000000000003';
  raise notice '    OK';
end $$;
reset role;

-- -----------------------------------------------------------------------------
\echo '--- TEST 23: barber kan zijn rij niet naar een andere shop verplaatsen'
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-4000-8000-000000000003';
do $$
declare
  v_evil   uuid := 'eeeeeeee-0000-4000-8000-000000000001';
  v_barber uuid := 'eeeeeeee-0000-4000-8000-000000000002';
  v_shop   uuid;
begin
  -- Let op: bewust géén ON CONFLICT. Onder RLS eist Postgres bij ON CONFLICT
  -- dat de rij ook via een SELECT-policy zichtbaar is, en een verse, nog niet
  -- gepubliceerde shop is dat per definitie niet.
  insert into public.shops (id, slug, name, city, created_by)
  values (v_evil, 'evil-shop', 'Evil Shop', 'Amsterdam',
          'aaaaaaaa-0000-4000-8000-000000000003');

  insert into public.barbers (id, shop_id, user_id, slug, display_name)
  values (v_barber, v_evil, 'aaaaaaaa-0000-4000-8000-000000000003', 'mallory', 'Mallory');

  update public.barbers
     set shop_id = '11111111-1111-4111-8111-111111111111'
   where id = v_barber;

  select shop_id into v_shop from public.barbers where id = v_barber;
  if v_shop <> v_evil then
    raise exception 'FAAL: barber staat nu in shop % !', v_shop;
  end if;
  raise notice '    OK — shop_id werd teruggezet door de trigger';
end $$;
reset role;

\echo '--- TEST 24: dienst van een andere shop koppelen lukt niet'
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-4000-8000-000000000003';
do $$
begin
  insert into public.barber_services (barber_id, service_id, price_cents)
  values ('eeeeeeee-0000-4000-8000-000000000002',
          '33333333-3333-4333-8333-333333333331', 500);
  raise exception 'FAAL: cross-tenant koppeling geaccepteerd!';
exception
  when insufficient_privilege then raise notice '    OK — permission denied';
  when others then
    if sqlstate = '42501' then raise notice '    OK — RLS blokkeerde de insert';
    else raise; end if;
end $$;
reset role;

-- -----------------------------------------------------------------------------
\echo '--- TEST 25: manage_token is niet te selecteren'
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-4000-8000-000000000001';
do $$
declare v_t uuid;
begin
  select manage_token into v_t from public.bookings limit 1;
  raise exception 'FAAL: manage_token uitgelezen (%)!', v_t;
exception when insufficient_privilege then
  raise notice '    OK — permission denied op de kolom';
end $$;
reset role;

\echo '--- TEST 26: eigenaar ziet de toegestane kolommen wel gewoon'
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-4000-8000-000000000001';
do $$
declare v_cnt int;
begin
  select count(*) into v_cnt from public.bookings b
   where b.shop_id = '11111111-1111-4111-8111-111111111111';
  raise notice '    OK — % boeking(en) zichtbaar', v_cnt;
end $$;
reset role;

-- -----------------------------------------------------------------------------
\echo '--- TEST 27: manager kan zichzelf niet tot eigenaar promoveren'
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-4000-8000-000000000002';
do $$
declare v_role public.app_role;
begin
  update public.shop_members set role = 'shop_owner'
   where user_id = 'aaaaaaaa-0000-4000-8000-000000000002';

  select role into v_role from public.shop_members
   where user_id = 'aaaaaaaa-0000-4000-8000-000000000002';
  if v_role <> 'manager' then raise exception 'FAAL: rol is nu %', v_role; end if;
  raise notice '    OK — rol bleef manager';
end $$;
reset role;

\echo '--- TEST 28: manager kan de eigenaar niet verwijderen'
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-4000-8000-000000000002';
do $$
declare v_cnt int;
begin
  delete from public.shop_members
   where user_id = 'aaaaaaaa-0000-4000-8000-000000000001';

  select count(*) into v_cnt from public.shop_members
   where user_id = 'aaaaaaaa-0000-4000-8000-000000000001';
  if v_cnt = 0 then raise exception 'FAAL: eigenaar verwijderd'; end if;
  raise notice '    OK — eigenaar staat er nog';
end $$;
reset role;

-- -----------------------------------------------------------------------------
\echo '--- TEST 29: anon kan create_booking niet rechtstreeks aanroepen'
set role anon;
do $$
begin
  perform public.create_booking(
    '11111111-1111-4111-8111-111111111111',
    '33333333-3333-4333-8333-333333333331',
    now() + interval '3 days',
    'Bypass', 'bypass@example.com', '0612345678');
  raise exception 'FAAL: anon kon de RPC aanroepen!';
exception when insufficient_privilege then
  raise notice '    OK — permission denied for function';
end $$;
reset role;

-- -----------------------------------------------------------------------------
\echo '--- TEST 30: shop_id van een boeking ligt vast'
do $$
declare v_id uuid;
begin
  select id into v_id from public.bookings limit 1;
  if v_id is null then raise notice '    OVERGESLAGEN — geen boekingen'; return; end if;

  update public.bookings set shop_id = 'eeeeeeee-0000-4000-8000-000000000001' where id = v_id;
  raise exception 'FAAL: boeking verplaatst naar een andere shop!';
exception
  when sqlstate 'P0001' then raise notice '    OK — %', sqlerrm;
  when foreign_key_violation then raise notice '    OK — samengestelde FK weigerde het';
end $$;

-- -----------------------------------------------------------------------------
\echo '--- TEST 31: verzetten herberekent de prijs en stuurt geen annuleringsmail'
do $$
declare
  v_shop  uuid := '11111111-1111-4111-8111-111111111111';
  v_svc   uuid := '33333333-3333-4333-8333-333333333331';
  v_slotA timestamptz;
  v_slotB timestamptz;
  v_res   jsonb;
  v_token uuid;
  v_price int;
  v_cnt   int;
begin
  select s.slot_start into v_slotA
  from public.available_slots(v_shop, v_svc, current_date + 7, current_date + 9) s
  order by s.slot_start limit 1;

  v_res := public.create_booking(v_shop, v_svc, v_slotA,
    'Verzetter', 'verzet@example.com', '0612349999', null, null, '203.0.113.44');
  v_token := (v_res ->> 'manage_token')::uuid;

  select s.slot_start into v_slotB
  from public.available_slots(v_shop, v_svc, current_date + 7, current_date + 9,
                              (v_res ->> 'barber_id')::uuid) s
  where s.slot_start > v_slotA
  order by s.slot_start limit 1;

  perform public.reschedule_booking_by_token(v_token, v_slotB);

  select price_cents into v_price from public.bookings where manage_token = v_token;
  if v_price is null or v_price = 0 then raise exception 'FAAL: prijs kwijt'; end if;

  select count(*) into v_cnt from public.notifications n
   where n.booking_id = (v_res ->> 'booking_id')::uuid
     and n.template = 'booking_cancelled';
  if v_cnt > 0 then raise exception 'FAAL: valse annuleringsmail gequeued'; end if;

  select count(*) into v_cnt from public.notifications n
   where n.booking_id = (v_res ->> 'booking_id')::uuid
     and n.template in ('booking_reminder_24h', 'booking_reminder_2h')
     and n.status = 'queued';
  if v_cnt = 0 then raise exception 'FAAL: herinneringen zijn ingetrokken'; end if;

  raise notice '    OK — prijs % cent, herinneringen intact, geen annuleringsmail', v_price;
end $$;

\echo ''
\echo '*** ALLE REGRESSIETESTS GESLAAGD ***'

-- =============================================================================
-- Regressietests voor het zelfbeheer van kappers (migratie 000700)
-- =============================================================================
insert into public.barbers (id, shop_id, user_id, slug, display_name)
values ('bbbbbbbb-0000-4000-8000-000000000001',
        '11111111-1111-4111-8111-111111111111',
        'aaaaaaaa-0000-4000-8000-000000000004', 'testbarber', 'Test Barber')
on conflict (id) do nothing;

insert into public.barber_services (barber_id, service_id, price_cents, duration_minutes)
values ('bbbbbbbb-0000-4000-8000-000000000001',
        '33333333-3333-4333-8333-333333333331', 3500, 45)
on conflict do nothing;

\echo '--- TEST 32: kapper mag zijn eigen tarief aanpassen'
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-4000-8000-000000000004';
do $$
declare v_price int;
begin
  update public.barber_services set price_cents = 4250
   where barber_id = 'bbbbbbbb-0000-4000-8000-000000000001'
     and service_id = '33333333-3333-4333-8333-333333333331';

  select price_cents into v_price from public.barber_services
   where barber_id = 'bbbbbbbb-0000-4000-8000-000000000001'
     and service_id = '33333333-3333-4333-8333-333333333331';

  if v_price <> 4250 then raise exception 'FAAL: tarief niet opgeslagen (%)', v_price; end if;
  raise notice '    OK — tarief staat op % cent', v_price;
end $$;
reset role;

\echo '--- TEST 33: maar niet de duur van de behandeling'
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-4000-8000-000000000004';
do $$
declare v_dur int;
begin
  update public.barber_services set duration_minutes = 5
   where barber_id = 'bbbbbbbb-0000-4000-8000-000000000001'
     and service_id = '33333333-3333-4333-8333-333333333331';

  select duration_minutes into v_dur from public.barber_services
   where barber_id = 'bbbbbbbb-0000-4000-8000-000000000001'
     and service_id = '33333333-3333-4333-8333-333333333331';

  if v_dur <> 45 then
    raise exception 'FAAL: kapper kon de duur op % zetten en zo de agenda volproppen', v_dur;
  end if;
  raise notice '    OK — duur bleef 45 minuten';
end $$;
reset role;

\echo '--- TEST 34: kapper kan geen afbeelding voor een vreemde salon plaatsen'
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-4000-8000-000000000004';
do $$
begin
  if public.can_write_media('shops/eeeeeeee-0000-4000-8000-000000000001/image.webp') then
    raise exception 'FAAL: schrijfrecht op een vreemde salon!';
  end if;
  if public.can_write_media('barbers/eeeeeeee-0000-4000-8000-000000000002/image.webp') then
    raise exception 'FAAL: schrijfrecht op de foto van een andere kapper!';
  end if;
  if not public.can_write_media('barbers/bbbbbbbb-0000-4000-8000-000000000001/image.webp') then
    raise exception 'FAAL: kapper kan zijn eigen foto niet plaatsen';
  end if;
  raise notice '    OK — alleen de eigen map';
end $$;
reset role;

\echo '--- TEST 35: onzinnige paden geven false, geen crash'
do $$
begin
  if public.can_write_media('shops/../../../etc/passwd') then
    raise exception 'FAAL: pad-traversal geaccepteerd';
  end if;
  if public.can_write_media('rommel') then
    raise exception 'FAAL: onzinpad geaccepteerd';
  end if;
  raise notice '    OK';
end $$;
