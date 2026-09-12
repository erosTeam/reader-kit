import { ReaderPagedSnapshot, ReaderPagedFrame, ReaderDisplayPart, ReaderSnapshot, ReaderUnitKey, ReaderFragment } from '@reader-kit/core'
import { ReaderViewportGeometry, ReaderViewportTransform } from '@reader-kit/core'
import { ReaderFailurePanel } from './ReaderFailurePanel'
import { ReaderTapSequence } from './ReaderTapSequence'
import { ReaderEntryRect, ReaderEntryTarget, ReaderEntryTransition } from './ReaderEntryTransition'
import { FrameCallback } from '@kit.ArkUI'
import { ReaderContinuousEntryPosition } from './ReaderContinuousEntryPosition'

class ReaderEntryAfterLayout extends FrameCallback {
  private action: () => void
  constructor(action: () => void) { super(); this.action = action }
  onIdle(_remaining: number): void { this.action() }
}

/** One monotonic layout clock also survives a selected leaf being remounted. */
class ReaderEntryLayoutRevision {
  private static current: number = 0
  static next(previous: number): number {
    ReaderEntryLayoutRevision.current = Math.max(ReaderEntryLayoutRevision.current, previous) + 1
    return ReaderEntryLayoutRevision.current
  }
}

/** Preserve only the selected entry's measured bounds across asset delivery remounts. */
class ReaderEntryMeasurement {
  entryId: number = -1
  contentRect: ReaderEntryRect | null = null
}

function partRatio(frame: ReaderPagedFrame): number {
  const page = frame.asset.page
  const width = frame.asset.kind === 'thumbnail' ? page?.thumbnail.width ?? 0 : page?.width ?? 0
  const height = frame.asset.kind === 'thumbnail' ? page?.thumbnail.height ?? 0 : page?.height ?? 0
  const region = frame.crop.region(frame.part)
  const fraction = frame.asset.kind === 'original' ? region.width / region.height : 1
  return width > 0 && height > 0 ? width / height * fraction : 0.75
}

/** Entry eligibility only; ordinary image layout keeps its existing fallback. */
export class ReaderEntryGeometryGate {
  static dimensions(width: number, height: number): 'invalid' | 'unknown' | 'ready' {
    if (!Number.isFinite(width) || !Number.isFinite(height) || width < 0 || height < 0) return 'invalid'
    return width === 0 || height === 0 ? 'unknown' : 'ready'
  }

  static frame(frame: ReaderPagedFrame): 'invalid' | 'unknown' | 'ready' {
    if (frame.asset.phase === 'failed' || frame.asset.kind !== 'original') return 'invalid'
    const page = frame.asset.page
    if (page === null) return 'unknown'
    const state = ReaderEntryGeometryGate.dimensions(page.width, page.height)
    if (state !== 'ready') return state
    return Number.isFinite(partRatio(frame)) && partRatio(frame) > 0 ? 'ready' : 'invalid'
  }

  static ready(frames: ReaderPagedFrame[]): boolean {
    return frames.length > 0 && frames.every((frame: ReaderPagedFrame) => ReaderEntryGeometryGate.frame(frame) === 'ready')
  }

  static cancel(frames: ReaderPagedFrame[], phase: string): boolean {
    return frames.some((frame: ReaderPagedFrame) => {
      const state = ReaderEntryGeometryGate.frame(frame)
      return state === 'invalid' || (state === 'unknown' && phase !== 'layout')
    })
  }

  /** A terminal decode without dimensions cancels only the still-current selected entry. */
  static invalidDecoded(entry: ReaderEntryTransition, snapshot: ReaderPagedSnapshot,
    slotId: number, requestId: number, assetRequestId: number): void {
    if (!entry.pending() || requestId <= 0 || assetRequestId <= 0 ||
      !snapshot.frames.some((frame: ReaderPagedFrame) => frame.slotId === slotId &&
      frame.asset.kind === 'original' && frame.asset.requestId === requestId &&
      frame.asset.assetRequestId === assetRequestId)) return
    const source = snapshot.frames.find((frame: ReaderPagedFrame) => entry.matches(frame.part))
    if (source === undefined) return
    const target = new ReaderEntryTarget(source.part)
    target.selectionId = snapshot.selectionId
    target.topologyRevision = snapshot.topologyRevision
    target.navigationRevision = snapshot.navigationRevision
    target.slotId = source.slotId
    target.requestId = source.asset.requestId
    target.assetRequestId = source.asset.assetRequestId
    target.layoutRevision = ReaderEntryLayoutRevision.next(entry.target?.layoutRevision ?? 0)
    // No geometry or image failure is invented. Publication uses the existing live-identity fence.
    entry.publishTarget(target)
    if (entry.target?.layoutRevision === target.layoutRevision) entry.cancel()
  }
}

