import { ReaderObservedPosition, ReaderReadingAnchor } from '@reader-kit/core'

/**
 * Optional host-owned destination for native-visible reading progress.
 *
 * reader-kit reports immutable snapshots only. The host decides whether the
 * observation updates persistence, chapter state, UI state, or nothing.
 */
export class ReaderObservationSink {
  private readonly onAnchor: ((anchor: ReaderReadingAnchor) => void) | null
  private readonly onPosition: ((position: ReaderObservedPosition) => void) | null

  constructor(onAnchor: ((anchor: ReaderReadingAnchor) => void) | null = null,
    onPosition: ((position: ReaderObservedPosition) => void) | null = null) {
    this.onAnchor = onAnchor
    this.onPosition = onPosition
  }

  observeAnchor(anchor: ReaderReadingAnchor): void {
    this.onAnchor?.(anchor.copy())
  }

  observePosition(position: ReaderObservedPosition): void {
    this.onPosition?.(position.copy())
  }
}
