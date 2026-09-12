import { ReaderPagedFrame, ReaderFragment, ReaderViewportGeometry, ReaderViewportTransform } from '@reader-kit/core'
import { ReaderPagedImage } from './ReaderPagedViewport'
import { ReaderTapSequence } from './ReaderTapSequence'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { ReaderContinuousEntryPosition } from './ReaderContinuousEntryPosition'

/** Image interaction only. The parent List owns scrolling, stacking and visible-position reporting. */
@ComponentV2
export struct ReaderContinuousZoomImage {
  @Param entryTransition: ReaderEntryTransition | null = null
  @Param entryPosition: ReaderContinuousEntryPosition | null = null
  @Require @Param frame: ReaderPagedFrame
  @Require @Param navigation: number
  @Require @Param imageHeight: number
  @Require @Param active: boolean
  @Require @Param interactionAllowed: boolean
  @Event onTap: (windowX: number, windowY: number) => void = () => {}
  @Event onLock: (identity: string, locked: boolean) => void = () => {}
  @Event onPresented: (slot: number, request: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onFailed: (slot: number, request: number, fragment: ReaderFragment) => void = () => {}
  @Local private imageTransform: ReaderViewportTransform = new ReaderViewportTransform()
  @Local private animating: boolean = false
  private componentWidth: number = 1
  private componentHeight: number = 1
  private measuredImageHeight: number = 1
  private identity: string = ''
  private publishedIdentity: string = ''
  private publishedLock: boolean = false
  private animationTimer: number = 0
  private pinching: boolean = false
  private panning: boolean = false
  private pinchAdjusted: boolean = false
  private gestureIdentity: string = ''
  private gestureStart: ReaderViewportTransform = new ReaderViewportTransform()
  private pinchX: number = 0
  private pinchY: number = 0
  private tapSequence: ReaderTapSequence = new ReaderTapSequence()

  aboutToAppear(): void { this.onContentChanged() }

  aboutToDisappear(): void {
    this.cancelMotion()
    this.onLock(this.identity, false)
  }

  @Monitor('frame', 'navigation', 'active', 'interactionAllowed')
  onContentChanged(): void {
    const identity = `${this.navigation}:${this.frame.slotId}:${this.frame.asset.assetRequestId}`
    if (identity !== this.identity || this.frame.asset.phase !== 'displayed') {
      if (this.identity.length > 0) this.onLock(this.identity, false)
      this.cancelMotion()
      this.identity = identity
      this.imageTransform = new ReaderViewportTransform()
      this.pinchAdjusted = false
    } else if (!this.active || !this.interactionAllowed) {
      // Suspend unfinished gestures, but retain a settled zoom over Home/resume.
      this.cancelMotion()
      this.imageTransform = this.imageTransform.settled(this.geometry())
    }
    this.publishLock()
  }

  private geometry(): ReaderViewportGeometry {
    const page = this.frame.asset.page
    const pixels = this.frame.asset.kind === 'original'
      ? (page?.width ?? 0) * this.frame.crop.region(this.frame.part).width : page?.thumbnail.width ?? 0
    return new ReaderViewportGeometry(this.componentWidth, this.componentHeight, this.componentWidth, this.measuredImageHeight,
      pixels > 0 ? pixels / this.componentWidth : 2)
  }

  private canInteract(): boolean {
    return this.active && this.interactionAllowed && this.frame.asset.phase === 'displayed' && this.componentWidth > 1
  }

  private interactionRegion(): Rectangle {
    if (!this.imageTransform.zoomed()) return { x: 0, y: 0, width: '100%', height: '100%' }
    // The row stays unscaled for List positioning. Its gesture region must also
    // include the raised image where it visibly overlaps an adjacent row.
    const imageWidth = this.componentWidth * this.imageTransform.scale
    const imageHeight = this.imageHeight * this.imageTransform.scale
    const left = Math.min(0, (this.componentWidth - imageWidth) / 2 + this.imageTransform.x)
    const top = Math.min(0, (this.componentHeight - imageHeight) / 2 + this.imageTransform.y)
    const right = Math.max(this.componentWidth, (this.componentWidth + imageWidth) / 2 + this.imageTransform.x)
    const bottom = Math.max(this.componentHeight, (this.componentHeight + imageHeight) / 2 + this.imageTransform.y)
    return { x: left, y: top, width: right - left, height: bottom - top }
  }

  private publishLock(): void {
    const locked = this.imageTransform.zoomed() || this.animating || this.pinching
    if (this.identity === this.publishedIdentity && locked === this.publishedLock) return
    this.publishedIdentity = this.identity
    this.publishedLock = locked
    this.onLock(this.identity, locked)
  }

  private cancelMotion(): void {
    if (this.animationTimer !== 0) clearTimeout(this.animationTimer)
    this.animationTimer = 0
    this.animating = false
    this.pinching = false
    this.panning = false
    this.gestureIdentity = ''
  }

  private log(action: string): void {
    console.info(`[ReaderContinuousZoom] action=${action} identity=${this.identity} page=${this.frame.part.sourceIndex + 1} scale=${this.imageTransform.scale.toFixed(3)} x=${this.imageTransform.x.toFixed(2)} y=${this.imageTransform.y.toFixed(2)}`)
  }

  private doubleTap(event?: GestureEvent): void {
    if (!this.canInteract() || this.pinching || event === undefined) return
    this.cancelMotion()
    const geometry = this.geometry()
    const target = this.imageTransform.doubleTapScale(geometry, this.pinchAdjusted)
    this.pinchAdjusted = false
    this.animating = true
    this.imageTransform = target === 1 ? new ReaderViewportTransform() : this.imageTransform.zoom(geometry, target,
      event.tapLocation?.x ?? this.componentWidth / 2, event.tapLocation?.y ?? this.componentHeight / 2)
    this.publishLock()
    this.animationTimer = setTimeout((): void => {
      this.animationTimer = 0
      this.animating = false
      this.publishLock()
      this.log('double-tap')
    }, 180)
  }

  private beginPinch(event?: GestureEvent): void {
    if (!this.canInteract() || event === undefined) return
    this.tapSequence.suppress()
    this.cancelMotion()
    this.pinching = true
    this.gestureIdentity = this.identity
    this.gestureStart = this.imageTransform
    this.pinchX = event.pinchCenterX
    this.pinchY = event.pinchCenterY
    this.publishLock()
  }

  private updatePinch(event?: GestureEvent): void {
    if (!this.pinching || !this.canInteract() || event === undefined || this.gestureIdentity !== this.identity) return
    this.pinchAdjusted = true
    this.imageTransform = this.gestureStart.zoom(this.geometry(), this.gestureStart.scale * event.scale,
      this.pinchX, this.pinchY, event.pinchCenterX, event.pinchCenterY, true)
  }

  private endPinch(): void {
    if (!this.pinching) return
    this.pinching = false
    this.imageTransform = this.imageTransform.settled(this.geometry())
    this.publishLock()
    this.log('pinch')
  }

  private beginPan(): void {
    this.panning = !this.pinching && this.canInteract() && this.imageTransform.zoomed()
    if (!this.panning) return
    this.tapSequence.suppress()
    if (this.animationTimer !== 0) clearTimeout(this.animationTimer)
    this.animationTimer = 0
    this.animating = false
    this.gestureIdentity = this.identity
    this.gestureStart = this.imageTransform
    this.publishLock()
  }

  private updatePan(event?: GestureEvent): void {
    if (!this.panning || this.pinching || !this.canInteract() || event === undefined ||
      this.gestureIdentity !== this.identity) return
    this.imageTransform = this.gestureStart.pan(this.geometry(), event.offsetX, event.offsetY)
  }

  private endPan(): void {
    if (this.panning) this.log('pan')
    this.panning = false
  }

  build() {
    Stack() {
      ReaderPagedImage({
        frame: this.frame, slotId: this.frame.slotId, assetRequestId: this.frame.asset.assetRequestId,
        selectionId: 0, renderedFragment: this.frame.part.fragment, active: false,
        entryTransition: this.entryTransition, continuousEntry: this.entryPosition,
        onPresented: this.onPresented,
        onFailed: (_selection: number, slot: number, request: number, fragment: ReaderFragment): void => {
          this.onFailed(slot, request, fragment)
        },
      })
        .width('100%').height(this.imageHeight)
        .scale({ x: this.imageTransform.scale, y: this.imageTransform.scale })
        .translate({ x: this.imageTransform.x, y: this.imageTransform.y })
        .animation({ duration: this.animating ? 180 : 0, curve: Curve.FastOutSlowIn })
    }
    .width('100%').height('100%')
    .responseRegion(this.interactionRegion())
    .onTouch((event: TouchEvent): void => { this.tapSequence.touch(event) })
    .onAreaChange((_old: Area, area: Area): void => {
      const previous = this.geometry()
      const width = Math.max(1, Number(area.width))
      const changed = this.componentWidth !== width || this.measuredImageHeight !== this.imageHeight
      if (changed) {
        this.cancelMotion()
      }
      this.componentWidth = width
      this.componentHeight = Math.max(1, Number(area.height))
      this.measuredImageHeight = this.imageHeight
      this.imageTransform = changed ? this.imageTransform.reflow(previous, this.geometry()) :
        this.imageTransform.settled(this.geometry())
      this.publishLock()
      if (changed && this.imageTransform.zoomed()) this.log('reflow')
    })
    .gesture(GestureGroup(GestureMode.Parallel,
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 2, distanceThreshold: 8 }).onAction((event?: GestureEvent): void => { this.doubleTap(event) }),
        TapGesture({ count: 1 }).onAction((event?: GestureEvent): void => {
          const location = event?.tapLocation
          if (this.canInteract() && !this.pinching && this.tapSequence.allowed() && location !== undefined &&
            Number.isFinite(location.windowX) && Number.isFinite(location.windowY)) this.onTap(location.windowX, location.windowY)
        }),
      ),
      PinchGesture({ fingers: 2 })
        .onActionStart((event?: GestureEvent): void => { this.beginPinch(event) })
        .onActionUpdate((event?: GestureEvent): void => { this.updatePinch(event) })
        .onActionEnd((): void => { this.endPinch() })
        .onActionCancel((): void => { this.endPinch() }),
      PanGesture({ fingers: 1, direction: PanDirection.All, distance: this.imageTransform.zoomed() ? 1 : 10000 })
        .onActionStart((): void => { this.beginPan() })
        .onActionUpdate((event?: GestureEvent): void => { this.updatePan(event) })
        .onActionEnd((): void => { this.endPan() })
        .onActionCancel((): void => { this.endPan() }),
    ))
  }
}
