import { image } from '@kit.ImageKit'
import { FrameCallback, UIUtils } from '@kit.ArkUI'
import { ReaderEntryRect, ReaderEntryTransition } from './ReaderEntryTransition'

/** Host-owned snapshot of the displayed thumbnail. Its pixels do not claim original coverage. */
export class ReaderEntryPreviewSource {
  private released: boolean = false
  pixels: image.PixelMap
  rect: ReaderEntryRect
  constructor(pixels: image.PixelMap, rect: ReaderEntryRect) { this.pixels = pixels; this.rect = rect }
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
    if (this.entry.phase === 'layout') {
      const destination = target.contentRect
      this.destination = destination.copy()
      const scale = Math.min(destination.width / this.source.rect.width, destination.height / this.source.rect.height)
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
          this.x = destination.x - this.origin.x + (destination.width - this.source.rect.width * scale) / 2
          this.y = destination.y - this.origin.y + (destination.height - this.source.rect.height * scale) / 2
        })
      })
    } else if (this.entry.phase === 'waiting' && target.decodedReady) {
      const epoch = ++this.epoch
      this.getUIContext().animateTo({ duration: 140, curve: Curve.Linear,
        onFinish: (): void => {
          if (this.mounted && epoch === this.epoch) this.entry.finish()
        },
      }, (): void => {
        UIUtils.applySync((): void => { this.entry.reveal(); this.previewOpacity = 0 })
      })
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.entry.pending()) {
        Image(this.source.pixels)
          .width(this.source.rect.width).height(this.source.rect.height)
          .objectFit(ImageFit.Contain)
          .scale({ x: this.previewScale, y: this.previewScale, centerX: 0, centerY: 0 })
          .translate({ x: this.x, y: this.y })
          .opacity(this.previewOpacity)
          .id('rkit-entry-preview-image')
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
