import { ReaderPagedSnapshot, ReaderPagedFrame, ReaderDisplayPart, ReaderSnapshot, ReaderUnitKey, ReaderFragment } from '@reader-kit/core'
import { ReaderViewportGeometry, ReaderViewportTransform } from '@reader-kit/core'

function partRatio(frame: ReaderPagedFrame): number {
  const page = frame.asset.page
  const width = frame.asset.kind === 'thumbnail' ? page?.thumbnail.width ?? 0 : page?.width ?? 0
  const height = frame.asset.kind === 'thumbnail' ? page?.thumbnail.height ?? 0 : page?.height ?? 0
  const fraction = frame.asset.kind === 'original' ? frame.part.width() : 1
  return width > 0 && height > 0 ? width / height * fraction : 0.75
}

/** Selected display-item rendering only; no app navigation, settings or progress owner. */
@ComponentV2
export struct ReaderPagedViewport {
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Local private viewportWidth: number = 1
  @Local private viewportHeight: number = 1
  @Local private zoomState: ReaderViewportTransform = new ReaderViewportTransform()
  @Local private zoomAnimating: boolean = false
  private transformIdentity: string = ''
  private gestureIdentity: string = ''
  private pinchStart: ReaderViewportTransform = new ReaderViewportTransform()
  private panStart: ReaderViewportTransform = new ReaderViewportTransform()
  private pinchX: number = 0
  private pinchY: number = 0
  private pinching: boolean = false
  private panning: boolean = false
  private ignorePan: boolean = false
  private pinchAdjusted: boolean = false
  private animationTimer: number = 0

  private identity(): string {
    return `${this.snapshot.kind}:${this.snapshot.policy.layout}:${this.snapshot.policy.direction}:` +
      this.snapshot.frames.map((frame: ReaderPagedFrame) =>
        `${frame.slotId}:${frame.asset.assetRequestId}:${frame.part.fragment}`).join('|')
  }

  @Monitor('snapshot', 'active')
  onContentChanged(): void {
    const identity = this.identity()
    if (identity !== this.transformIdentity) {
      this.cancelGesture()
      this.transformIdentity = identity
      this.zoomState = new ReaderViewportTransform()
      this.pinchAdjusted = false
    } else if (!this.gesturesEnabled()) {
      this.cancelGesture()
      this.zoomState = this.zoomState.settled(this.geometry())
    } else {
      this.zoomState = this.zoomState.constrained(this.geometry())
    }
  }

  aboutToDisappear(): void { this.cancelGesture() }

  private gesturesEnabled(): boolean {
    return this.active && this.snapshot.phase === 'ready' && this.snapshot.frames.length > 0 &&
      this.snapshot.frames.every((frame: ReaderPagedFrame) => frame.asset.phase === 'displayed')
  }

  private stopAnimation(): void {
    if (this.animationTimer !== 0) clearTimeout(this.animationTimer)
    this.animationTimer = 0
    this.zoomAnimating = false
  }

  private cancelGesture(): void {
    this.stopAnimation()
    this.gestureIdentity = ''
    this.pinching = false
    this.panning = false
    this.ignorePan = true
  }

  private geometry(): ReaderViewportGeometry {
    const height = this.frameHeight()
    const scales = this.snapshot.frames.map((frame: ReaderPagedFrame): number => {
      const intrinsicHeight = frame.asset.kind === 'original' ? frame.asset.page?.height ?? 0 :
        frame.asset.page?.thumbnail.height ?? 0
      return intrinsicHeight > 0 ? intrinsicHeight / height : 2
    })
    return new ReaderViewportGeometry(this.viewportWidth, this.viewportHeight,
      height * this.totalRatio(), height, Math.max(1, ...scales))
  }

  private logTransform(action: string): void {
    console.info(`[ReaderViewport] action=${action} selection=${this.snapshot.selectionId} scale=${this.zoomState.scale.toFixed(3)} x=${this.zoomState.x.toFixed(2)} y=${this.zoomState.y.toFixed(2)}`)
  }

  private doubleTap(event?: GestureEvent): void {
    if (!this.gesturesEnabled() || this.pinching || event === undefined) return
    this.cancelGesture()
    const geometry = this.geometry()
    const target = this.zoomState.doubleTapScale(geometry, this.pinchAdjusted)
    this.pinchAdjusted = false
    this.zoomAnimating = true
    this.zoomState = target === 1 ? new ReaderViewportTransform() :
      this.zoomState.zoom(geometry, target,
        event.tapLocation?.x ?? geometry.width / 2, event.tapLocation?.y ?? geometry.height / 2)
    this.animationTimer = setTimeout((): void => {
      this.animationTimer = 0
      this.zoomAnimating = false
      this.logTransform('double-tap')
    }, 180)
  }

