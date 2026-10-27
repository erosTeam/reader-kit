export type ReaderBoundaryDirection = 'previous' | 'next'
export type ReaderBoundaryAxis = 'horizontal' | 'vertical'
export type ReaderBoundaryReadingDirection = 'ltr' | 'rtl'

/**
 * Recognizes one explicit swipe that starts at a unit boundary.
 *
 * Swiper owns paged motion. A paged boundary consumes its native drag offset;
 * the touch coordinates only establish the distance and axis of that gesture.
 * Continuous List keeps its own vertical boundary handling.
 */
export class ReaderBoundarySwipe {
  private startX: number = 0
  private startY: number = 0
  private previousAvailable: boolean = false
  private nextAvailable: boolean = false
  private tracking: boolean = false
  private nativeOffset: number = 0

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
    this.nativeOffset = 0
  }

  /** Called only from the current native Swiper's gesture callback. */
  observeNative(offset: number): void {
    if (this.tracking && Number.isFinite(offset)) this.nativeOffset = offset
  }

  finish(x: number, y: number, axis: ReaderBoundaryAxis,
    readingDirection: ReaderBoundaryReadingDirection = 'ltr'): ReaderBoundaryDirection | null {
    return this.finishWithOffset(x, y, axis, readingDirection, false)
  }

  finishNative(x: number, y: number, axis: ReaderBoundaryAxis,
    readingDirection: ReaderBoundaryReadingDirection = 'ltr'): ReaderBoundaryDirection | null {
    return this.finishWithOffset(x, y, axis, readingDirection, true)
  }

  private finishWithOffset(x: number, y: number, axis: ReaderBoundaryAxis,
    readingDirection: ReaderBoundaryReadingDirection, native: boolean): ReaderBoundaryDirection | null {
    if (!this.tracking || !Number.isFinite(x) || !Number.isFinite(y)) {
      this.cancel()
      return null
    }
    const deltaX = x - this.startX
    const deltaY = y - this.startY
    const physical = axis === 'vertical' ? deltaY : deltaX
    const main = native ? this.nativeOffset : physical
    const cross = axis === 'vertical' ? deltaX : deltaY
    const previousAvailable = this.previousAvailable
    const nextAvailable = this.nextAvailable
    this.cancel()
    if (main === 0 || Math.abs(physical) < 48 || Math.abs(physical) < Math.abs(cross) * 1.2) return null
    const next = axis === 'vertical' ? main < 0 : readingDirection === 'rtl' ? main > 0 : main < 0
    if (next && nextAvailable) return 'next'
    if (!next && previousAvailable) return 'previous'
    return null
  }
}
