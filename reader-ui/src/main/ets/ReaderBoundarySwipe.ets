export type ReaderBoundaryDirection = 'previous' | 'next'
export type ReaderBoundaryAxis = 'horizontal' | 'vertical'
export type ReaderBoundaryReadingDirection = 'ltr' | 'rtl'

/**
 * Recognizes one explicit swipe that starts at a unit boundary.
 *
 * This is deliberately independent from ArkUI gesture recognizers: Swiper/List
 * keep native ownership of paging and scrolling, while the host receives only
 * a semantic unit-boundary intent after the native surface cannot move farther.
 */
export class ReaderBoundarySwipe {
  private startX: number = 0
  private startY: number = 0
  private previousAvailable: boolean = false
  private nextAvailable: boolean = false
  private tracking: boolean = false

  begin(x: number, y: number, previousAvailable: boolean, nextAvailable: boolean): void {
    this.cancel()
    if (!Number.isFinite(x) || !Number.isFinite(y) || (!previousAvailable && !nextAvailable)) return
    this.startX = x
    this.startY = y
    this.previousAvailable = previousAvailable
    this.nextAvailable = nextAvailable
    this.tracking = true
  }

  cancel(): void {
    this.tracking = false
    this.previousAvailable = false
    this.nextAvailable = false
  }

  finish(x: number, y: number, axis: ReaderBoundaryAxis,
    readingDirection: ReaderBoundaryReadingDirection = 'ltr'): ReaderBoundaryDirection | null {
    if (!this.tracking || !Number.isFinite(x) || !Number.isFinite(y)) {
      this.cancel()
      return null
    }
    const deltaX = x - this.startX
    const deltaY = y - this.startY
    const main = axis === 'vertical' ? deltaY : deltaX
    const cross = axis === 'vertical' ? deltaX : deltaY
    const previousAvailable = this.previousAvailable
    const nextAvailable = this.nextAvailable
    this.cancel()
    if (Math.abs(main) < 48 || Math.abs(main) < Math.abs(cross) * 1.2) return null
    const next = axis === 'vertical' ? main < 0 : readingDirection === 'rtl' ? main > 0 : main < 0
    if (next && nextAvailable) return 'next'
    if (!next && previousAvailable) return 'previous'
    return null
  }
}