  private beginPinch(event?: GestureEvent): void {
    if (!this.gesturesEnabled() || event === undefined) return
    this.stopAnimation()
    this.gestureIdentity = this.identity()
    this.pinching = true
    this.panning = false
    this.ignorePan = true
    this.pinchStart = this.zoomState
    this.pinchX = event.pinchCenterX
    this.pinchY = event.pinchCenterY
  }

  private updatePinch(event?: GestureEvent): void {
    if (!this.pinching || !this.gesturesEnabled() || event === undefined || this.gestureIdentity !== this.identity()) return
    this.pinchAdjusted = true
    this.zoomState = this.pinchStart.zoom(this.geometry(), this.pinchStart.scale * event.scale,
      this.pinchX, this.pinchY, event.pinchCenterX, event.pinchCenterY, true)
  }

  private endPinch(): void {
    if (!this.pinching) return
    this.pinching = false
    this.zoomState = this.zoomState.settled(this.geometry())
    this.logTransform('pinch')
  }

  private beginPan(): void {
    this.ignorePan = this.pinching || !this.gesturesEnabled() || !this.zoomState.zoomed()
    this.panning = !this.ignorePan
    if (!this.panning) return
    this.stopAnimation()
    this.gestureIdentity = this.identity()
    this.panStart = this.zoomState
  }

  private updatePan(event?: GestureEvent): void {
    if (!this.panning || this.ignorePan || this.pinching || !this.gesturesEnabled() ||
      event === undefined || this.gestureIdentity !== this.identity()) return
    this.zoomState = this.panStart.pan(this.geometry(), event.offsetX, event.offsetY)
  }

  private endPan(): void {
    if (this.panning && !this.ignorePan) this.logTransform('pan')
    this.panning = false
  }

  private totalRatio(): number {
    return Math.max(0.01, this.snapshot.frames.reduce((sum: number, frame: ReaderPagedFrame) => sum + partRatio(frame), 0))
  }

  private frameHeight(): number { return Math.min(this.viewportHeight, this.viewportWidth / this.totalRatio()) }

  build() {
    Stack() {
      Row() {
        ForEach(this.snapshot.frames, (frame: ReaderPagedFrame) => {
          // Only stable identity comes from the ForEach closure. Cell state is
          // resolved from the current snapshot so same-key updates are not lost.
          ReaderPagedCell({
            snapshot: this.snapshot, slotId: frame.slotId,
            assetRequestId: frame.asset.assetRequestId,
            renderedFragment: frame.part.fragment,
            frameHeight: this.frameHeight(), active: this.active && !this.zoomAnimating && this.zoomState.scale === 1,
            onPresented: this.onPresented, onVisible: this.onVisible, onFailed: this.onFailed,
          })
        }, (frame: ReaderPagedFrame): string => `${frame.slotId}:${frame.asset.assetRequestId}:${frame.part.fragment}`)
      }
      .direction(Direction.Ltr)
      .width(this.frameHeight() * this.totalRatio())
      .height(this.frameHeight())
      .scale({ x: this.zoomState.scale, y: this.zoomState.scale })
      .translate({ x: this.zoomState.x, y: this.zoomState.y })
      .animation({ duration: this.zoomAnimating ? 180 : 0, curve: Curve.FastOutSlowIn })
      if (this.snapshot.phase === 'catalog') {
        LoadingProgress().width(32).height(32)
      }
    }
    .alignContent(Alignment.Center)
    .width('100%').height('100%')
    .clip(true)
    .id('rkit-image-viewport')
    .onAreaChange((_old: Area, area: Area): void => {
      this.cancelGesture()
      this.viewportWidth = Math.max(1, Number(area.width))
      this.viewportHeight = Math.max(1, Number(area.height))
      this.zoomState = this.zoomState.settled(this.geometry())
    })
    .gesture(GestureGroup(GestureMode.Parallel,
      TapGesture({ count: 2, distanceThreshold: 8 })
        .onAction((event?: GestureEvent): void => { this.doubleTap(event) }),
      PinchGesture({ fingers: 2 })
        .onActionStart((event?: GestureEvent): void => { this.beginPinch(event) })
        .onActionUpdate((event?: GestureEvent): void => { this.updatePinch(event) })
        .onActionEnd((): void => { this.endPinch() })
        .onActionCancel((): void => { this.endPinch() }),
      PanGesture({ fingers: 1, direction: PanDirection.All, distance: this.zoomState.zoomed() ? 1 : 10000 })
        .onActionStart((): void => { this.beginPan() })
        .onActionUpdate((event?: GestureEvent): void => { this.updatePan(event) })
        .onActionEnd((): void => { this.endPan() })
        .onActionCancel((): void => { this.endPan() }),
    ))
  }
}