/** Selected display-item rendering only; no app navigation, settings or progress owner. */
@ComponentV2
export struct ReaderPagedViewport {
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Param entryTransition: ReaderEntryTransition | null = null
  @Param selected: boolean = true
  @Event onTap: (xFraction: number) => void = () => {}
  @Event onInputLockChange: (locked: boolean) => void = () => {}
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (slotId: number, requestId: number) => void = () => {}
  @Local private viewportWidth: number = 1
  @Local private viewportHeight: number = 1
  @Local private entryViewportLaidOut: boolean = false
  @Local private zoomState: ReaderViewportTransform = new ReaderViewportTransform()
  @Local private zoomAnimating: boolean = false
  @Local private recovering: boolean = false
  private recoveryIdentity: string = ''
  private transformIdentity: string = ''
  private gestureIdentity: string = ''
  private pinchStart: ReaderViewportTransform = new ReaderViewportTransform()
  private panStart: ReaderViewportTransform = new ReaderViewportTransform()
  private pinchX: number = 0
  private pinchY: number = 0
  @Local private pinching: boolean = false
  private panning: boolean = false
  private ignorePan: boolean = false
  private pinchAdjusted: boolean = false
  private animationTimer: number = 0
  private tapSequence: ReaderTapSequence = new ReaderTapSequence()
  private entryMeasurement: ReaderEntryMeasurement = new ReaderEntryMeasurement()

  private identity(): string {
    return `${this.snapshot.navigationRevision}:${this.snapshot.kind}:${this.snapshot.policy.layout}:${this.snapshot.policy.direction}:` +
      this.snapshot.frames.map((frame: ReaderPagedFrame) =>
        `${frame.slotId}:${frame.asset.assetRequestId}:${frame.part.fragment}`).join('|')
  }

