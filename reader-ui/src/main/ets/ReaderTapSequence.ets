/** A tap belongs to a fresh single-pointer sequence, never the tail of pinch/pan. */
export class ReaderTapSequence {
  private suppressed: boolean = false

  touch(event: TouchEvent): void {
    if (event.type === TouchType.Down) this.suppressed = event.touches.length !== 1
  }

  suppress(): void { this.suppressed = true }
  allowed(): boolean { return !this.suppressed }
}
