const COMBINING_MARKS = /[\u0300-\u036f]/g

/** URL-veilige stadsnaam: "Den Haag" -> "den-haag". Werkt op server en client. */
export function citySlug(city: string | null | undefined): string {
  return (city ?? 'nederland')
    .toLowerCase()
    .normalize('NFD')
    .replace(COMBINING_MARKS, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}
