import { ReaderTapAction } from './ReaderTapAction'

/**
 * Host-provided normalized geometry for one tap-zone preview cell.
 * The host owns preference semantics; reader-kit owns only presentation.
 */
export class ReaderTapZonePreviewRegion {
  action: ReaderTapAction
  left: number
  top: number
  right: number
  bottom: number

  constructor(action: ReaderTapAction, left: number, top: number, right: number, bottom: number) {
    this.action = action
    this.left = left
    this.top = top
    this.right = right
    this.bottom = bottom
  }

  valid(): boolean {
    return this.action !== 'none' && Number.isFinite(this.left) && Number.isFinite(this.top) &&
      Number.isFinite(this.right) && Number.isFinite(this.bottom) && this.left >= 0 && this.top >= 0 &&
      this.right <= 1 && this.bottom <= 1 && this.right > this.left && this.bottom > this.top
  }

  key(): string {
    return `${this.action}-${this.left}-${this.top}-${this.right}-${this.bottom}`
  }
}
