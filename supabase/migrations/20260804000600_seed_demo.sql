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
