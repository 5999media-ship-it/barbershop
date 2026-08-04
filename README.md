# BarberBook — multi-tenant bookingplatform voor barbershops

Next.js 15 (App Router) + Supabase. Eén platform, meerdere salons, meerdere barbers
per salon, gastboekingen zonder account, en een agenda waarin dubbelboeken
technisch onmogelijk is.

---

## Wat dit anders doet dan de gemiddelde bookingwidget

| | Typische widget | Dit systeem |
|---|---|---|
| Dubbelboeken | Applicatiecheck: race condition bij gelijktijdige klikken | Postgres `EXCLUDE`-constraint met GiST — fysiek onmogelijk |
| Prijs en duur | Komen uit de request van de browser | Worden serverside opnieuw uit de database gelezen |
| Boekingen lezen | Vaak één tabel achter een API-key | Geen enkele RLS-policy voor `anon`; gastentoegang loopt via een token-RPC |
| SEO | iframe of client-side render | Server-rendered pagina per salon en per stad, met `HairSalon` + `ReserveAction` JSON-LD |
| Tijdzones | Lokale tijd van de browser | Alles gaat door de tijdzone van de salon; DST wordt door Postgres afgehandeld |
| Annuleren | Bellen | Zelfservice via een geheime link, met annuleringsvenster |
| Notificaties | Fire-and-forget in het request | Outbox-tabel + dispatcher met retries en backoff |

---

## Snel starten

### 1. Database

Je hebt twee routes.

**A. Supabase CLI (aanbevolen)**

```bash
supabase link --project-ref qidnrhdjekhnaypnusvv
supabase db push
```

**B. SQL Editor**

Open `supabase/schema-full.sql`, plak de inhoud in de SQL Editor van je project
en voer hem uit. Dat bestand is de samenvoeging van alles in
`supabase/migrations/` in de juiste volgorde.

> De laatste migratie (`…_seed_demo.sql`) zet een demosalon neer. Sla hem over
> of verwijder de data later met
> `delete from public.shops where slug = 'junique-fades';`

### 2. Omgevingsvariabelen

```bash
cp .env.example .env.local
```

Vul in:

| Variabele | Waar vind je hem | Geheim? |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Project Settings → API | nee |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Project Settings → API Keys → publishable | nee |
| `SUPABASE_SERVICE_ROLE_KEY` | Project Settings → API Keys → secret | **ja** |
| `NEXT_PUBLIC_SITE_URL` | je eigen domein | nee |

De service-role key omzeilt alle RLS-policies. Zet hem nooit in een variabele
die met `NEXT_PUBLIC_` begint en commit hem nooit.

### 3. Draaien

```bash
npm install
npm run dev
```

- Publiek: <http://localhost:3000>
- Demosalon: <http://localhost:3000/kapper/amsterdam/junique-fades>
- Dashboard: <http://localhost:3000/dashboard> (maak eerst een account via `/login`)

### 4. Jezelf eigenaar maken van de demosalon

```sql
insert into public.shop_members (shop_id, user_id, role)
select '11111111-1111-4111-8111-111111111111', id, 'shop_owner'
from auth.users where email = 'jouw@email.nl'
on conflict (shop_id, user_id) do update set role = 'shop_owner';
```

---

## Deployen naar Netlify

Deze app is **geen statische site**. Er draaien server components, route
handlers, server actions en middleware. Een `next export` naar een mapje HTML
zou precies de beveiliging slopen die de rest van dit project opbouwt: de
service-role key, de rate limiting en de `create_booking`-aanroep horen aan de
serverkant. De Netlify Next Runtime regelt dat: statische assets naar de CDN,
server-rendering naar Netlify Functions.

### Configuratie is runtime, niet buildtime

Alle publieke instellingen worden per request uit de omgeving gelezen en via
een klein script in de layout naar de browser gestuurd
(`src/components/PublicEnvScript.tsx`). Reden: Next vervangt elke
`NEXT_PUBLIC_`-variabele tijdens de build letterlijk in de bundle. Je zou dan
één artefact hebben dat aan één Supabase-project vastzit, en voor staging
opnieuw moeten bouwen. Nu is dezelfde build overal bruikbaar.

Vier variabelen, te zetten onder **Site configuration → Environment variables**:

| Variabele | Waarde | Secret? |
|---|---|---|
| `SUPABASE_URL` | `https://<ref>.supabase.co` | nee |
| `SUPABASE_ANON_KEY` | de publishable key | nee |
| `SUPABASE_SERVICE_ROLE_KEY` | de secret key | **ja, aanvinken** |
| `SITE_URL` | je definitieve domein | nee |

Laat je `SITE_URL` leeg, dan valt de app terug op de `URL` die Netlify zelf
zet. Prima om te testen, maar zet hem expliciet zodra je een eigen domein
hebt — anders staan er `*.netlify.app`-adressen in je sitemap en JSON-LD.

