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
