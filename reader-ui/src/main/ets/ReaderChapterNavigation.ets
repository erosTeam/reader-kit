import { ReaderUnitKey } from '@reader-kit/core'

export type ReaderChapterDirection = 'previous' | 'next'
export type ReaderChapterRequestOrigin = 'explicit' | 'boundary'

/**
 * Optional host-owned chapter continuation capability.
 *
 * reader-kit decides when a chapter boundary is current and actionable. The
 * host remains responsible for resolving, loading, persisting, and presenting
 * the target chapter.
 */
export class ReaderChapterNavigation {
  readonly busy: boolean
  private readonly onRequest: (direction: ReaderChapterDirection, source: ReaderUnitKey,
    origin: ReaderChapterRequestOrigin) => void

  constructor(busy: boolean = false,
    onRequest: (direction: ReaderChapterDirection, source: ReaderUnitKey,
      origin: ReaderChapterRequestOrigin) => void = () => {}) {
    this.busy = busy
    this.onRequest = onRequest
  }

  request(direction: ReaderChapterDirection, source: ReaderUnitKey,
    origin: ReaderChapterRequestOrigin = 'explicit'): void {
    this.onRequest(direction, source.copy(), origin)
  }
}
