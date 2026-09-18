/** A small finger travel is still a tap; anything more is a drag/pinch/pan tail. */
export const READER_TAP_MOVE_TOLERANCE: number = 8

/**
 * A tap belongs to a fresh single-pointer sequence that never moved past the tap
 * tolerance and is never the tail of a pinch or pan. ArkUI's default tap distance
 * threshold only fails once the finger leaves the component hot region, so a
 * cross-axis drag inside a full-bleed viewport would otherwise be reported as a
 * tap. The legacy readers each suppress the tap themselves once the finger travels
 * past a small tolerance; this keeps the shared reader equivalent.
 */
export class ReaderTapSequence {
  private suppressed: boolean = false
  private moved: boolean = false
  private startX: number = 0
  private startY: number = 0

  touch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.suppressed = event.touches.length !== 1
      this.moved = false
      const point = event.touches[0]
      if (point !== undefined && !this.suppressed) {
        this.startX = point.x
        this.startY = point.y
      }
      return
    }
    if (event.type === TouchType.Move) {
      if (this.suppressed || this.moved) return
      const point = event.touches[0] ?? event.changedTouches[0]
      if (point === undefined) return
      const dx = point.x - this.startX
      const dy = point.y - this.startY
      if (dx * dx + dy * dy > READER_TAP_MOVE_TOLERANCE * READER_TAP_MOVE_TOLERANCE) this.moved = true
      return
    }
    if (event.type === TouchType.Cancel) this.moved = true
  }

  suppress(): void { this.suppressed = true }
  allowed(): boolean { return !this.suppressed && !this.moved }
}
