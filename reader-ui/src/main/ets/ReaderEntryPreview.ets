import { image } from '@kit.ImageKit'
import { FrameCallback, UIUtils } from '@kit.ArkUI'
import { ReaderEntryRect, ReaderEntryTransition } from './ReaderEntryTransition'

/** Host-owned snapshot; whole-page coverage must be asserted by the producer, never inferred from its ratio. */
export class ReaderEntryPreviewSource {
  private released: boolean = false
  private departureGuard: ((entryId: number) => boolean) | null
  pixels: image.PixelMap
  rect: ReaderEntryRect
  readonly coverage: 'unknown' | 'whole-page'
  constructor(pixels: image.PixelMap, rect: ReaderEntryRect,
    departureGuard: ((entryId: number) => boolean) | null = null,
    coverage: 'unknown' | 'whole-page' = 'unknown') {
    this.pixels = pixels; this.rect = rect; this.departureGuard = departureGuard
    this.coverage = coverage
  }

  authorizeDeparture(entryId: number): boolean {
    if (this.released) return false
    try {
      const allowed = this.departureGuard === null || this.departureGuard(entryId)
      return allowed && !this.released
    } catch (_error) {
      return false
    }
  }

  release(): void {
    if (this.released) return
    this.released = true
    void this.pixels.release().catch((): void => {})
  }
}

class ReaderEntryInitialFrame extends FrameCallback {
  private ready: () => void
  constructor(ready: () => void) { super(); this.ready = ready }
  onIdle(_timeLeftInNano: number): void { this.ready() }
}

@ComponentV2
export struct ReaderEntryPreview {
  @Require @Param entry: ReaderEntryTransition
  @Require @Param source: ReaderEntryPreviewSource
  @Local private x: number = 0
  @Local private y: number = 0
  @Local private previewScale: number = 1
  @Local private previewOpacity: number = 1
  private mounted: boolean = false
  private firstFrame: boolean = false
  private origin: ReaderEntryRect = new ReaderEntryRect()
  private destination: ReaderEntryRect | null = null
  private destinationClip: ReaderEntryRect | null = null
  private epoch: number = 0

  aboutToDisappear(): void { this.mounted = false; this.epoch += 1; this.entry.cancel() }

  @Monitor('entry.target', 'entry.phase')
  advance(): void {
    if (!this.mounted || !this.firstFrame || !this.entry.pending()) return
    const target = this.entry.target
    if (target === null || !target.geometryReady || !target.contentRect.valid()) return
    const committed = this.destination
    if (committed !== null && (committed.x !== target.contentRect.x || committed.y !== target.contentRect.y ||
      committed.width !== target.contentRect.width || committed.height !== target.contentRect.height)) {
      this.entry.cancel(); return
    }
    const clip = target.clipRect
    const committedClip = this.destinationClip
    if (committed !== null && ((committedClip === null) !== (clip === null) ||
      (committedClip !== null && clip !== null && (committedClip.x !== clip.x || committedClip.y !== clip.y ||
      committedClip.width !== clip.width || committedClip.height !== clip.height)))) {
      this.entry.cancel(); return
    }
    if (this.entry.phase === 'layout') {
      const entry = this.entry
      const source = this.source
      const destination = target.contentRect
      let previewFrame = destination
      if (source.coverage === 'unknown' && clip !== null) {
        // A partial preview has no pixel correspondence with the original. Contain it in
        // the visible destination area without changing the original's measured geometry.
        const x = Math.max(destination.x, clip.x)
        const y = Math.max(destination.y, clip.y)
        previewFrame = new ReaderEntryRect(x, y,
          Math.min(destination.x + destination.width, clip.x + clip.width) - x,
          Math.min(destination.y + destination.height, clip.y + clip.height) - y)
        if (!previewFrame.valid()) { entry.cancel(); return }
      }
      if (!source.authorizeDeparture(entry.entryId)) { entry.cancel(); return }
      // The host may synchronously retire this hidden trial while authorizing its source.
      if (!this.mounted || this.entry !== entry || this.source !== source || !entry.pending() ||
        entry.phase !== 'layout' || entry.target !== target) return
      this.destination = destination.copy()
      this.destinationClip = clip?.copy() ?? null
      const scale = Math.min(previewFrame.width / this.source.rect.width, previewFrame.height / this.source.rect.height)
      const epoch = ++this.epoch
      this.entry.beginMove()
      this.getUIContext().animateTo({ duration: 280, curve: Curve.FastOutSlowIn,
        onFinish: (): void => {
          if (!this.mounted || epoch !== this.epoch || this.entry.phase !== 'moving') return
          this.getUIContext().animateTo({ duration: 140, curve: Curve.Linear }, (): void => { this.entry.arrived() })
          this.advance()
        },
      }, (): void => {
        // Monitor-driven V2 changes otherwise mark the animation end frame after animateTo has closed.
        UIUtils.applySync((): void => {
          this.previewScale = scale
          this.x = previewFrame.x - this.origin.x + (previewFrame.width - this.source.rect.width * scale) / 2
          this.y = previewFrame.y - this.origin.y + (previewFrame.height - this.source.rect.height * scale) / 2
        })
      })
    } else if (this.entry.phase === 'waiting' && target.decodedReady) {
      const epoch = ++this.epoch
      if (this.source.coverage === 'unknown') {
        // A partial preview has no proven pixel correspondence with the original.
        // Retire it in the same non-animated commit that exposes the decoded image.
        this.getUIContext().animateTo({ duration: 0 }, (): void => {
          UIUtils.applySync((): void => {
            this.entry.reveal()
            this.previewOpacity = 0
            this.entry.finish()
          })
        })
        return
      }
      this.getUIContext().animateTo({ duration: 140, curve: Curve.Linear,
        onFinish: (): void => {
          if (this.mounted && epoch === this.epoch) this.entry.finish()
        },
      }, (): void => {
        // Keep a known whole-page underlay opaque during the upper original fade.
        UIUtils.applySync((): void => {
          this.entry.reveal()
        })
      })
    }
  }