@ComponentV2
struct ReaderPagedCell {
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param slotId: number
  @Require @Param assetRequestId: number
  @Require @Param renderedFragment: ReaderFragment
  @Require @Param frameHeight: number
  @Require @Param active: boolean
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}

  private frame(): ReaderPagedFrame {
    return this.snapshot.frames.find((frame: ReaderPagedFrame) => frame.slotId === this.slotId &&
      frame.asset.assetRequestId === this.assetRequestId && frame.part.fragment === this.renderedFragment) ??
      new ReaderPagedFrame(0, new ReaderDisplayPart(new ReaderUnitKey('', '', ''), null, 0), new ReaderSnapshot())
  }

  build() {
    Stack() {
      if (this.frame().asset.uri.length > 0) {
        ReaderPagedImage({
          frame: this.frame(), selectionId: this.snapshot.selectionId,
          slotId: this.slotId, assetRequestId: this.assetRequestId,
          renderedFragment: this.renderedFragment,
          active: this.active && this.snapshot.phase === 'ready',
          onPresented: this.onPresented, onVisible: this.onVisible, onFailed: this.onFailed,
        })
      }
      if (this.frame().asset.phase === 'idle' || this.frame().asset.phase === 'asset' || this.frame().asset.phase === 'decoding') {
        LoadingProgress().width(32).height(32)
      }
    }
    .width(this.frameHeight * partRatio(this.frame()))
    .height(this.frameHeight).clip(true)
    .id(`rkit-part-${this.frame().part.sourceIndex}-${this.frame().part.fragment}`)
  }
}

@ComponentV2
struct ReaderPagedImage {
  @Require @Param frame: ReaderPagedFrame
  @Require @Param slotId: number
  @Require @Param assetRequestId: number
  @Require @Param selectionId: number
  @Require @Param renderedFragment: ReaderFragment
  @Require @Param active: boolean
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Local private viewportWidth: number = 1
  @Local private viewportHeight: number = 1
  private fullyVisible: boolean = false
  private decoded: boolean = false

  @Monitor('active', 'selectionId')
  onSelectionChanged(): void { this.reportVisible() }

  private reportVisible(): void {
    if (this.active && this.fullyVisible && this.decoded && this.frame.asset.kind === 'original') {
      this.onVisible(this.selectionId, this.slotId, this.assetRequestId, this.renderedFragment)
    }
  }

  private completed(width: number, height: number): void {
    this.decoded = true
    this.onPresented(this.slotId, this.assetRequestId, true, width, height)
    this.reportVisible()
  }

  private failed(): void {
    this.decoded = false
    this.onFailed(this.selectionId, this.slotId, this.assetRequestId, this.renderedFragment)
  }

  private spriteScale(): number {
    const thumbnail = this.frame.asset.page?.thumbnail
    if (thumbnail === undefined || thumbnail.width <= 0 || thumbnail.height <= 0) return 1
    return Math.min(this.viewportWidth / thumbnail.width, this.viewportHeight / thumbnail.height)
  }

  build() {
    Stack() {
      if (this.frame.asset.kind === 'thumbnail' && this.frame.asset.page?.thumbnail.kind === 'sprite') {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(this.frame.asset.uri)
            .width(this.frame.asset.page.thumbnail.spriteWidth * this.spriteScale())
            .height(this.frame.asset.page.thumbnail.spriteHeight * this.spriteScale())
            .objectFit(ImageFit.Fill)
            .position({
              x: -this.frame.asset.page.thumbnail.offsetX * this.spriteScale(),
              y: -this.frame.asset.page.thumbnail.offsetY * this.spriteScale(),
            })
            .onComplete((event): void => {
              if (event?.loadingStatus === 1) this.completed(event.width, event.height)
            })
            .onError((): void => { this.failed() })
        }
        .width(this.frame.asset.page.thumbnail.width * this.spriteScale())
        .height(this.frame.asset.page.thumbnail.height * this.spriteScale())
        .clip(true)
      } else if (this.frame.asset.kind === 'original' && this.frame.part.fragment !== 'whole') {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(this.frame.asset.uri)
            .width(this.viewportWidth * 2).height(this.viewportHeight)
            .objectFit(ImageFit.Fill)
            .position({ x: this.frame.part.fragment === 'right' ? -this.viewportWidth : 0, y: 0 })
            .onComplete((event): void => {
              if (event?.loadingStatus === 1) this.completed(event.width, event.height)
            })
            .onError((): void => { this.failed() })
        }
        .width('100%').height('100%').clip(true)
      } else {
        Image(this.frame.asset.uri)
          .width('100%').height('100%')
          .objectFit(ImageFit.Contain)
          .onComplete((event): void => {
            if (event?.loadingStatus === 1) this.completed(event.width, event.height)
          })
          .onError((): void => { this.failed() })
      }
    }
    .width('100%').height('100%')
    .onVisibleAreaChange([0, 1], (_expanding: boolean, ratio: number): void => {
      this.fullyVisible = ratio >= 1
      this.reportVisible()
    })
    .onAreaChange((_old: Area, area: Area): void => {
      this.viewportWidth = Math.max(1, Number(area.width))
      this.viewportHeight = Math.max(1, Number(area.height))
    })
  }
}
