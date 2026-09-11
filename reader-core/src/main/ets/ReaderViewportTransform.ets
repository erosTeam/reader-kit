/** Platform-free fitted-content geometry. Coordinates and extents use the same unit. */
export class ReaderViewportGeometry {
  width: number
  height: number
  contentWidth: number
  contentHeight: number
  nativeScale: number
  contentCenterX: number
  constructor(
    width: number, height: number, contentWidth: number, contentHeight: number, nativeScale: number = 2,
    contentCenterX: number = 0,
  ) {
    this.width = width
    this.height = height
    this.contentWidth = contentWidth
    this.contentHeight = contentHeight
    this.nativeScale = nativeScale
    this.contentCenterX = contentCenterX
  }

  maxScale(): number { return Math.min(12, Math.max(4, this.nativeScale * 2)) }
}

/** A value, not a second reading-session or persistent progress owner. */
export class ReaderViewportTransform {
  scale: number
  x: number
  y: number
  constructor(scale: number = 1, x: number = 0, y: number = 0) {
    this.scale = scale
    this.x = x
    this.y = y
  }

  zoomed(): boolean { return this.scale > 1.01 }

  static clampOffset(value: number, viewport: number, content: number, scale: number): number {
    const limit = Math.max(0, (content * scale - viewport) / 2)
    return Math.max(-limit, Math.min(limit, value))
  }

  constrained(geometry: ReaderViewportGeometry): ReaderViewportTransform {
    const left = geometry.contentCenterX - geometry.contentWidth / 2
    const right = geometry.contentCenterX + geometry.contentWidth / 2
    const minX = Math.min(0, geometry.width / 2 - right * this.scale)
    const maxX = Math.max(0, -geometry.width / 2 - left * this.scale)
    return new ReaderViewportTransform(this.scale,
      Math.max(minX, Math.min(maxX, this.x)),
      ReaderViewportTransform.clampOffset(this.y, geometry.height, geometry.contentHeight, this.scale))
  }

  /** Keep the original content point under a moving viewport-local focal point. */
  zoom(geometry: ReaderViewportGeometry, target: number, startX: number, startY: number,
    centerX: number = startX, centerY: number = startY, elastic: boolean = false): ReaderViewportTransform {
    if (!Number.isFinite(target)) return new ReaderViewportTransform()
    const scale = target >= 1 ? Math.min(geometry.maxScale(), target) :
      elastic ? Math.max(0.8, 1 - (1 - target) * 0.35) : 1
    const ratio = scale / this.scale
    const x = centerX - geometry.width / 2 - (startX - geometry.width / 2 - this.x) * ratio
    const y = centerY - geometry.height / 2 - (startY - geometry.height / 2 - this.y) * ratio
    return new ReaderViewportTransform(scale, x, y).constrained(geometry)
  }

  pan(geometry: ReaderViewportGeometry, dx: number, dy: number): ReaderViewportTransform {
    if (!this.zoomed()) return this.settled(geometry)
    return new ReaderViewportTransform(this.scale, this.x + dx, this.y + dy).constrained(geometry)
  }

  settled(geometry: ReaderViewportGeometry): ReaderViewportTransform {
    return this.zoomed() ? this.constrained(geometry) : new ReaderViewportTransform()
  }

  /** Preserve content-relative translation when the same image is laid out at a new size. */
  reflow(previous: ReaderViewportGeometry, next: ReaderViewportGeometry): ReaderViewportTransform {
    if (!this.zoomed()) return new ReaderViewportTransform()
    return new ReaderViewportTransform(this.scale,
      this.x * next.contentWidth / Math.max(1, previous.contentWidth),
      this.y * next.contentHeight / Math.max(1, previous.contentHeight)).constrained(next)
  }

  doubleTapScale(geometry: ReaderViewportGeometry, pinchAdjusted: boolean): number {
    if (pinchAdjusted && this.zoomed()) return 1
    if (!this.zoomed()) return 2
    const native = Math.max(1, Math.min(geometry.maxScale(), geometry.nativeScale))
    if (Math.abs(this.scale - 2) <= 0.02 && native > 1.02 && Math.abs(native - 2) > 0.02) return native
    return 1
  }
}
