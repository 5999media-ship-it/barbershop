// =============================================================================
// notifications-dispatch — Supabase Edge Function (Deno)
// =============================================================================
// Draait op een cron (elke minuut) en werkt de outbox af:
//   1. claim_due_notifications() pakt een batch met FOR UPDATE SKIP LOCKED,
//      zodat twee gelijktijdige runs elkaar nooit dubbel versturen.
//   2. Per bericht wordt het juiste kanaal aangeroepen.
//   3. Succes -> mark_notification_sent, fout -> mark_notification_failed met
//      exponentiële backoff. Na vijf pogingen blijft hij op 'failed' staan en
//      kun je hem in het dashboard terugvinden.
//
// Deployen:
//   supabase functions deploy notifications-dispatch --no-verify-jwt
//   supabase secrets set RESEND_API_KEY=... CRON_SECRET=... NOTIFY_FROM_EMAIL=...
//
// Cron aanzetten (SQL editor):
//   select cron.schedule('dispatch-notifications', '* * * * *', $$
//     select net.http_post(
//       url := 'https://<project>.supabase.co/functions/v1/notifications-dispatch',
//       headers := jsonb_build_object('x-cron-secret', '<CRON_SECRET>')
//     );
//   $$);
// =============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

interface NotificationJob {
  id: string
  channel: 'email' | 'sms' | 'whatsapp'
  template: string
  recipient: string
  attempts: number
  shop: {
    name: string
    slug: string
    phone: string | null
    timezone: string
    address: string | null
    reply_to: string | null
    logo_url: string | null
  }
  booking: {
    id: string
    starts_at: string
    service_end_at: string
    status: string
    price_cents: number
    currency: string
    customer_name: string
    customer_email: string
    customer_phone: string
    notes: string | null
    manage_token: string
    service_name: string
    barber_name: string
  }
}

const SITE_URL = Deno.env.get('SITE_URL') ?? 'https://example.com'
const FROM_EMAIL = Deno.env.get('NOTIFY_FROM_EMAIL') ?? 'Afspraken <onboarding@resend.dev>'

Deno.serve(async (request: Request) => {
  // Deze functie draait zonder JWT-verificatie (de cron heeft er geen), dus
  // beschermen we hem met een gedeeld geheim.
  const expected = Deno.env.get('CRON_SECRET')
  if (expected && request.headers.get('x-cron-secret') !== expected) {
    return new Response('forbidden', { status: 403 })
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  )

  const { data, error } = await supabase.rpc('claim_due_notifications', { p_limit: 50 })
  if (error) {
    console.error('claim failed', error)
    return Response.json({ ok: false, error: error.message }, { status: 500 })
  }

  const jobs = (data ?? []) as NotificationJob[]
  let sent = 0
  let failed = 0

  for (const job of jobs) {
    try {
      if (job.channel === 'email') await sendEmail(job)
      else await sendSms(job)

      await supabase.rpc('mark_notification_sent', { p_id: job.id })
      sent++
    } catch (err) {
      console.error(`notification ${job.id} faalde`, err)
      await supabase.rpc('mark_notification_failed', {
        p_id: job.id,
        p_error: err instanceof Error ? err.message : String(err),
      })
      failed++
    }
  }

  return Response.json({ ok: true, claimed: jobs.length, sent, failed })
})

// ---------------------------------------------------------------------------
// Kanalen
// ---------------------------------------------------------------------------
async function sendEmail(job: NotificationJob) {
  const apiKey = Deno.env.get('RESEND_API_KEY')
  if (!apiKey) throw new Error('RESEND_API_KEY ontbreekt')

  const { subject, html, text } = renderEmail(job)

  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: FROM_EMAIL,
      to: [job.recipient],
      reply_to: job.shop.reply_to ?? undefined,
      subject,
      html,
      text,
    }),
  })

  if (!response.ok) {
    throw new Error(`Resend ${response.status}: ${await response.text()}`)
  }
}

async function sendSms(job: NotificationJob) {
  const sid = Deno.env.get('TWILIO_ACCOUNT_SID')
  const token = Deno.env.get('TWILIO_AUTH_TOKEN')
  if (!sid || !token) throw new Error('Twilio-credentials ontbreken')

  const isWhatsApp = job.channel === 'whatsapp'
  const from = isWhatsApp
    ? Deno.env.get('TWILIO_WHATSAPP_FROM')
    : Deno.env.get('TWILIO_FROM_NUMBER')
  if (!from) throw new Error('Afzendernummer ontbreekt')

  const body = new URLSearchParams({
    From: isWhatsApp ? `whatsapp:${from}` : from,
    To: isWhatsApp ? `whatsapp:${job.recipient}` : job.recipient,
    Body: renderSms(job),
  })

  const response = await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`,
    {
      method: 'POST',
      headers: {
        Authorization: `Basic ${btoa(`${sid}:${token}`)}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body,
    },
  )

  if (!response.ok) {
    throw new Error(`Twilio ${response.status}: ${await response.text()}`)
  }
}

// ---------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------
function when(job: NotificationJob): string {
  return new Intl.DateTimeFormat('nl-NL', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    hour: '2-digit',
    minute: '2-digit',
    timeZone: job.shop.timezone,
  }).format(new Date(job.booking.starts_at))
}

