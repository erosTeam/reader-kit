/** A tap location in both component and window coordinates. */
export class ReaderTapPoint {
  x: number
  y: number
  windowX: number
  windowY: number
  constructor(x: number, y: number, windowX: number, windowY: number) {
    this.x = x; this.y = y; this.windowX = windowX; this.windowY = windowY
  }
}

/** One owner per interactive image. A second down within the configured window
 * claims the pending single; scrolling, pinch, navigation and disposal cancel it. */
export class ReaderTapArbiter {
  private pending: ReaderTapPoint | null = null
  private timer: number = 0
  private releasedAt: number = 0
  private interval: number = 300
  private secondDown: boolean = false
  private single: (point: ReaderTapPoint) => void
  private double: (point: ReaderTapPoint) => void

  constructor(single: (point: ReaderTapPoint) => void, double: (point: ReaderTapPoint) => void) {
    this.single = single; this.double = double
  }

  down(x: number, y: number): void {
    const pending = this.pending
    if (pending === null || this.secondDown) return
    const dx = x - pending.x, dy = y - pending.y
    if (Date.now() - this.releasedAt <= this.interval && dx * dx + dy * dy <= 60 * 60) {
      if (this.timer !== 0) clearTimeout(this.timer)
      this.timer = 0
      this.secondDown = true
    } else {
      this.emitSingle()
    }
  }

  tap(point: ReaderTapPoint, doubleEnabled: boolean, interval: number): void {
    if (!doubleEnabled) {
      this.cancel()
      this.single(point)
      return
    }
    if (this.pending !== null && this.secondDown) {
      this.cancel()
      this.double(point)
      return
    }
    if (this.pending !== null) this.emitSingle()
    this.pending = point
    this.interval = Number.isFinite(interval) ? Math.max(1, Math.round(interval)) : 300
    this.releasedAt = Date.now()
    this.timer = setTimeout((): void => { this.emitSingle() }, this.interval)
  }

  cancel(): void {
    if (this.timer !== 0) clearTimeout(this.timer)
    this.timer = 0; this.pending = null; this.secondDown = false
  }

  private emitSingle(): void {
    const pending = this.pending
    this.cancel()
    if (pending !== null) this.single(pending)
  }
}