  private previewClip(): ReaderEntryRect { return this.entry.target?.clipRect ?? this.origin }

  private clipped(): boolean { return this.entry.target?.clipRect !== null && this.entry.target?.clipRect !== undefined }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.entry.pending()) {
        if (this.clipped()) {
          Stack({ alignContent: Alignment.TopStart }) {
            Image(this.source.pixels)
              .width(this.source.rect.width).height(this.source.rect.height)
              .objectFit(ImageFit.Contain)
              .scale({ x: this.previewScale, y: this.previewScale, centerX: 0, centerY: 0 })
              .translate({ x: this.x - this.previewClip().x + this.origin.x,
                y: this.y - this.previewClip().y + this.origin.y })
              .opacity(this.previewOpacity)
              .id('rkit-entry-preview-image')
          }
          .width(this.previewClip().width).height(this.previewClip().height)
          .position({ x: this.previewClip().x - this.origin.x, y: this.previewClip().y - this.origin.y })
          .clip(true)
        } else {
          Image(this.source.pixels)
          .width(this.source.rect.width).height(this.source.rect.height)
          .objectFit(ImageFit.Contain)
          .scale({ x: this.previewScale, y: this.previewScale, centerX: 0, centerY: 0 })
          .translate({ x: this.x, y: this.y })
          .opacity(this.previewOpacity)
          .id('rkit-entry-preview-image')
        }
      }
    }.width('100%').height('100%').id('rkit-entry-preview-root')
      .hitTestBehavior(HitTestMode.None)
      .onAreaChange((): void => {
        if (this.mounted) { this.entry.cancel(); return }
        const rect = this.getUIContext().getComponentUtils().getRectangleById('rkit-entry-preview-root')
        this.origin = new ReaderEntryRect(this.getUIContext().px2vp(rect.windowOffset.x),
          this.getUIContext().px2vp(rect.windowOffset.y), this.getUIContext().px2vp(rect.size.width),
          this.getUIContext().px2vp(rect.size.height))
        this.x = this.source.rect.x - this.origin.x
        this.y = this.source.rect.y - this.origin.y
        this.mounted = true
        this.getUIContext().postFrameCallback(new ReaderEntryInitialFrame((): void => {
          if (!this.mounted) return
          this.firstFrame = true; this.advance()
        }))
      })
  }
}
