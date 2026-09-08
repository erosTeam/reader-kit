import { ReaderDisplayPart } from './ReaderDisplayMap'

/** Insets refer to the current body asset, never to a thumbnail or a re-sized page. */
export class ReaderImageCropBounds {
  left: number
  top: number
  right: number
  bottom: number

  constructor(left: number = 0, top: number = 0, right: number = 0, bottom: number = 0) {
    this.left = ReaderImageCropBounds.inset(left)
    this.top = ReaderImageCropBounds.inset(top)
    this.right = ReaderImageCropBounds.inset(right)
    this.bottom = ReaderImageCropBounds.inset(bottom)
  }

  private static inset(value: number): number {
    return Number.isFinite(value) ? Math.max(0, Math.min(0.49, value)) : 0
  }

  copy(): ReaderImageCropBounds { return new ReaderImageCropBounds(this.left, this.top, this.right, this.bottom) }
  applied(): boolean { return this.left > 0 || this.top > 0 || this.right > 0 || this.bottom > 0 }

  /** Page indices are zero-based. Internal continuous seams must stay intact. */
  forContinuousPage(index: number, count: number): ReaderImageCropBounds {
    return new ReaderImageCropBounds(this.left, index === 0 ? this.top : 0,
      this.right, count > 0 && index === count - 1 ? this.bottom : 0)
  }

  region(part: ReaderDisplayPart): ReaderImageCropRegion {
    const left = Math.max(this.left, part.left())
    const right = Math.min(1 - this.right, part.left() + part.width())
    return new ReaderImageCropRegion(left, this.top, right - left, 1 - this.top - this.bottom)
  }
}

/** Mapping between visible content and original-page coordinates; topology is unchanged. */
export class ReaderImageCropRegion {
  x: number
  y: number
  width: number
  height: number
  constructor(x: number, y: number, width: number, height: number) {
    this.x = x; this.y = y; this.width = width; this.height = height
  }
  sourceX(local: number): number { return this.x + Math.max(0, Math.min(1, local)) * this.width }
  sourceY(local: number): number { return this.y + Math.max(0, Math.min(1, local)) * this.height }
  localX(source: number): number { return Math.max(0, Math.min(1, (source - this.x) / this.width)) }
  localY(source: number): number { return Math.max(0, Math.min(1, (source - this.y) / this.height)) }
}

/** Host detection/cache owner, bound to one resolved asset version. Failure leaves the body readable. */
export interface ReaderImageCropSource {
  read(): Promise<ReaderImageCropBounds>
}