### Optie A — vanaf Git (aanbevolen voor doorontwikkeling)

Push naar GitHub, koppel de repo in Netlify. `netlify.toml` staat er al in, dus
build command, publish directory, Node-versie en de runtime-plugin worden
automatisch opgepikt. Deploy previews en branch-deploys krijgen een
`X-Robots-Tag: noindex` mee, zodat ze niet met je echte pagina's concurreren in
Google.

### Optie B — rechtstreeks vanaf je laptop, zonder Git

```bash
npm run deploy          # preview-deploy met een eigen URL
npm run deploy:prod     # productie
```

De eerste keer vraagt de Netlify CLI om in te loggen en een site te kiezen of
aan te maken.

### Optie C — het meegeleverde prebuilt artefact

Er is een kant-en-klare build meegeleverd (`.netlify/` + `.next/`). Uitpakken
en uploaden zonder zelf te bouwen:

```bash
tar -xzf barber-booking-netlify-dist.tgz
cd barber-booking-dist
npx netlify-cli@latest deploy --prod --no-build
```

Werkt, maar heeft twee nadelen: je moet het opnieuw van mij krijgen bij elke
codewijziging, en de Netlify CLI-versie moet redelijk overeenkomen met die
waarmee gebouwd is. Voor eenmalig live gaan is het prima; voor doorontwikkelen
is optie A of B beter.

---

## Architectuur

```
Browser ──► Next.js Server Component ──► Supabase (anon key + RLS)
   │                                          ▲
   │  POST /api/book                          │
   ▼                                          │
Route Handler ──► register_booking_attempt()  │  service_role, eigen transactie
              └─► create_booking()  ──────────┘  SECURITY DEFINER, valideert alles
```

### De vier lagen beveiliging

1. **Grants** — `anon` heeft geen `insert` op `bookings`. De table-brede
   `select` is ingetrokken en vervangen door een expliciete kolomlijst, zodat
   `manage_token` en `created_ip_hash` er niet in zitten. (Een kale
   `revoke select (kolom)` is in Postgres een no-op zolang de table-grant
   blijft staan — een klassieke valkuil.)
2. **RLS** — deny-by-default op elke tabel. Helper-functies zijn `SECURITY
   DEFINER` zodat policies op `shop_members` zichzelf niet oproepen (recursie).
3. **RPC's** — `create_booking` haalt prijs, duur en barber zelf op en negeert
   wat de client beweert. De functie is bewust **niet** aan `anon` gegeven:
   alles loopt via `POST /api/book`, waar de server het echte IP kent. Zou je
   hem wél aan `anon` geven, dan roept een aanvaller de REST-endpoint direct
   aan en slaat hij honeypot én rate limiting over.
4. **Constraints** — `bookings_no_overlap` (`EXCLUDE USING gist`) laat twee
   actieve afspraken bij dezelfde barber nooit overlappen, ook niet bij
   gelijktijdige requests. Samengestelde foreign keys op `(barber_id, shop_id)`
   en `(service_id, shop_id)` maken het onmogelijk een boeking naar een andere
   tenant te verplaatsen.

Daarnaast staan er twee `BEFORE UPDATE`-triggers die kolommen terugzetten in
plaats van te weigeren: `tg_profiles_guard` (niemand promoveert zichzelf tot
`platform_admin`) en `tg_barbers_guard` (een barber kan zijn eigen rij niet
naar een andere salon verplaatsen). Een `WITH CHECK` kan dit niet: die ziet
alleen de nieuwe rij en weet niet welke kolommen er veranderd zijn.

### Waarom de beschikbaarheid in SQL zit

`available_slots()` is de enige plek waar berekend wordt wat vrij is. De
boekingswizard, het dashboard en `create_booking()` gebruiken dezelfde functie.
Zou je dit in TypeScript nabouwen, dan krijg je vroeg of laat de klassieke bug:
de UI toont een slot dat de backend weigert. Bovendien gaat de zomertijd
vanzelf goed, omdat werktijden als lokale `time` staan opgeslagen en per
kalenderdag met `AT TIME ZONE` worden omgezet.

---

## Belangrijkste bestanden

```
supabase/migrations/
  …000100_init_schema.sql      tabellen, enums, de EXCLUDE-constraint
  …000200_rls_policies.sql     RLS + helper-functies + grants
  …000300_availability.sql     available_slots() / available_days()
  …000400_booking_rpc.sql      create_booking, cancel, reschedule, rate limiting
  …000500_notifications.sql    outbox, triggers, dispatcher-API, onderhoud
  …000600_seed_demo.sql        demodata
supabase/tests/                 lokale regressietests (20 stuks)
supabase/functions/
  notifications-dispatch/       Edge Function: mail via Resend, SMS via Twilio

src/app/kapper/[city]/[slug]/   publieke salonpagina (SEO + JSON-LD)
src/app/kapper/[city]/          stadspagina (het GEO-anker)
src/app/afspraak/[token]/       zelfservice voor gasten
src/app/dashboard/              agenda, afspraken, diensten, team, rooster
src/app/api/book/route.ts       rate limiting + boeking aanmaken
src/lib/format.ts               tijdzone-veilige formattering
```