function manageUrl(job: NotificationJob): string {
  return `${SITE_URL}/afspraak/${job.booking.manage_token}`
}

function renderEmail(job: NotificationJob): { subject: string; html: string; text: string } {
  const b = job.booking
  const moment = when(job)
  const price = new Intl.NumberFormat('nl-NL', {
    style: 'currency',
    currency: b.currency,
  }).format(b.price_cents / 100)

  const templates: Record<string, { subject: string; heading: string; intro: string }> = {
    booking_confirmation: {
      subject: `Bevestigd: ${b.service_name} op ${moment}`,
      heading: 'Je afspraak staat',
      intro: `Hoi ${b.customer_name}, je bent ingepland bij ${job.shop.name}.`,
    },
    booking_reminder_24h: {
      subject: `Morgen: ${b.service_name} bij ${job.shop.name}`,
      heading: 'Tot morgen',
      intro: `Hoi ${b.customer_name}, kleine herinnering aan je afspraak.`,
    },
    booking_reminder_2h: {
      subject: `Over 2 uur: ${b.service_name}`,
      heading: 'Bijna zover',
      intro: `Hoi ${b.customer_name}, over ongeveer twee uur word je verwacht.`,
    },
    booking_cancelled: {
      subject: `Geannuleerd: ${b.service_name} op ${moment}`,
      heading: 'Afspraak geannuleerd',
      intro: `Hoi ${b.customer_name}, je afspraak is geannuleerd. Tot een volgende keer.`,
    },
    staff_new_booking: {
      subject: `Nieuwe boeking: ${b.customer_name} — ${moment}`,
      heading: 'Nieuwe boeking',
      intro: `${b.customer_name} heeft ${b.service_name} geboekt bij ${b.barber_name}.`,
    },
  }

  const t = templates[job.template] ?? templates.booking_confirmation!
  const isStaff = job.template === 'staff_new_booking'

  const rows: Array<[string, string]> = [
    ['Wanneer', moment],
    ['Behandeling', b.service_name],
    ['Barber', b.barber_name],
    ['Prijs', price],
  ]
  if (job.shop.address) rows.push(['Adres', job.shop.address])
  if (isStaff) {
    rows.push(['Telefoon', b.customer_phone], ['E-mail', b.customer_email])
    if (b.notes) rows.push(['Opmerking', b.notes])
  }

  const html = `<!doctype html>
<html lang="nl"><body style="margin:0;background:#f5f5f4;font-family:-apple-system,Segoe UI,Roboto,sans-serif;color:#1c1c1e">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:32px 16px">
    <tr><td align="center">
      <table role="presentation" width="100%" style="max-width:520px;background:#fff;border-radius:14px;overflow:hidden;border:1px solid #e5e5e5">
        <tr><td style="padding:28px 28px 8px">
          <h1 style="margin:0;font-size:22px;font-weight:600">${escapeHtml(t.heading)}</h1>
          <p style="margin:10px 0 0;font-size:15px;line-height:1.5;color:#52525b">${escapeHtml(t.intro)}</p>
        </td></tr>
        <tr><td style="padding:16px 28px">
          <table role="presentation" width="100%" style="font-size:14px">
            ${rows
              .map(
                ([label, value]) =>
                  `<tr><td style="padding:7px 0;color:#71717a">${escapeHtml(label)}</td><td style="padding:7px 0;text-align:right;font-weight:500">${escapeHtml(value)}</td></tr>`,
              )
              .join('')}
          </table>
        </td></tr>
        ${
          isStaff || job.template === 'booking_cancelled'
            ? ''
            : `<tr><td style="padding:8px 28px 28px" align="center">
                 <a href="${manageUrl(job)}" style="display:inline-block;background:#1c1c1e;color:#fff;text-decoration:none;padding:13px 26px;border-radius:9px;font-size:15px;font-weight:600">Afspraak bekijken of annuleren</a>
                 <p style="margin:12px 0 0;font-size:12px;color:#a1a1aa">Bewaar deze mail — dit is je persoonlijke link.</p>
               </td></tr>`
        }
        <tr><td style="padding:18px 28px;background:#fafafa;border-top:1px solid #eee;font-size:12px;color:#71717a">
          ${escapeHtml(job.shop.name)}${job.shop.phone ? ` · ${escapeHtml(job.shop.phone)}` : ''}
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`

  const text = [
    t.heading,
    '',
    t.intro,
    '',
    ...rows.map(([label, value]) => `${label}: ${value}`),
    '',
    isStaff ? '' : manageUrl(job),
  ].join('\n')

  return { subject: t.subject, html, text }
}

function renderSms(job: NotificationJob): string {
  const b = job.booking
  const moment = when(job)

  switch (job.template) {
    case 'booking_reminder_2h':
      return `Tot straks! ${b.service_name} om ${moment.split(' ').slice(-1)[0]} bij ${job.shop.name}. Niet kunnen? ${manageUrl(job)}`
    case 'booking_cancelled':
      return `Je afspraak bij ${job.shop.name} op ${moment} is geannuleerd.`
    default:
      return `${job.shop.name}: ${b.service_name} bij ${b.barber_name} op ${moment}. Wijzigen of annuleren: ${manageUrl(job)}`
  }
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}
