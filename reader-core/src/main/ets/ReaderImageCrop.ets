import { ReaderDisplayPart } from './ReaderDisplayMap'

const READER_CROP_MAX_EDGE_FRACTION: number = 0.35
const READER_CROP_MIN_RETAINED_FRACTION: number = 0.25
const READER_CROP_LINE_CONTENT_FRACTION: number = 0.01

enum ReaderImageBackgroundKind {
  NONE = 0,
  TRANSPARENT = 1,
  WHITE = 2,
  BLACK = 3,
}

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

/** Pure conservative detector shared by every host; input pixels are RGBA_8888. */
export class ReaderImageCropDetector {
  static detect(width: number, height: number, stride: number, pixels: Uint8Array): ReaderImageCropBounds {
    if (width < 4 || height < 4 || stride < width * 4 || pixels.length < stride * height) {
      return new ReaderImageCropBounds()
    }
    const maxLeft: number = Math.floor(width * READER_CROP_MAX_EDGE_FRACTION)
    const maxTop: number = Math.floor(height * READER_CROP_MAX_EDGE_FRACTION)
    const leftBackground = ReaderImageCropDetector.columnBackgroundKind(0, height, stride, pixels)
    const rightBackground = ReaderImageCropDetector.columnBackgroundKind(width - 1, height, stride, pixels)
    const topBackground = ReaderImageCropDetector.rowBackgroundKind(0, width, stride, pixels)
    const bottomBackground = ReaderImageCropDetector.rowBackgroundKind(height - 1, width, stride, pixels)
    let left: number = 0
    while (leftBackground !== ReaderImageBackgroundKind.NONE && left < maxLeft &&
      ReaderImageCropDetector.columnIsBackground(left, height, stride, pixels, leftBackground)) left++
    let right: number = width - 1
    while (rightBackground !== ReaderImageBackgroundKind.NONE && right > width - 1 - maxLeft &&
      ReaderImageCropDetector.columnIsBackground(right, height, stride, pixels, rightBackground)) right--
    let top: number = 0
    while (topBackground !== ReaderImageBackgroundKind.NONE && top < maxTop &&
      ReaderImageCropDetector.rowIsBackground(top, width, stride, pixels, topBackground)) top++
    let bottom: number = height - 1
    while (bottomBackground !== ReaderImageBackgroundKind.NONE && bottom > height - 1 - maxTop &&
      ReaderImageCropDetector.rowIsBackground(bottom, width, stride, pixels, bottomBackground)) bottom--

    if (leftBackground !== ReaderImageBackgroundKind.NONE && left >= maxLeft &&
      ReaderImageCropDetector.columnIsBackground(left, height, stride, pixels, leftBackground)) left = 0
    if (rightBackground !== ReaderImageBackgroundKind.NONE && right <= width - 1 - maxLeft &&
      ReaderImageCropDetector.columnIsBackground(right, height, stride, pixels, rightBackground)) right = width - 1
    if (topBackground !== ReaderImageBackgroundKind.NONE && top >= maxTop &&
      ReaderImageCropDetector.rowIsBackground(top, width, stride, pixels, topBackground)) top = 0
    if (bottomBackground !== ReaderImageBackgroundKind.NONE && bottom <= height - 1 - maxTop &&
      ReaderImageCropDetector.rowIsBackground(bottom, width, stride, pixels, bottomBackground)) bottom = height - 1

    if (left > 0) left--
    if (right < width - 1) right++
    if (top > 0) top--
    if (bottom < height - 1) bottom++
    if (right - left + 1 < width * READER_CROP_MIN_RETAINED_FRACTION ||
      bottom - top + 1 < height * READER_CROP_MIN_RETAINED_FRACTION) return new ReaderImageCropBounds()
    const rightInset = width - right - 1
    const bottomInset = height - bottom - 1
    if (left <= 0 && top <= 0 && rightInset <= 0 && bottomInset <= 0) return new ReaderImageCropBounds()
    return new ReaderImageCropBounds(left / width, top / height, rightInset / width, bottomInset / height)
  }

  private static pixelKind(x: number, y: number, stride: number, pixels: Uint8Array): ReaderImageBackgroundKind {
    const offset = y * stride + x * 4
    const r = pixels[offset], g = pixels[offset + 1], b = pixels[offset + 2], a = pixels[offset + 3]
    if (a <= 16) return ReaderImageBackgroundKind.TRANSPARENT
    if (r >= 235 && g >= 235 && b >= 235) return ReaderImageBackgroundKind.WHITE
    if (r <= 20 && g <= 20 && b <= 20) return ReaderImageBackgroundKind.BLACK
    return ReaderImageBackgroundKind.NONE
  }

  private static rowIsBackground(y: number, width: number, stride: number, pixels: Uint8Array,
    background: ReaderImageBackgroundKind): boolean {
    const allowedContent = Math.max(1, Math.floor(width * READER_CROP_LINE_CONTENT_FRACTION))
    let content = 0
    for (let x = 0; x < width; x++) {
      if (ReaderImageCropDetector.pixelKind(x, y, stride, pixels) !== background && ++content > allowedContent) return false
    }
    return true
  }

  private static columnIsBackground(x: number, height: number, stride: number, pixels: Uint8Array,
    background: ReaderImageBackgroundKind): boolean {
    const allowedContent = Math.max(1, Math.floor(height * READER_CROP_LINE_CONTENT_FRACTION))
    let content = 0
    for (let y = 0; y < height; y++) {
      if (ReaderImageCropDetector.pixelKind(x, y, stride, pixels) !== background && ++content > allowedContent) return false
    }
    return true
  }

  private static rowBackgroundKind(y: number, width: number, stride: number,
    pixels: Uint8Array): ReaderImageBackgroundKind {
    const allowedContent = Math.max(1, Math.floor(width * READER_CROP_LINE_CONTENT_FRACTION))
    const counts: number[] = [0, 0, 0, 0]
    for (let x = 0; x < width; x++) counts[ReaderImageCropDetector.pixelKind(x, y, stride, pixels)]++
    return ReaderImageCropDetector.backgroundKind(counts, width - allowedContent)
  }

  private static columnBackgroundKind(x: number, height: number, stride: number,
    pixels: Uint8Array): ReaderImageBackgroundKind {
    const allowedContent = Math.max(1, Math.floor(height * READER_CROP_LINE_CONTENT_FRACTION))
    const counts: number[] = [0, 0, 0, 0]
    for (let y = 0; y < height; y++) counts[ReaderImageCropDetector.pixelKind(x, y, stride, pixels)]++
    return ReaderImageCropDetector.backgroundKind(counts, height - allowedContent)
  }

  private static backgroundKind(counts: number[], required: number): ReaderImageBackgroundKind {
    for (let kind = ReaderImageBackgroundKind.TRANSPARENT; kind <= ReaderImageBackgroundKind.BLACK; kind++) {
      if (counts[kind] >= required) return kind as ReaderImageBackgroundKind
    }
    return ReaderImageBackgroundKind.NONE
  }
}
