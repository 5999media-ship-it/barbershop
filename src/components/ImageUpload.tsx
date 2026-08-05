'use client'

import { useRef, useState } from 'react'

import { Button, Spinner } from '@/components/ui'
import { createClient } from '@/lib/supabase/client'

/**
 * Uploadt een afbeelding als WebP.
 *
 * De conversie gebeurt in de browser, vóór het uploaden. Drie redenen:
 *  1. Een foto van 4 MB uit een telefooncamera wordt zo'n 60 kB. Dat scheelt
 *     je bezoekers laadtijd en jou bandbreedte.
 *  2. Je hebt geen serverfunctie nodig die met beeldbewerking in de weer gaat.
 *  3. De opslag accepteert alleen image/webp, dus er kan nooit per ongeluk een
 *     onbewerkte 12-megapixel JPEG in terechtkomen.
 *
 * Het formaat wordt vierkant bijgesneden vanuit het midden — logo's en
 * profielfoto's worden overal rond of vierkant getoond.
 */
export default function ImageUpload({
  kind,
  ownerId,
  currentUrl,
  label,
  size = 512,
  onUploaded,
}: {
  kind: 'shops' | 'barbers'
  ownerId: string
  currentUrl: string | null
  label: string
  size?: number
  onUploaded: (publicUrl: string) => Promise<void> | void
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [preview, setPreview] = useState<string | null>(currentUrl)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleFile(file: File) {
    setError(null)

    if (!file.type.startsWith('image/')) {
      setError('Kies een afbeelding.')
      return
    }
    // Ruime bovengrens vóór de conversie; daarna is alles klein.
    if (file.size > 20 * 1024 * 1024) {
      setError('Deze afbeelding is groter dan 20 MB.')
      return
    }

    setBusy(true)
    try {
      const webp = await toSquareWebp(file, size)
      if (webp.size > 2 * 1024 * 1024) {
        setError('Conversie leverde een te groot bestand op. Probeer een andere foto.')
        return
      }

      const supabase = createClient()
      // Vaste bestandsnaam met cache-buster in de URL: zo blijft er per salon
      // of kapper precies één bestand staan in plaats van een groeiende berg.
      const path = `${kind}/${ownerId}/image.webp`

      const { error: uploadError } = await supabase.storage
        .from('media')
        .upload(path, webp, { contentType: 'image/webp', upsert: true })

      if (uploadError) {
        setError(
          uploadError.message.includes('row-level security')
            ? 'Je hebt geen rechten om hier een afbeelding te plaatsen.'
            : 'Uploaden lukte niet. Probeer het nog eens.',
        )
        return
      }

      const { data } = supabase.storage.from('media').getPublicUrl(path)
      const url = `${data.publicUrl}?v=${Date.now()}`

      setPreview(url)
      await onUploaded(url)
    } catch {
      setError('Deze afbeelding kon niet verwerkt worden.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div>
      <span className="mb-1.5 block text-sm font-medium text-ink-100">{label}</span>

      <div className="flex items-center gap-4">
        <div className="h-20 w-20 shrink-0 overflow-hidden rounded-[14px] border border-ink-700 bg-ink-850">
          {preview ? (
            // Bewust <img> en geen next/image: de bron is een Supabase-URL met
            // cache-buster en de afmeting staat al vast na conversie.
            // eslint-disable-next-line @next/next/no-img-element
            <img src={preview} alt="" className="h-full w-full object-cover" />
          ) : (
            <div className="flex h-full w-full items-center justify-center text-xs text-ink-400">
              —
            </div>
          )}
        </div>

        <div>
          <input
            ref={inputRef}
            type="file"
            accept="image/*"
            className="hidden"
            onChange={(e) => {
              const file = e.target.files?.[0]
              if (file) void handleFile(file)
              e.target.value = ''
            }}
          />
          <Button
            type="button"
            variant="ghost"
            size="sm"
            disabled={busy}
            onClick={() => inputRef.current?.click()}
          >
            {preview ? 'Vervangen' : 'Uploaden'}
          </Button>
          <p className="mt-1.5 text-xs text-ink-400">
            JPG, PNG of HEIC. Wordt automatisch omgezet naar WebP van {size}×{size}.
          </p>
          {busy && (
            <p className="mt-1">
              <Spinner label="Verwerken…" />
            </p>
          )}
          {error && <p className="mt-1 text-xs text-danger-500">{error}</p>}
        </div>
      </div>
    </div>
  )
}

/**
 * Schaalt en snijdt bij naar een vierkant en levert WebP.
 * createImageBitmap houdt rekening met de EXIF-oriëntatie, zodat foto's van een
 * telefoon niet gekanteld binnenkomen.
 */
async function toSquareWebp(file: File, size: number): Promise<Blob> {
  const bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' })

  const side = Math.min(bitmap.width, bitmap.height)
  const sx = (bitmap.width - side) / 2
  const sy = (bitmap.height - side) / 2

  const canvas = document.createElement('canvas')
  canvas.width = size
  canvas.height = size

  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('canvas niet beschikbaar')

  ctx.imageSmoothingQuality = 'high'
  ctx.drawImage(bitmap, sx, sy, side, side, 0, 0, size, size)
  bitmap.close()

  const blob = await new Promise<Blob | null>((resolve) =>
    canvas.toBlob(resolve, 'image/webp', 0.85),
  )
  if (!blob) throw new Error('conversie mislukt')
  return blob
}