  @Monitor('snapshot', 'active', 'selected')
  onContentChanged(): void {
    const recoveryIdentity = `${this.snapshot.topologyRevision}:${this.snapshot.displayIndex}:${this.snapshot.kind}`
    if (recoveryIdentity !== this.recoveryIdentity) {
      this.recoveryIdentity = recoveryIdentity
      this.recovering = false
    }
    const failed = this.snapshot.frames.some((frame: ReaderPagedFrame) => frame.asset.phase === 'failed')
    if (failed && this.selected && this.active && this.entryTransition?.pending()) {
      const source = this.snapshot.frames.find((frame: ReaderPagedFrame) =>
        this.entryTransition?.matches(frame.part) === true && frame.asset.phase === 'failed')
      if (source !== undefined) {
        const target = new ReaderEntryTarget(source.part)
        target.selectionId = this.snapshot.selectionId
        target.topologyRevision = this.snapshot.topologyRevision
        target.navigationRevision = this.snapshot.navigationRevision
        target.slotId = source.slotId
        target.requestId = source.asset.requestId
        target.assetRequestId = source.asset.assetRequestId
        target.layoutRevision = ReaderEntryLayoutRevision.next(this.entryTransition.target?.layoutRevision ?? 0)
        target.failed = true
        this.entryTransition.publishTarget(target)
      }
      // Recovery changes joined image geometry into equal failure slots.
      this.entryTransition.cancel()
    }
    if (this.selected && this.active && this.entryTransition?.pending() &&
      ReaderEntryGeometryGate.cancel(this.snapshot.frames, this.entryTransition.phase)) {
      // Zero metadata can be refined by the real Image while the initial layout waits.
      this.entryTransition.cancel()
    }
    if (failed) this.recovering = true
    else if (this.snapshot.frames.length > 0 && this.snapshot.frames.every((frame: ReaderPagedFrame) =>
      frame.asset.phase === 'displayed')) this.recovering = false
    const identity = this.identity()
    if (identity !== this.transformIdentity || !this.selected || failed) {
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

  aboutToAppear(): void { this.onContentChanged() }
  aboutToDisappear(): void { this.cancelGesture() }

  @Monitor('zoomState', 'zoomAnimating', 'pinching', 'active', 'selected')
  onInputStateChanged(): void {
    if (this.selected && (this.zoomState.zoomed() || this.zoomAnimating || this.pinching ||
      this.zoomState.x !== 0 || this.zoomState.y !== 0)) this.entryTransition?.cancel()
    this.onInputLockChange(this.selected && this.active &&
      (this.zoomState.zoomed() || this.zoomAnimating || this.pinching))
  }

  private gesturesEnabled(): boolean {
    return this.active && this.selected && this.snapshot.phase === 'ready' && this.snapshot.frames.length > 0 &&
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
      const intrinsicHeight = frame.asset.kind === 'original'
        ? (frame.asset.page?.height ?? 0) * frame.crop.region(frame.part).height :
        frame.asset.page?.thumbnail.height ?? 0
      return intrinsicHeight > 0 ? intrinsicHeight / this.containedHeight(frame) : 2
    })
    if (this.splitLayout()) {
      const widths = this.snapshot.frames.map((frame: ReaderPagedFrame): number => this.containedHeight(frame) * partRatio(frame))
      const heights = this.snapshot.frames.map((frame: ReaderPagedFrame): number => this.containedHeight(frame))
      // The whole equal-slot Row scales, including the gap between narrow images.
      // Preserve the actual asymmetric outer edges rather than summing image widths.
      const left = -this.viewportWidth / 4 - widths[0] / 2
      const right = this.viewportWidth / 4 + widths[1] / 2
      return new ReaderViewportGeometry(this.viewportWidth, this.viewportHeight,
        right - left, Math.max(...heights), Math.max(1, ...scales), (left + right) / 2)
    }
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
    this.tapSequence.suppress()
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
    this.tapSequence.suppress()
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

  private splitLayout(): boolean {
    return this.snapshot.policy.layout === 'spread' && this.snapshot.policy.spreadLayout === 'split' &&
      this.snapshot.frames.length === 2
  }

  private containedHeight(frame: ReaderPagedFrame): number {
    return this.splitLayout() ? Math.min(this.viewportHeight, this.viewportWidth / 2 / partRatio(frame)) : this.frameHeight()
  }

  private equalSlots(): boolean { return this.recovering || this.splitLayout() }

  private entryRatiosReady(): boolean {
    return ReaderEntryGeometryGate.ready(this.snapshot.frames)
  }

  build() {
    Stack() {
      Row() {
        ForEach(this.snapshot.frames, (frame: ReaderPagedFrame) => {
          // Only stable identity comes from the ForEach closure. Cell state is
          // resolved from the current snapshot so same-key updates are not lost.
          ReaderPagedCell({
            snapshot: this.snapshot, slotId: frame.slotId,
            entryTransition: this.entryTransition,
            entryMeasurement: this.entryMeasurement,
            entryGeometryReady: this.entryViewportLaidOut && this.entryRatiosReady(),
            assetRequestId: frame.asset.assetRequestId,
            renderedFragment: frame.part.fragment,
            // Zero leaves the fitted width to the cell's current reactive frame, not this stable-key closure.
            frameWidth: this.equalSlots() ? this.viewportWidth / this.snapshot.frames.length : 0,
            frameHeight: this.equalSlots() ? this.viewportHeight : this.frameHeight(),
            active: this.selected && this.active && !this.zoomAnimating && this.zoomState.scale === 1,
            onPresented: this.onPresented, onVisible: this.onVisible, onFailed: this.onFailed,
            onInvalidDecodedMetrics: (slotId: number, requestId: number, assetRequestId: number): void => {
              if (this.selected && this.active && this.entryTransition !== null) {
                ReaderEntryGeometryGate.invalidDecoded(this.entryTransition, this.snapshot, slotId, requestId, assetRequestId)
              }
            },
            onRetry: this.onRetry,
          })
        }, (frame: ReaderPagedFrame): string => `${frame.slotId}:${frame.asset.assetRequestId}:${frame.part.fragment}`)
      }
      .direction(Direction.Ltr)
      .width(this.equalSlots() ? this.viewportWidth : this.frameHeight() * this.totalRatio())
      .height(this.equalSlots() ? this.viewportHeight : this.frameHeight())
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
    .id(this.selected ? 'rkit-image-viewport' : `rkit-cached-viewport-${this.snapshot.displayIndex}`)
    .onTouch((event: TouchEvent): void => { this.tapSequence.touch(event) })
    .onAreaChange((_old: Area, area: Area): void => {
      if (this.entryViewportLaidOut && this.entryTransition !== null && this.entryTransition.target !== null &&
        (this.viewportWidth !== Math.max(1, Number(area.width)) ||
          this.viewportHeight !== Math.max(1, Number(area.height)))) this.entryTransition.cancel()
      this.cancelGesture()
      this.viewportWidth = Math.max(1, Number(area.width))
      this.viewportHeight = Math.max(1, Number(area.height))
      this.entryViewportLaidOut = true
      this.zoomState = this.zoomState.settled(this.geometry())
    })
    .gesture(GestureGroup(GestureMode.Parallel,
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 2, distanceThreshold: 8 })
          .onAction((event?: GestureEvent): void => { this.doubleTap(event) }),
        TapGesture({ count: 1 }).onAction((event?: GestureEvent): void => {
          if (this.active && this.selected && !this.pinching && this.tapSequence.allowed() && event !== undefined) {
            this.onTap((event.tapLocation?.x ?? this.viewportWidth / 2) / this.viewportWidth)
          }
        }),
      ),
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
  @Param entryTransition: ReaderEntryTransition | null = null
  @Param entryMeasurement: ReaderEntryMeasurement | null = null
  @Param entryGeometryReady: boolean = false
  @Require @Param slotId: number
  @Require @Param assetRequestId: number
  @Require @Param renderedFragment: ReaderFragment
  @Require @Param frameWidth: number
  @Require @Param frameHeight: number
  @Require @Param active: boolean
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onInvalidDecodedMetrics: (slotId: number, requestId: number, assetRequestId: number) => void = () => {}
  @Event onRetry: (slotId: number, requestId: number) => void = () => {}

  private frame(): ReaderPagedFrame {
    return this.snapshot.frames.find((frame: ReaderPagedFrame) => frame.slotId === this.slotId &&
      frame.asset.assetRequestId === this.assetRequestId && frame.part.fragment === this.renderedFragment) ??
      new ReaderPagedFrame(0, new ReaderDisplayPart(new ReaderUnitKey('', '', ''), null, 0), new ReaderSnapshot())
  }

  private cellWidth(): number { return this.frameWidth > 0 ? this.frameWidth : this.frameHeight * partRatio(this.frame()) }
  private imageHeight(): number { return Math.min(this.frameHeight, this.cellWidth() / partRatio(this.frame())) }

  private entryContentReady(): boolean {
    const transition = this.entryTransition
    const frame = this.frame()
    return this.active && this.entryGeometryReady && transition !== null && transition.pending() &&
      transition.matches(frame.part) && frame.asset.kind === 'original' && this.renderedFragment === 'whole'
  }

  build() {
    Stack() {
      if (this.frame().asset.phase === 'failed') {
        ReaderFailurePanel({
          page: this.frame().part.sourceIndex + 1, compact: this.snapshot.frames.length > 1,
          retryEnabled: this.active,
          onRetry: (): void => { this.onRetry(this.slotId, this.frame().asset.requestId) },
        })
      } else if (this.frame().asset.uri.length > 0 || this.entryContentReady()) {
        ReaderPagedImage({
          frame: this.frame(), selectionId: this.snapshot.selectionId,
          topologyRevision: this.snapshot.topologyRevision, navigationRevision: this.snapshot.navigationRevision,
          entryTransition: this.entryTransition,
          entryMeasurement: this.entryMeasurement,
          entryPhase: this.entryTransition?.phase ?? 'finished',
          entryLayoutWidth: this.entryGeometryReady ? this.imageHeight() * partRatio(this.frame()) : 0,
          entryLayoutHeight: this.entryGeometryReady ? this.imageHeight() : 0,
          slotId: this.slotId, assetRequestId: this.assetRequestId,
          renderedFragment: this.renderedFragment,
          active: this.active && this.snapshot.phase === 'ready',
          onPresented: this.onPresented, onVisible: this.onVisible, onFailed: this.onFailed,
          onInvalidDecodedMetrics: this.onInvalidDecodedMetrics,
        }).width(this.imageHeight() * partRatio(this.frame())).height(this.imageHeight())
      }
      if (this.frame().asset.phase === 'idle' || this.frame().asset.phase === 'asset' || this.frame().asset.phase === 'decoding') {
        LoadingProgress().width(32).height(32)
      }
    }
    .width(this.cellWidth())
    .height(this.frameHeight).clip(true)
    .id(`rkit-part-${this.frame().part.sourceIndex}-${this.frame().part.fragment}`)
  }
}

@ComponentV2
export struct ReaderPagedImage {
  @Param continuousEntry: ReaderContinuousEntryPosition | null = null
  @Require @Param frame: ReaderPagedFrame
  @Require @Param slotId: number
  @Require @Param assetRequestId: number
  @Require @Param selectionId: number
  @Require @Param renderedFragment: ReaderFragment
  @Require @Param active: boolean
  @Param thumbnailCover: boolean = false
  @Param topologyRevision: number = 0
  @Param navigationRevision: number = 0
  @Param entryTransition: ReaderEntryTransition | null = null
  @Param entryMeasurement: ReaderEntryMeasurement | null = null
  @Param entryPhase: string = 'finished'
  @Param entryLayoutWidth: number = 0
  @Param entryLayoutHeight: number = 0
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onInvalidDecodedMetrics: (slotId: number, requestId: number, assetRequestId: number) => void = () => {}
  @Local private viewportWidth: number = 1
  @Local private viewportHeight: number = 1
  @Local private sheetWidth: number = 0
  @Local private sheetHeight: number = 0
  private fullyVisible: boolean = false
  private decoded: boolean = false
  private entryContentLaidOut: boolean = false
  private entryLeafLaidOut: boolean = false
  private entryLayoutRevision: number = 0
  private decodedWidth: number = 0
  private decodedHeight: number = 0
  private entryMounted: boolean = false
  private measuredEntryId: number = -1
  private measuredEntryRect: ReaderEntryRect | null = null

  aboutToAppear(): void { this.entryMounted = true }
  aboutToDisappear(): void { this.entryMounted = false }

  @Monitor('active', 'selectionId', 'frame')
  onSelectionChanged(): void { this.publishEntryTarget(); this.reportVisible() }

  @Monitor('frame', 'entryTransition', 'entryLayoutWidth', 'entryLayoutHeight', 'topologyRevision', 'navigationRevision', 'continuousEntry')
  onEntryLayoutChanged(): void { this.publishEntryTarget() }

  @Monitor('entryPhase')
  onEntryPhaseChanged(): void { this.reportVisible() }

  private entryLeafId(): string {
    return `rkit-entry-image-${this.entryTransition?.entryId ?? 0}-${this.slotId}-${this.assetRequestId}`
  }

  private entryContentId(): string {
    return `rkit-entry-content-${this.entryTransition?.entryId ?? 0}-${this.slotId}-${this.assetRequestId}`
  }

  private reportInvalidDecodedMetrics(): boolean {
    if (this.entryTransition === null || !this.entryTransition.pending() || !this.entryMounted || !this.active ||
      this.frame.asset.kind !== 'original' || !this.decoded ||
      ReaderEntryGeometryGate.dimensions(this.decodedWidth, this.decodedHeight) === 'ready') return false
    // A sibling may already have refined selection while this callback still holds the old snapshot.
    // Keep the terminal fact on this leaf and retry through the current-snapshot monitors.
    this.onInvalidDecodedMetrics(this.slotId, this.frame.asset.requestId, this.assetRequestId)
    return true
  }

  private publishEntryTarget(failed: boolean = false): void {
    const position = this.continuousEntry
    if (position !== null) {
      if (!position.isCurrent()) return
      // The closure keeps the positioning token that scheduled this measurement.
      this.getUIContext().postFrameCallback(new ReaderEntryAfterLayout((): void => {
        if (this.continuousEntry !== position || !position.isCurrent()) return
        this.measureEntryTarget(failed, position)
      }))
      return
    }
    this.measureEntryTarget(failed, null)
  }

  private measureEntryTarget(failed: boolean, position: ReaderContinuousEntryPosition | null): void {
    if (!failed && this.reportInvalidDecodedMetrics()) return
    const transition = this.entryTransition
    if (transition === null || !transition.pending() || !this.entryMounted ||
      (position === null ? !this.active : this.continuousEntry !== position || !position.isCurrent()) ||
      !transition.matches(this.frame.part)) return
    if (position !== null && this.decoded && ReaderEntryGeometryGate.dimensions(this.decodedWidth, this.decodedHeight) !== 'ready') {
      transition.cancel(); return
    }
    if (this.measuredEntryId !== transition.entryId) {
      this.measuredEntryId = transition.entryId
      this.measuredEntryRect = null
      this.entryLayoutRevision = 0
    }
    const target = new ReaderEntryTarget(this.frame.part)
    target.selectionId = position?.selection ?? this.selectionId
    target.topologyRevision = position?.topology ?? this.topologyRevision
    target.navigationRevision = position?.navigation ?? this.navigationRevision
    target.slotId = this.slotId
    target.requestId = this.frame.asset.requestId
    target.assetRequestId = this.assetRequestId
    target.failed = failed
    target.decodedReady = this.decoded
    target.layoutRevision = Math.max(this.entryLayoutRevision, transition.target?.layoutRevision ?? 0)
    if (failed) { transition.publishTarget(target); return }
    const page = this.frame.asset.page
    // Sprite/fragment clipping and unknown original geometry need a different
    // content contract; never advertise their outer wrapper as the image bounds.
    if (this.frame.asset.kind !== 'original' || this.renderedFragment !== 'whole' || this.frame.crop.applied()) {
      transition.cancel(); return
    }
    if (page === null) return
    const dimensions = ReaderEntryGeometryGate.dimensions(page.width, page.height)
    if (dimensions === 'invalid' || (dimensions === 'unknown' && transition.phase !== 'layout')) {
      transition.cancel(); return
    }
    // completed() reports into core first; the callback's old @Param may still contain zero.
    // Wait for its current snapshot and the actual fitted area, never publish the fallback ratio.
    if (dimensions === 'unknown') return
    const layoutWidth = position?.width ?? this.entryLayoutWidth
    const layoutHeight = position?.height ?? this.entryLayoutHeight
    if (!this.entryContentLaidOut || layoutWidth <= 0 || layoutHeight <= 0) return
    if (this.frame.asset.uri.length > 0 && !this.entryLeafLaidOut) return
    try {
      const context = this.getUIContext()
      // This is the same fitted content Stack that owns the delivered Image,
      // not the outer cell (which also owns loading and failure presentation).
      const leaf = context.getComponentUtils().getRectangleById(this.entryContentId())
      if (this.frame.asset.uri.length > 0) {
        const image = context.getComponentUtils().getRectangleById(this.entryLeafId())
        if (Math.abs(image.windowOffset.x - leaf.windowOffset.x) > 1 ||
          Math.abs(image.windowOffset.y - leaf.windowOffset.y) > 1 ||
          Math.abs(image.size.width - leaf.size.width) > 1 || Math.abs(image.size.height - leaf.size.height) > 1) {
          if (transition.phase !== 'layout') transition.cancel()
          return
        }
      }
      const viewport = context.getComponentUtils().getRectangleById(position === null ? 'rkit-image-viewport' : 'rkit-continuous-list')
      const rect = new ReaderEntryRect(context.px2vp(leaf.windowOffset.x), context.px2vp(leaf.windowOffset.y),
        context.px2vp(leaf.size.width), context.px2vp(leaf.size.height))
      if (!rect.valid()) return
      // Parent/child area callbacks have no guaranteed order. Wait until this
      // leaf has actually applied the current cell fit before publishing it.
      if (Math.abs(leaf.size.width - context.vp2px(layoutWidth)) > 1 ||
        Math.abs(leaf.size.height - context.vp2px(layoutHeight)) > 1) {
        if (transition.phase !== 'layout') transition.cancel()
        return
      }
      if (position === null && (leaf.windowOffset.x < viewport.windowOffset.x - 1 || leaf.windowOffset.y < viewport.windowOffset.y - 1 ||
        leaf.windowOffset.x + leaf.size.width > viewport.windowOffset.x + viewport.size.width + 1 ||
        leaf.windowOffset.y + leaf.size.height > viewport.windowOffset.y + viewport.size.height + 1)) {
        transition.cancel(); return
      }
      if (position !== null) {
        const root = context.getComponentUtils().getRectangleById('rkit-entry-preview-root')
        const left = Math.max(viewport.windowOffset.x, root.windowOffset.x)
        const top = Math.max(viewport.windowOffset.y, root.windowOffset.y)
        const right = Math.min(viewport.windowOffset.x + viewport.size.width, root.windowOffset.x + root.size.width)
        const bottom = Math.min(viewport.windowOffset.y + viewport.size.height, root.windowOffset.y + root.size.height)
        const clip = new ReaderEntryRect(context.px2vp(left), context.px2vp(top), context.px2vp(right - left), context.px2vp(bottom - top))
        if (!clip.valid() || rect.x >= clip.x + clip.width || rect.y >= clip.y + clip.height ||
          rect.x + rect.width <= clip.x || rect.y + rect.height <= clip.y) { transition.cancel(); return }
        target.clipRect = clip
      }
      // Contain must occupy the measured Image itself. Unexpected decoded
      // proportions are not permission to stretch a thumbnail to this box.
      if (this.decoded && this.decodedWidth > 0 && this.decodedHeight > 0 &&
        Math.abs(leaf.size.width - leaf.size.height * this.decodedWidth / this.decodedHeight) > 1) {
        if (transition.phase !== 'layout') transition.cancel()
        return
      }
      const previous = transition.target
      const inheritedRect = this.entryMeasurement?.entryId === transition.entryId ?
        this.entryMeasurement.contentRect : null
      const priorRect = previous?.contentRect ?? this.measuredEntryRect ?? inheritedRect
      const moved = priorRect !== null && (priorRect.x !== rect.x || priorRect.y !== rect.y ||
        priorRect.width !== rect.width || priorRect.height !== rect.height)
      const oldClip = previous?.clipRect ?? null
      const clipChanged = previous !== null && ((oldClip === null) !== (target.clipRect === null) ||
        (oldClip !== null && target.clipRect !== null &&
        (oldClip.x !== target.clipRect.x || oldClip.y !== target.clipRect.y ||
        oldClip.width !== target.clipRect.width || oldClip.height !== target.clipRect.height)))
      if (clipChanged && transition.phase !== 'layout') { transition.cancel(); return }
      if (moved && transition.phase !== 'layout') { transition.cancel(); return }
      const sameIdentity = previous !== null && previous.selectionId === target.selectionId &&
        previous.topologyRevision === target.topologyRevision && previous.navigationRevision === target.navigationRevision &&
        previous.slotId === target.slotId && previous.requestId === target.requestId &&
        previous.assetRequestId === target.assetRequestId
      // A publication redraws the optional presenter. Identical leaf reports
      // must not feed that redraw back into another target publication.
      if (sameIdentity && !moved && !clipChanged && previous !== null && previous.geometryReady &&
        previous.decodedReady === target.decodedReady && !previous.failed) return
      if (previous === null || moved || clipChanged || !sameIdentity) {
        target.layoutRevision = ReaderEntryLayoutRevision.next(target.layoutRevision)
      }
      this.entryLayoutRevision = target.layoutRevision
      this.measuredEntryRect = rect.copy()
      target.contentRect = rect
      target.geometryReady = true
      if (position !== null && (this.continuousEntry !== position || !position.isCurrent())) return
      transition.publishTarget(target)
      // Rejected retired-leaf callbacks must not replace the next leaf's baseline.
      if (this.entryMeasurement !== null && transition.target?.layoutRevision === target.layoutRevision &&
        transition.target.requestId === target.requestId && transition.target.assetRequestId === target.assetRequestId) {
        this.entryMeasurement.entryId = transition.entryId
        this.entryMeasurement.contentRect = rect.copy()
      }
    } catch (_error) {
      transition.cancel()
    }
  }

  private reportVisible(): void {
    if (this.active && this.fullyVisible && this.decoded && this.frame.asset.kind === 'original' &&
      (this.entryTransition === null || !this.entryTransition.pending())) {
      this.onVisible(this.selectionId, this.slotId, this.assetRequestId, this.renderedFragment)
    }
  }

  private completed(width: number, height: number): void {
    const thumbnail = this.frame.asset.page?.thumbnail
    if (this.frame.asset.kind === 'thumbnail' && thumbnail?.kind === 'sprite' &&
      Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0 &&
      (this.sheetWidth !== width || this.sheetHeight !== height)) {
      this.sheetWidth = width
      this.sheetHeight = height
      console.info(`[ReaderViewport] sprite_pixels slot=${this.slotId} request=${this.assetRequestId} real=${width}x${height} parsed=${thumbnail.spriteWidth}x${thumbnail.spriteHeight} crop=${thumbnail.width}x${thumbnail.height}`)
    }
    this.decoded = true
    this.decodedWidth = width
    this.decodedHeight = height
    this.reportInvalidDecodedMetrics()
    this.onPresented(this.slotId, this.assetRequestId, true, width, height)
    this.publishEntryTarget()
    this.reportVisible()
  }

  private failed(): void {
    this.decoded = false
    this.publishEntryTarget(true)
    this.onFailed(this.selectionId, this.slotId, this.assetRequestId, this.renderedFragment)
  }

  private spriteScale(): number {
    const thumbnail = this.frame.asset.page?.thumbnail
    if (thumbnail === undefined || thumbnail.width <= 0 || thumbnail.height <= 0) return 1
    return this.thumbnailCover && this.frame.asset.kind === 'thumbnail'
      ? Math.max(this.viewportWidth / thumbnail.width, this.viewportHeight / thumbnail.height)
      : Math.min(this.viewportWidth / thumbnail.width, this.viewportHeight / thumbnail.height)
  }

  build() {
    Stack() {
      if (this.frame.asset.uri.length > 0 && this.frame.asset.kind === 'thumbnail' &&
        this.frame.asset.page?.thumbnail.kind === 'sprite') {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(this.frame.asset.uri)
            // Parsed extents describe the occupied cells, not necessarily the entire canvas.
            // Keep one pixel scale on both axes, including any decoded sheet padding.
            .width((this.sheetWidth || this.frame.asset.page.thumbnail.spriteWidth) * this.spriteScale())
            .height((this.sheetHeight || this.frame.asset.page.thumbnail.spriteHeight) * this.spriteScale())
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
      } else if (this.frame.asset.uri.length > 0 && this.frame.asset.kind === 'original' &&
        (this.frame.part.fragment !== 'whole' || this.frame.crop.applied())) {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(this.frame.asset.uri)
            .width(this.viewportWidth / this.frame.crop.region(this.frame.part).width)
            .height(this.viewportHeight / this.frame.crop.region(this.frame.part).height)
            .id(`rkit-cropped-image-${this.frame.part.sourceIndex}-${this.frame.part.fragment}`)
            .objectFit(ImageFit.Fill)
            .position({
              x: -this.viewportWidth * this.frame.crop.region(this.frame.part).x / this.frame.crop.region(this.frame.part).width,
              y: -this.viewportHeight * this.frame.crop.region(this.frame.part).y / this.frame.crop.region(this.frame.part).height,
            })
            .onComplete((event): void => {
              if (event?.loadingStatus === 1) this.completed(event.width, event.height)
            })
            .onError((): void => { this.failed() })
        }
        .width('100%').height('100%').clip(true)
      } else if (this.frame.asset.uri.length > 0) {
        Image(this.frame.asset.uri)
          .width('100%').height('100%')
          .objectFit(this.thumbnailCover && this.frame.asset.kind === 'thumbnail' ? ImageFit.Cover : ImageFit.Contain)
          .id(this.entryLeafId())
          .onAreaChange((): void => {
            this.entryLeafLaidOut = true
            this.publishEntryTarget()
          })
          .onComplete((event): void => {
            if (event?.loadingStatus === 1) this.completed(event.width, event.height)
          })
          .onError((): void => { this.failed() })
      }
    }
    .width('100%').height('100%')
    .id(this.entryContentId())
    .clip(this.thumbnailCover && this.frame.asset.kind === 'thumbnail')
    .opacity(this.entryTransition?.opacity(this.frame.part) ?? 1)
    .onVisibleAreaChange([0, 1], (_expanding: boolean, ratio: number): void => {
      this.fullyVisible = ratio >= 1
      this.reportVisible()
    })
    .onAreaChange((_old: Area, area: Area): void => {
      this.viewportWidth = Math.max(1, Number(area.width))
      this.viewportHeight = Math.max(1, Number(area.height))
      this.entryContentLaidOut = true
      this.publishEntryTarget()
    })
  }
}
