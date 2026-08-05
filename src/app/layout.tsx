/**
 * Wortel-layout. Bewust leeg: <html> en <body> staan in [locale]/layout.tsx,
 * omdat het lang-attribuut pas bekend is zodra de taal uit de URL is gelezen.
 * Next.js vereist wel dat dit bestand bestaat.
 */
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return children
}