---

## Tests

```bash
npm run db:test
```

Draait alle migraties op een lokale, kale Postgres 16 (met een stub voor het
`auth`-schema) en voert 31 tests uit:

- `01_smoke.sql` — beschikbaarheid, normalisatie van e-mail en telefoon,
  dubbelboeken, de EXCLUDE-constraint, rate limiting, annuleren, het intrekken
  van herinneringen, plus vijf tests waarin we echt `set role anon` doen en
  proberen data te lezen die niet van ons is.
- `02_security.sql` — regressietests voor concrete kwetsbaarheden die tijdens
  een adversariële review op dit project zijn gevonden en gedicht:
  privilege-escalatie via `profiles`, cross-tenant barber-injectie, het
  uitlezen van `manage_token`, een manager die zichzelf tot eigenaar
  promoveert, het verplaatsen van een boeking naar een andere salon, het
  omzeilen van de rate limiting via de REST-API, en het verzetten van een
  afspraak dat een valse annuleringsmail veroorzaakte.

Vereist lokaal `postgresql-16` en `postgresql-contrib-16`.

> Elke test in `02_security.sql` heeft ooit gefaald. Ze staan er niet voor de
> sier maar omdat de bijbehorende exploit werkte.

---

## Notificaties aanzetten

```bash
supabase functions deploy notifications-dispatch --no-verify-jwt
supabase secrets set \
  RESEND_API_KEY=re_... \
  NOTIFY_FROM_EMAIL="Afspraken <afspraken@jouwdomein.nl>" \
  SITE_URL=https://jouwdomein.nl \
  CRON_SECRET=$(openssl rand -hex 32)
```

Cron elke minuut (SQL Editor, `pg_cron` + `pg_net` moeten aan staan):

```sql
select cron.schedule('dispatch-notifications', '* * * * *', $$
  select net.http_post(
    url     := 'https://<ref>.supabase.co/functions/v1/notifications-dispatch',
    headers := jsonb_build_object('x-cron-secret', '<CRON_SECRET>')
  );
$$);

select cron.schedule('barberbook-maintenance', '0 3 * * *', $$
  select public.run_maintenance();
$$);
```

SMS/WhatsApp: zet `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` en
`TWILIO_FROM_NUMBER` en zet `notify_sms_enabled` aan bij de salon.

---

## SEO en lokale vindbaarheid

Wat er al in zit:

- **Server-side rendering** van elke salon- en stadspagina, met ISR van vijf
  minuten. Google ziet volledige HTML, geen loading spinner.
- **`HairSalon` JSON-LD** met NAP-gegevens, `geo`, `openingHoursSpecification`,
  `hasOfferCatalog` (elke behandeling met prijs) en een `ReserveAction`. Die
  laatste is wat Google nodig heeft om een "Afspraak maken"-knop te tonen.
- **`BreadcrumbList`** en een `ItemList` op de stadspagina.
- **URL-structuur** `/kapper/{stad}/{salon}` — stadsnaam in het pad, canonieke
  redirect als iemand de verkeerde stad gebruikt.
- **Dynamische sitemap** met `lastModified` uit de database.
- **`noindex`** op de boekingsflow, de tokenpagina en het dashboard.

Wat jij nog moet doen — dit is waar de winst zit:

1. **Google-bedrijfsprofiel**: naam, adres en telefoonnummer moeten *letterlijk*
   overeenkomen met wat je in de instellingen invult. Verschillen kosten
   posities in de map pack.
2. **Zet de boekingslink in je profiel** onder "Afspraken".
3. **Vul de omschrijving met echte taal**: "skin fade Amsterdam Zuid" wint van
   "wij bieden kwaliteitskapsels".
4. **Vraag reviews** — voor lokale rankings weegt dat zwaarder dan techniek.
5. **Eén pagina per stad, niet per wijk**, tenzij je er echt een vestiging hebt.
   Dunne wijkpagina's werken averechts sinds de helpful-content-updates.

---

## Wat er bewust nog niet in zit

- **Online betalen / aanbetaling.** Het datamodel is er klaar voor
  (`price_cents`, `currency`, `status = 'pending'`). Mollie is voor NL/BE de
  logische keuze vanwege iDEAL: `pending` bij aanmaken, via webhook naar
  `confirmed`, plus een cron die `pending` ouder dan vijftien minuten opruimt.
- **Terugkerende afspraken** en wachtlijsten.
- **Uploads** voor logo's en foto's (Supabase Storage met RLS per shop).
- **Multi-language.** De teksten staan nu in het Nederlands in de componenten;
  voor internationaal is `next-intl` de volgende stap.

---

## Licentie

Privé project. Doe ermee wat je wilt.
