import { cookies } from 'next/headers'

import { THEME_COOKIE, type ThemeChoice } from './theme-shared'

export { THEME_COOKIE }
export type { ThemeChoice }

/**
 * Themakeuze uit de cookie.
 *
 * Waarom een cookie en geen localStorage? Omdat de server dan al weet welk
 * thema hij moet renderen. Met localStorage krijg je onvermijdelijk een flits
 * van het verkeerde thema voordat het script draait.
 */
export async function getThemeChoice(): Promise<ThemeChoice> {
  const value = (await cookies()).get(THEME_COOKIE)?.value
  return value === 'light' || value === 'dark' ? value : 'system'
}
