/**
 * Gedeeld tussen server en client.
 *
 * Bewust een apart bestand: `theme.ts` importeert `next/headers` en dat mag
 * niet in een client component belanden. Eén regel import is genoeg om de hele
 * build te laten struikelen, dus de constante en het type wonen hier los.
 */
export const THEME_COOKIE = 'bb_theme'
export type ThemeChoice = 'light' | 'dark' | 'system'
