import type { ThemeChoice } from '@/lib/theme-shared'

/**
 * Zet de theme-klasse vóórdat de browser iets tekent.
 *
 * Bij een expliciete keuze doet de server het al via de class op <html>; dit
 * script is er voor 'system', waar alleen de browser weet wat de gebruiker
 * heeft ingesteld. Het draait synchroon in de <head>, dus er is geen enkel
 * frame waarin het verkeerde thema zichtbaar is.
 */
export default function ThemeScript({ choice }: { choice: ThemeChoice }) {
  const script = `
(function () {
  try {
    var c = ${JSON.stringify(choice)};
    var dark = c === 'dark' || (c === 'system' &&
      window.matchMedia('(prefers-color-scheme: dark)').matches);
    document.documentElement.classList.toggle('dark', dark);
  } catch (e) {}
})();`

  return <script dangerouslySetInnerHTML={{ __html: script }} />
}
