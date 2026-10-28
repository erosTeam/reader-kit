import { FrameCallback, LengthMetrics } from '@kit.ArkUI'
import { ReaderPagedSnapshot, ReaderPagedFrame, ReaderFragment, ReaderAssetNotice, readerPolicyRotatesPage, readerPagedFrameAspectRatio } from '@reader-kit/core'
import { ReaderContinuousZoomImage } from './ReaderContinuousZoomImage'
import { ReaderFailurePanel } from './ReaderFailurePanel'
import { ReaderAssetNoticePanel } from './ReaderAssetNoticePanel'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { ReaderContinuousEntryPosition } from './ReaderContinuousEntryPosition'
import { ReaderTapAction } from './ReaderTapAction'
import { ReaderTapSequence } from './ReaderTapSequence'
import { ReaderTapArbiter, ReaderTapPoint } from './ReaderTapArbiter'
import { ReaderBoundaryDirection, ReaderBoundarySwipe } from './ReaderBoundarySwipe'
import { normalizedReaderPageGap } from './ReaderPageGap'
import { ReaderLoadingStage } from './ReaderLoadingStage'
import { ReaderImagePlaceholder, ReaderImagePresentation } from './ReaderImagePlaceholder'
import { ReaderZoomResetCommand } from './ReaderZoomResetCommand'
import { readerElementKey } from './ReaderElementKey'
import { ReaderContinuousCellSnapshot, ReaderContinuousCellSnapshots } from './ReaderContinuousCellSnapshot'

class ReaderContinuousIndexSource implements IDataSource {
  private keys: string[]
  private listeners: DataChangeListener[] = []
  constructor(keys: string[]) { this.keys = keys.slice() }
  totalCount(): number { return this.keys.length }
  getData(index: number): string { return this.keys[index] }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener)
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((value: DataChangeListener): boolean => value !== listener)
  }
  update(keys: string[]): void {
    // Chapter extension changes only the ends. Never reload/remount the List;
    // ArkUI preserves its visible key/offset with add/delete notifications.
    if (keys.length === this.keys.length && keys.every((key: string, index: number): boolean =>
      key === this.keys[index])) return
    const wanted = new Set<string>(keys)
    for (let index = this.keys.length - 1; index >= 0; index--) {
      if (wanted.has(this.keys[index])) continue
      this.keys.splice(index, 1)
      this.listeners.forEach((listener: DataChangeListener): void => listener.onDataDelete(index))
    }
    for (let index = 0; index < keys.length; index++) {
      if (this.keys[index] === keys[index]) continue
      this.keys.splice(index, 0, keys[index])
      this.listeners.forEach((listener: DataChangeListener): void => listener.onDataAdd(index))
    }
  }
}

class ReaderContinuousAfterLayout extends FrameCallback {
  private action: () => void
  constructor(action: () => void) { super(); this.action = action }
  onIdle(_remaining: number): void { this.action() }
}

/** Continuous layout only. Host navigation, commands and resource ownership stay outside. */
@ComponentV2
export struct ReaderContinuousSurface {
  @Param loadingInk: ResourceColor = Color.White
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Param doubleTapEnabled: boolean = true
  @Param doubleTapIntervalMs: number = 300
  @Param pageGap: number = 0
  @Param entryTransition: ReaderEntryTransition | null = null
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Param zoomResetCommand: ReaderZoomResetCommand | null = null
  @Event onInputLockChange: (locked: boolean, topology: number) => void = () => {}
  @Event onZoomedChange: (zoomed: boolean, topology: number, navigation: number) => void = () => {}
  @Event onTap: (xFraction: number, yFraction: number) => ReaderTapAction = () => 'none'
  @Event onRange: (start: number, end: number, topology: number, navigation: number, position?: number) => void = () => {}
  @Event onPresented: (slot: number, request: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (topology: number, navigation: number, key: string, slot: number, request: number, x: number, y: number) => void = () => {}
  @Event onFailed: (topology: number, key: string, slot: number, request: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (topology: number, key: string, slot: number, request: number) => void = () => {}
  @Event onNoticeAction: (topology: number, navigation: number, key: string, slot: number,
    request: number, noticeId: string) => Promise<boolean> =
    async (_topology: number, _navigation: number, _key: string, _slot: number,
      _request: number, _noticeId: string): Promise<boolean> => false
  @Event onBoundary: (direction: ReaderBoundaryDirection, topologyRevision: number,
    navigationRevision: number) => void = () => {}

  build() {
    Stack() {
      if (this.snapshot.displayKeys.length > 0) {
        ForEach([this.snapshot.topologyRevision], (revision: number) => {
          ReaderContinuousList({
            imageInterpolation: this.imageInterpolation, loadingInk: this.loadingInk,
            doubleTapEnabled: this.doubleTapEnabled, doubleTapIntervalMs: this.doubleTapIntervalMs,
            pageGap: this.pageGap,
            snapshot: this.snapshot,
            active: this.active && this.snapshot.phase === 'ready' &&
              revision === this.snapshot.topologyRevision,
            createdRevision: revision,
            zoomResetCommand: this.zoomResetCommand,
            entryTransition: this.entryTransition,
            onInputLockChange: this.onInputLockChange,
            onZoomedChange: this.onZoomedChange,
            onBoundary: this.onBoundary,
            onRange: this.onRange, onPresented: this.onPresented, onVisible: this.onVisible, onFailed: this.onFailed,
            onRetry: this.onRetry, onNoticeAction: this.onNoticeAction,
            onTap: this.onTap,
          })
        }, (revision: number): string => `${revision}`)
      } else if (this.snapshot.phase === 'idle' || this.snapshot.phase === 'catalog') {
        ReaderLoadingStage({ label: $r('app.string.rkit_loading_resolving'), loadingInk: this.loadingInk })
      }
    }.width('100%').height('100%').clip(true)
  }
}

@ComponentV2
struct ReaderContinuousList {
  @Param loadingInk: ResourceColor = Color.White
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Param doubleTapEnabled: boolean = true
  @Param doubleTapIntervalMs: number = 300
  @Param pageGap: number = 0
  @Param entryTransition: ReaderEntryTransition | null = null
  @Local private entryPosition: ReaderContinuousEntryPosition | null = null
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Param zoomResetCommand: ReaderZoomResetCommand | null = null
  @Event onInputLockChange: (locked: boolean, topology: number) => void = () => {}
  @Event onZoomedChange: (zoomed: boolean, topology: number, navigation: number) => void = () => {}
  @Event onTap: (xFraction: number, yFraction: number) => ReaderTapAction = () => 'none'
  @Require @Param createdRevision: number
  @Event onRange: (start: number, end: number, topology: number, navigation: number, position?: number) => void = () => {}
  @Event onPresented: (slot: number, request: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (topology: number, navigation: number, key: string, slot: number, request: number, x: number, y: number) => void = () => {}
  @Event onFailed: (topology: number, key: string, slot: number, request: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (topology: number, key: string, slot: number, request: number) => void = () => {}
  @Event onNoticeAction: (topology: number, navigation: number, key: string, slot: number,
    request: number, noticeId: string) => Promise<boolean> =
    async (_topology: number, _navigation: number, _key: string, _slot: number,
      _request: number, _noticeId: string): Promise<boolean> => false
  @Event onBoundary: (direction: ReaderBoundaryDirection, topologyRevision: number,
    navigationRevision: number) => void = () => {}
  private source: ReaderContinuousIndexSource = new ReaderContinuousIndexSource([])
  private cellSnapshots: ReaderContinuousCellSnapshots = new ReaderContinuousCellSnapshots()
  private scroller: ListScroller = new ListScroller()
  private nativeReady: Map<string, string> = new Map()
  @Local private viewWidth: number = 1
  private viewHeight: number = 1
  @Local private fullyVisible: boolean = false
  private lastNavigation: number = -1
  @Local private pendingPosition: boolean = true
  private positionTimer: number = 0
  private positionInFlight: boolean = false
  private positionEpoch: number = 0
  private positionTarget: number = -1
  private positionX: number = 0.5
  private positionY: number = 0
  private rowGeometry: Map<string, number> = new Map()
  private geometryRevision: number = 0
  private disposed: boolean = false
  private measureTimer: number = 0
  private first: number = 0
  private last: number = 0
  @Local private lockedKey: string = ''
  @Local private moving: boolean = false
  private lockedIdentity: string = ''
  private zoomedKey: string = ''
  private zoomedIdentity: string = ''
  private cropRegions: Map<string, string> = new Map()
  private boundarySwipe: ReaderBoundarySwipe = new ReaderBoundarySwipe()
  private boundaryTopology: number = -1
  private boundaryNavigation: number = -1

  private handleBoundaryTouch(event: TouchEvent): void {
    if (!this.active || this.snapshot.phase !== 'ready' || event.touches.length > 1 ||
      event.changedTouches.length === 0) {
      this.boundarySwipe.cancel()
      return
    }
    const point = event.changedTouches[0]
    if (event.type === TouchType.Down) {
      if (this.pendingPosition || this.positionInFlight || this.moving || this.lockedKey.length > 0) {
        this.boundarySwipe.cancel()
        return
      }
      let atStart = false
      let atEnd = false
      try {
        atStart = this.first === 0 && this.scroller.currentOffset().yOffset <= 0.5
        atEnd = this.last + 1 >= this.snapshot.displayKeys.length && this.scroller.isAtEnd()
      } catch (_) {
        this.boundarySwipe.cancel()
        return
      }
      this.boundaryTopology = this.snapshot.topologyRevision
      this.boundaryNavigation = this.snapshot.navigationRevision
      this.boundarySwipe.begin(point.windowX, point.windowY, atStart, atEnd)
      return
    }
    if (event.type === TouchType.Cancel) {
      this.boundarySwipe.cancel()
      return
    }
    if (event.type !== TouchType.Up) return
    const direction = this.boundarySwipe.finish(point.windowX, point.windowY, 'vertical')
    if (direction !== null && this.active && this.snapshot.phase === 'ready' &&
      this.createdRevision === this.snapshot.topologyRevision && this.boundaryTopology === this.snapshot.topologyRevision &&
      this.boundaryNavigation === this.snapshot.navigationRevision) {
      this.onBoundary(direction, this.boundaryTopology, this.boundaryNavigation)
    }
  }

  aboutToAppear(): void {
    this.source = new ReaderContinuousIndexSource(this.snapshot.displayKeys)
    this.lastNavigation = this.snapshot.navigationRevision
    this.first = this.snapshot.continuousIndex
    this.last = this.first
    this.reportExternalLock()
  }

  aboutToDisappear(): void {
    this.disposed = true
    this.positionTarget = -1
    this.entryTransition?.cancel()
    this.entryPosition = null
    this.positionEpoch += 1
    if (this.positionTimer !== 0) clearTimeout(this.positionTimer)
    if (this.measureTimer !== 0) clearTimeout(this.measureTimer)
  }

  @Monitor('lockedKey', 'pendingPosition', 'moving', 'active')
  reportExternalLock(): void {
    this.onInputLockChange(!this.active || this.pendingPosition || this.moving || this.lockedKey.length > 0,
      this.createdRevision)
  }

  @Monitor('snapshot', 'active')
  onSnapshotChanged(): void {
    const positionedKey = this.positionTarget >= 0 ? this.source.getData(this.positionTarget) : ''
    this.source.update(this.snapshot.displayKeys)
    if (positionedKey.length > 0) this.positionTarget = this.snapshot.displayKeys.indexOf(positionedKey)
    const entryFrame = this.snapshot.frames.find((frame: ReaderPagedFrame): boolean =>
      this.entryTransition?.matches(frame.part) === true)
    if (entryFrame?.asset.phase === 'failed') this.entryTransition?.cancel()
    if (this.entryPosition !== null && entryFrame !== undefined &&
      this.entryPosition.height !== this.imageHeight(this.snapshot.continuousIndex)) this.invalidatePosition()
    if (this.positionTarget >= 0) {
      const targetFrame = this.snapshot.forItem(this.snapshot.displayKeys[this.positionTarget]).frames[0]
      if (targetFrame?.asset.phase === 'failed' || targetFrame?.asset.phase === 'suppressed') this.releasePosition()
    }
    let cropChanged = false
    this.snapshot.displayKeys.forEach((key: string, index: number): void => {
      const crop = this.snapshot.continuousCrop(index)
      const value = `${crop.left}:${crop.top}:${crop.right}:${crop.bottom}`
      const previous = this.cropRegions.get(key)
      if (previous !== undefined && previous !== value) cropChanged = true
      this.cropRegions.set(key, value)
    })
    if (cropChanged) this.invalidatePosition()
    // A host sheet/background suspends input, not the current explicit page.
    // User movement, a new navigation, failure or disposal still retires it.
    if (!this.active) this.moving = false
    if (this.lockedKey.length > 0) {
      const frame = this.snapshot.forItem(this.lockedKey).frames[0]
      if (frame === undefined || frame.asset.phase !== 'displayed' ||
        this.lockedIdentity !== this.imageIdentity(this.lockedKey, frame)) {
        this.lockedKey = ''
        this.lockedIdentity = ''
      }
    }
    if (this.zoomedKey.length > 0) {
      const frame = this.snapshot.forItem(this.zoomedKey).frames[0]
      if (frame === undefined || frame.asset.phase !== 'displayed' ||
        this.zoomedIdentity !== this.imageIdentity(this.zoomedKey, frame)) {
        this.zoomedKey = ''
        this.zoomedIdentity = ''
        this.onZoomedChange(false, this.createdRevision, this.snapshot.navigationRevision)
      }
    }
    if (this.lastNavigation !== this.snapshot.navigationRevision) {
      this.lastNavigation = this.snapshot.navigationRevision
      this.positionTarget = -1
      this.rowGeometry.clear()
      this.boundarySwipe.cancel()
      this.invalidatePosition()
    }
    if (this.pendingPosition) this.schedulePosition()
    else { this.refreshEntryPosition(); this.scheduleMeasure() }
  }

  private refreshEntryPosition(): void {
    const entry = this.entryTransition
    if (entry === null || !entry.pending() || this.disposed || !this.active || this.pendingPosition ||
      this.positionInFlight || this.moving || this.lockedKey.length > 0 || this.snapshot.phase !== 'ready') return
    const frame = this.snapshot.forItem(this.snapshot.displayKeys[this.snapshot.continuousIndex]).frames[0]
    if (frame === undefined || !entry.matches(frame.part)) return
    if (frame.asset.phase === 'failed') { entry.cancel(); return }
    const width = this.viewWidth
    const height = this.imageHeight(this.snapshot.continuousIndex)
    const previous = this.entryPosition
    if (previous !== null && previous.matches(this.snapshot) && previous.width === width && previous.height === height) return
    const epoch = this.positionEpoch
    const token: ReaderContinuousEntryPosition = new ReaderContinuousEntryPosition(epoch, this.snapshot, frame, width, height, entry, (): boolean =>
      this.entryPosition === token && !this.disposed && this.active && !this.pendingPosition &&
      !this.positionInFlight && !this.moving && this.lockedKey.length === 0 && this.positionEpoch === epoch && token.matches(this.snapshot) &&
      this.viewWidth === width && this.imageHeight(this.snapshot.continuousIndex) === height)
    this.entryPosition = token
  }

  private imageTap(key: string, windowX: number, windowY: number): void {
    if (!this.active || this.disposed || this.pendingPosition || this.positionInFlight || !this.fullyVisible ||
      this.moving || (this.lockedKey.length > 0 && this.lockedKey !== key) || this.snapshot.phase !== 'ready' ||
      this.createdRevision !== this.snapshot.topologyRevision || this.entryTransition?.blocksInput() ||
      !Number.isFinite(windowX) || !Number.isFinite(windowY)) return
    const frame = this.snapshot.forItem(key).frames[0]
    if (frame === undefined) return
    const navigation = this.snapshot.navigationRevision
    try {
      const context = this.getUIContext()
      const rect = context.getComponentUtils().getRectangleById('rkit-continuous-list')
      const width = context.px2vp(rect.size.width), height = context.px2vp(rect.size.height)
      const x = windowX - context.px2vp(rect.windowOffset.x)
      const y = windowY - context.px2vp(rect.windowOffset.y)
      if (!Number.isFinite(width) || !Number.isFinite(height) || !Number.isFinite(x) || !Number.isFinite(y) ||
        width <= 0 || height <= 0 ||
        x < 0 || y < 0 || x > width || y > height) return
      const action = this.onTap(x / width, y / height)
      if (!this.active || this.disposed || this.pendingPosition || this.positionInFlight ||
        this.lockedKey.length > 0 || navigation !== this.snapshot.navigationRevision) return
      if (action === 'previous' || action === 'left') {
        // An explicit scrollBy also supersedes entry positioning; it need not
        // produce the same onWillScroll callback as a finger-driven gesture.
        this.releasePosition()
        const atStart = this.first === 0 && this.scroller.currentOffset().yOffset <= 0.5
        if (atStart) this.onBoundary('previous', this.createdRevision, navigation)
        else this.scroller.scrollBy(0, -height * 0.75)
      } else if (action === 'next' || action === 'right') {
        this.releasePosition()
        const atEnd = this.last + 1 >= this.snapshot.displayKeys.length && this.scroller.isAtEnd()
        if (atEnd) this.onBoundary('next', this.createdRevision, navigation)
        else this.scroller.scrollBy(0, height * 0.75)
      }
    } catch (_) { /* A missing current viewport is not permission to infer a tap position. */ }
  }

  private imageAspectRatio(index: number): number {
    const page = this.snapshot.continuousPage(index)
    const frame = this.snapshot.window.find((item) => item.index === index)?.frames[0]
    if (this.snapshot.kind === 'original' && frame !== undefined && frame.asset.page !== null &&
      frame.part.fragment === 'whole' &&
      !frame.crop.applied() && !this.snapshot.continuousCrop(index).applied() &&
      !readerPolicyRotatesPage(this.snapshot.policy, page ?? null)) {
      const ratio = readerPagedFrameAspectRatio(frame, this.snapshot.policy)
      // The continuous list needs space for each loading row; this estimate is
      // local to that placeholder and is never a source-image measurement.
      return ratio > 0 ? ratio : 0.75
    }
    const crop = this.snapshot.continuousCrop(index)
    const usePreview = this.snapshot.kind === 'original' && page?.hasWholePagePreviewGeometry() === true &&
      ((page?.width ?? 0) <= 0 || (page?.height ?? 0) <= 0) &&
      crop.left === 0 && crop.top === 0 && crop.right === 0 && crop.bottom === 0
    const width = this.snapshot.kind === 'thumbnail' ? page?.thumbnail.width ?? 0 :
      usePreview ? page?.previewWidth ?? 0 : page?.width ?? 0
    const height = this.snapshot.kind === 'thumbnail' ? page?.thumbnail.height ?? 0 :
      usePreview ? page?.previewHeight ?? 0 : page?.height ?? 0
    const heightRatio = this.snapshot.kind === 'original'
      ? (1 - crop.top - crop.bottom) / (1 - crop.left - crop.right) : 1
    const ratio = width > 0 && height > 0 ? width / height / heightRatio : 0.75
    if (!readerPolicyRotatesPage(this.snapshot.policy, page ?? null)) return ratio
    const originalRatio = page !== null && page.width > 0 && page.height > 0
      ? page.width / page.height / ((1 - crop.top - crop.bottom) / (1 - crop.left - crop.right)) : 0
    return originalRatio > 0 ? 1 / originalRatio : 0.75
  }

  private rotates(index: number): boolean {
    const page = this.snapshot.continuousPage(index)
    return readerPolicyRotatesPage(this.snapshot.policy, page ?? null)
  }

  private imageHeight(index: number): number { return this.viewWidth / this.imageAspectRatio(index) }

  private rowHeight(index: number): number {
    const frame = this.snapshot.forItem(this.snapshot.displayKeys[index]).frames[0]
    return frame?.asset.phase === 'failed' ? 220 : Math.max(220, this.imageHeight(index))
  }

  private imageIdentity(key: string, frame: ReaderPagedFrame): string {
    return `${this.snapshot.navigationRevision}:${frame.slotId}:${frame.asset.assetRequestId}:` +
      `${this.rotates(this.snapshot.displayKeys.indexOf(key))}`
  }

  private onImageLock(key: string, identity: string, locked: boolean): void {
    const frame = this.snapshot.forItem(key).frames[0]
    if (frame === undefined || identity !== this.imageIdentity(key, frame)) return
    if (locked) {
      if (frame.asset.phase !== 'displayed' || (this.lockedKey.length > 0 && this.lockedKey !== key)) return
      this.entryTransition?.cancel()
      this.releasePosition()
      this.lockedKey = key
      this.lockedIdentity = identity
    } else if (this.lockedKey === key && this.lockedIdentity === identity) {
      this.lockedKey = ''
      this.lockedIdentity = ''
      this.scheduleMeasure()
    }
  }

  private onImageZoomed(key: string, identity: string, zoomed: boolean): void {
    const frame = this.snapshot.forItem(key).frames[0]
    if (frame === undefined || identity !== this.imageIdentity(key, frame)) return
    if (zoomed) {
      if (frame.asset.phase !== 'displayed' || (this.zoomedKey.length > 0 && this.zoomedKey !== key)) return
      this.zoomedKey = key
      this.zoomedIdentity = identity
      this.onZoomedChange(true, this.createdRevision, this.snapshot.navigationRevision)
    } else if (this.zoomedKey === key && this.zoomedIdentity === identity) {
      this.zoomedKey = ''
      this.zoomedIdentity = ''
      this.onZoomedChange(false, this.createdRevision, this.snapshot.navigationRevision)
    }
  }

  private invalidatePosition(): void {
    if (this.entryTransition?.phase !== 'layout') this.entryTransition?.cancel()
    this.entryPosition = null
    if (this.positionTimer !== 0) clearTimeout(this.positionTimer)
    if (this.measureTimer !== 0) clearTimeout(this.measureTimer)
    this.positionTimer = 0
    this.measureTimer = 0
    this.positionInFlight = false
    this.positionEpoch += 1
    this.pendingPosition = true
  }

  private onRowGeometry(key: string, height: number): void {
    if (!Number.isFinite(height) || height <= 0) return
    const previous = this.rowGeometry.get(key)
    this.rowGeometry.set(key, height)
    if (previous === height || this.positionTarget < 0 || this.disposed || !this.active) return
    const index = this.snapshot.displayKeys.indexOf(key)
    if (index < 0 || index > this.positionTarget) return
    this.geometryRevision += 1
    if (this.pendingPosition || this.positionInFlight) return
    this.invalidatePosition()
    this.schedulePosition()
  }

  private releasePosition(): void {
    this.positionTarget = -1
    this.positionEpoch += 1
    if (this.positionTimer !== 0) clearTimeout(this.positionTimer)
    this.positionTimer = 0
    this.positionInFlight = false
    this.pendingPosition = false
  }

  private schedulePosition(): void {
    if (this.positionTimer !== 0 || this.positionInFlight || this.disposed || !this.active ||
      this.viewWidth <= 1 || this.snapshot.phase !== 'ready') return
    const navigation = this.snapshot.navigationRevision
    const epoch = this.positionEpoch
    this.positionTimer = setTimeout((): void => {
      if (this.disposed || epoch !== this.positionEpoch || navigation !== this.snapshot.navigationRevision) return
      this.positionTimer = 0
      if (!this.active) return
      if (this.positionTarget < 0) {
        this.positionTarget = this.snapshot.continuousIndex
        this.positionX = this.snapshot.anchor?.x ?? 0.5
        this.positionY = this.snapshot.anchor?.y ?? 0
      }
      const index = this.positionTarget
      const crop = this.snapshot.continuousCrop(index)
      const sourceX = this.positionX
      const sourceY = this.positionY
      const rotated = this.rotates(index)
      const defaultStart = sourceX === 0.5 && sourceY === 0
      const sourcePosition = rotated ? (defaultStart ? crop.left : sourceX) : sourceY
      const start = rotated ? crop.left : crop.top
      const end = rotated ? crop.right : crop.bottom
      const y = this.snapshot.kind === 'original'
        ? Math.max(0, Math.min(1, (sourcePosition - start) / (1 - start - end))) : 0
      const geometryRevision = this.geometryRevision
      const width = this.viewWidth
      const height = this.imageHeight(index)
      const rowHeight = this.rowHeight(index)
      const inset = (rowHeight - height) / 2
      this.positionInFlight = true
      this.scroller.scrollToIndex(index, false, ScrollAlign.START,
        { extraOffset: LengthMetrics.vp(inset + height * y) })
      // scrollToIndex schedules native layout; old getItemRect data is not the
      // requested position. Keep input/observations gated until a frame finishes.
      this.getUIContext().postFrameCallback(new ReaderContinuousAfterLayout((): void => {
        if (this.disposed || epoch !== this.positionEpoch || navigation !== this.snapshot.navigationRevision) return
        if (geometryRevision !== this.geometryRevision || width !== this.viewWidth || height !== this.imageHeight(index) || rowHeight !== this.rowHeight(index)) {
          this.invalidatePosition()
          this.schedulePosition()
          return
        }
        this.positionInFlight = false
        if (!this.active) return
        this.pendingPosition = false
        this.refreshEntryPosition()
        this.scheduleMeasure()
      }))
    }, 0)
  }

  /** Match the established webtoon page-end rule from actual body rectangles.
   * A fully visible short last page can own progress while an earlier page still
   * peeks above it. No isAtEnd or total-scroll estimate grants an observation.
   */
  private measuredPosition(start: number, end: number): number {
    for (let index = end; index >= start; index--) {
      const rect = this.scroller.getItemRect(index)
      // This row's aspect-ratio Stack is the drawable body. Native layout
      // rounds its height to pixels; recomputing width / ratio can put a fully
      // visible last row fractionally beyond the viewport and strand progress.
      const top = rect.y
      const bottom = top + rect.height
      if (rect.height > 0 && top < this.viewHeight && bottom > 0 &&
        (bottom <= this.viewHeight || top < 0)) return index
    }
    return start
  }

  private scheduleMeasure(): void {
    if (this.measureTimer !== 0 || !this.active || this.pendingPosition || !this.fullyVisible || this.lockedKey.length > 0) return
    const navigation = this.snapshot.navigationRevision
    this.measureTimer = setTimeout((): void => {
      this.measureTimer = 0
      if (!this.active || this.pendingPosition || !this.fullyVisible || this.lockedKey.length > 0 || navigation !== this.snapshot.navigationRevision ||
        this.snapshot.phase !== 'ready') return
      const hit = this.scroller.getItemIndex(this.viewWidth / 2, 1)
      if (hit >= 0) this.first = hit
      const endHit = this.scroller.getItemIndex(this.viewWidth / 2, Math.max(1, this.viewHeight - 1))
      if (endHit >= 0) this.last = endHit
      const last = Math.max(this.first, this.last)
      let first = this.measuredPosition(this.first, last)
      const target = this.positionTarget
      if (target >= this.first && target <= last) {
        const targetRect = this.scroller.getItemRect(target)
        if (targetRect.height > 0 && targetRect.y < this.viewHeight && targetRect.y + targetRect.height > 0) first = target
      }
      this.onRange(this.first, last, this.createdRevision, navigation, first)
      const key = this.snapshot.displayKeys[first]
      const frame = this.snapshot.forItem(key).frames[0]
      if (frame === undefined || frame.cropPending || frame.asset.kind !== 'original' || frame.asset.phase !== 'displayed' ||
        this.nativeReady.get(key) !== `${frame.slotId}:${frame.asset.assetRequestId}`) return
      const rect = this.scroller.getItemRect(first)
      const imageHeight = this.imageHeight(first)
      const imageTop = rect.y + (rect.height - imageHeight) / 2
      if (rect.height <= 0 || imageTop >= this.viewHeight || imageTop + imageHeight <= 0) return
      const y = Math.max(0, Math.min(1, -imageTop / imageHeight))
      const region = frame.crop.region(frame.part)
      const rotated = this.rotates(first)
      this.onVisible(this.createdRevision, navigation, key, frame.slotId, frame.asset.assetRequestId,
        rotated ? region.sourceX(y) : region.sourceX(0.5),
        rotated ? region.sourceY(0.5) : region.sourceY(y))
    }, 0)
  }

  build() {
    List({ initialIndex: this.snapshot.continuousIndex, scroller: this.scroller,
      space: normalizedReaderPageGap(this.pageGap) }) {
      LazyForEach(this.source, (key: string) => {
        ListItem() {
          ReaderContinuousCell({
            imageInterpolation: this.imageInterpolation, loadingInk: this.loadingInk,
            doubleTapEnabled: this.doubleTapEnabled, doubleTapIntervalMs: this.doubleTapIntervalMs,
            snapshot: this.cellSnapshots.forItem(this.snapshot, key, this.entryTransition?.pending() !== true),
            entryTransition: this.entryTransition,
            entryPosition: this.entryPosition?.key === key ? this.entryPosition : null,
            active: this.active,
            zoomResetCommand: this.zoomResetCommand?.topologyRevision === this.createdRevision ? this.zoomResetCommand : null,
            onTap: (x: number, y: number): void => this.imageTap(key, x, y),
            interactionAllowed: !this.pendingPosition && this.fullyVisible &&
              (this.lockedKey.length === 0 || this.lockedKey === key),
            onLock: (identity: string, locked: boolean): void => { this.onImageLock(key, identity, locked) },
            onZoomedChange: (identity: string, zoomed: boolean): void => { this.onImageZoomed(key, identity, zoomed) },
            imageHeight: this.imageHeight(this.snapshot.displayKeys.indexOf(key)),
            imageAspectRatio: this.imageAspectRatio(this.snapshot.displayKeys.indexOf(key)),
            rotateClockwise: this.rotates(this.snapshot.displayKeys.indexOf(key)),
            onRetry: (slot: number, request: number): void => {
              this.onRetry(this.createdRevision, key, slot, request)
            },
            onNoticeAction: (slot: number, request: number, noticeId: string): Promise<boolean> => {
              return this.onNoticeAction(this.createdRevision, this.snapshot.navigationRevision,
                key, slot, request, noticeId)
            },
            onPresented: (slot: number, request: number, success: boolean, width: number, height: number): void => {
              const current = this.snapshot.forItem(key).frames[0]
              if (current === undefined || current.slotId !== slot || current.asset.assetRequestId !== request) return
              if (!success) this.nativeReady.delete(key)
              this.onPresented(slot, request, success, width, height)
              this.scheduleMeasure()
            },
            onDecodedOriginal: (slot: number, request: number): void => {
              const current = this.snapshot.forItem(key).frames[0]
              if (current === undefined || current.slotId !== slot || current.asset.assetRequestId !== request) return
              this.nativeReady.set(key, `${slot}:${request}`)
              this.scheduleMeasure()
            },
            onRetired: (slot: number, request: number): void => {
              if (this.nativeReady.get(key) === `${slot}:${request}`) this.nativeReady.delete(key)
            },
            onFailed: (slot: number, request: number, fragment: ReaderFragment): void => {
              if (this.nativeReady.get(key) === `${slot}:${request}`) this.nativeReady.delete(key)
              this.onFailed(this.createdRevision, key, slot, request, fragment)
            },
          })
        }
          .zIndex(this.lockedKey === key ? 1 : 0)
          .onAreaChange((_old: Area, area: Area): void => {
            this.onRowGeometry(key, Number(area.height))
          })
      }, (key: string): string => readerElementKey(key))
    }
    .width('100%').height('100%').cachedCount(this.snapshot.nativeCacheDepth)
    .scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
    .maintainVisibleContentPosition(true)
    .enableScrollInteraction(this.active && this.snapshot.phase === 'ready' && !this.pendingPosition && this.lockedKey.length === 0)
    .id('rkit-continuous-list')
    .onTouch((event: TouchEvent): void => { this.handleBoundaryTouch(event) })
    .onAreaChange((_old: Area, area: Area): void => {
      const width = Math.max(1, Number(area.width))
      if (this.viewWidth !== width || (this.entryTransition?.pending() === true &&
        this.viewHeight !== Math.max(1, Number(area.height)))) {
        if (this.viewWidth > 1 && this.entryTransition?.target !== null) this.entryTransition?.cancel()
        this.invalidatePosition()
      }
      this.viewWidth = width
      this.viewHeight = Math.max(1, Number(area.height))
      if (this.pendingPosition) this.schedulePosition()
      else this.scheduleMeasure()
    })
    .onVisibleAreaChange([0, 1], (_expanding: boolean, ratio: number): void => {
      this.fullyVisible = ratio >= 1
      this.scheduleMeasure()
    })
    .onScrollIndex((start: number, end: number): void => {
      this.first = start
      this.last = end
      this.scheduleMeasure()
    })
    .onWillScroll((_offset: number, _state: ScrollState, _source: ScrollSource): void => {
      this.releasePosition()
    })
    .onDidScroll((_offset: number, state: ScrollState): void => {
      if (!this.pendingPosition && !this.positionInFlight && state !== ScrollState.Idle) this.entryTransition?.cancel()
      this.moving = state !== ScrollState.Idle
      this.scheduleMeasure()
    })
    .onScrollStop((): void => { this.moving = false; this.scheduleMeasure() })
  }

}

@ComponentV2
struct ReaderContinuousCell {
  @Param loadingInk: ResourceColor = Color.White
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Param doubleTapEnabled: boolean = true
  @Param doubleTapIntervalMs: number = 300
  @Param entryTransition: ReaderEntryTransition | null = null
  @Param entryPosition: ReaderContinuousEntryPosition | null = null
  @Require @Param snapshot: ReaderContinuousCellSnapshot
  @Require @Param imageHeight: number
  @Require @Param imageAspectRatio: number
  @Param rotateClockwise: boolean = false
  @Require @Param active: boolean
  @Param zoomResetCommand: ReaderZoomResetCommand | null = null
  @Event onTap: (windowX: number, windowY: number) => void = () => {}
  @Require @Param interactionAllowed: boolean
  @Event onLock: (identity: string, locked: boolean) => void = () => {}
  @Event onZoomedChange: (identity: string, zoomed: boolean) => void = () => {}
  @Event onPresented: (slot: number, request: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onFailed: (slot: number, request: number, fragment: ReaderFragment) => void = () => {}
  // Core may receive dimensions before the row has applied them. Only this
  // actual drawable receipt allows continuous visibility and old-chapter retirement.
  @Event onDecodedOriginal: (slot: number, request: number) => void = () => {}
  @Event onRetired: (slot: number, request: number) => void = () => {}
  @Event onRetry: (slot: number, request: number) => void = () => {}
  @Event onNoticeAction: (slot: number, request: number, noticeId: string) => Promise<boolean> =
    async (_slot: number, _request: number, _noticeId: string): Promise<boolean> => false
  @Local private noticeActionBusy: boolean = false
  @Local private decodedOriginalIdentity: string = ''
  private terminalTapSequence: ReaderTapSequence = new ReaderTapSequence()
  private terminalTapIdentity: string = ''
  private terminalTapArbiter: ReaderTapArbiter = new ReaderTapArbiter(
    (point: ReaderTapPoint): void => {
      if (this.active && this.interactionAllowed && this.terminalTapIdentity === this.terminalIdentity()) {
        this.onTap(point.windowX, point.windowY)
      }
    }, (_point: ReaderTapPoint): void => {})

  private terminalIdentity(): string {
    return `${this.snapshot.navigationRevision}:${this.snapshot.displayIndex}:` +
      `${this.snapshot.frames[0]?.slotId ?? -1}:${this.snapshot.frames[0]?.asset.assetRequestId ?? -1}`
  }

  @Monitor('snapshot', 'active', 'interactionAllowed')
  onTerminalStateChanged(): void {
    if (!this.active || !this.interactionAllowed || this.terminalTapIdentity !== this.terminalIdentity()) {
      this.terminalTapArbiter.cancel()
    }
  }

  @Monitor('doubleTapEnabled', 'doubleTapIntervalMs')
  onTerminalPreferenceChanged(): void { this.terminalTapArbiter.cancel() }

  aboutToDisappear(): void { this.terminalTapArbiter.cancel() }

  private terminalTouch(event: TouchEvent): void {
    this.terminalTapSequence.touch(event)
    if (event.type === TouchType.Down && this.terminalTapSequence.allowed()) {
      const point = event.touches[0]
      if (point !== undefined) this.terminalTapArbiter.down(point.x, point.y)
    } else if (!this.terminalTapSequence.allowed()) this.terminalTapArbiter.cancel()
  }

  private originalDrawableIdentity(): string {
    const frame = this.snapshot.frames[0]
    if (frame === undefined) return ''
    return `${frame.slotId}:${frame.asset.assetRequestId}:` +
      `${frame.part.sourceIndex}:${frame.part.fragment}:${frame.asset.visualRevision}`
  }

  private originalDecoded(identity: string): void {
    if (this.snapshot.frames[0]?.asset.kind === 'original' && identity === this.originalDrawableIdentity()) {
      this.decodedOriginalIdentity = identity
      const frame = this.snapshot.frames[0]
      this.onDecodedOriginal(frame.slotId, frame.asset.assetRequestId)
    }
  }

  private imagePresentation(): ReaderImagePresentation {
    return new ReaderImagePresentation(this.snapshot.frames[0] ?? null, this.decodedOriginalIdentity,
      this.entryTransition)
  }

  private loadingVisible(): boolean { return this.imagePresentation().loading }

  private terminalTap(event?: GestureEvent): void {
    const location = event?.tapLocation
    if (this.active && this.interactionAllowed && this.terminalTapSequence.allowed() &&
      location !== undefined && Number.isFinite(location.x) && Number.isFinite(location.y) &&
      Number.isFinite(location.windowX) && Number.isFinite(location.windowY)) {
      this.terminalTapIdentity = this.terminalIdentity()
      this.terminalTapArbiter.tap(new ReaderTapPoint(location.x, location.y, location.windowX, location.windowY),
        this.doubleTapEnabled, this.doubleTapIntervalMs)
    }
  }

  private async resolveNoticeAction(frame: ReaderPagedFrame): Promise<void> {
    const notice = frame.asset.notice
    if (notice === null || this.noticeActionBusy) return
    this.noticeActionBusy = true
    try {
      await this.onNoticeAction(frame.slotId, frame.asset.assetRequestId, notice.id)
    } finally {
      this.noticeActionBusy = false
    }
  }

  build() {
    if (this.snapshot.frames[0]?.asset.phase === 'suppressed' && this.snapshot.frames[0].asset.notice !== null) {
      Stack() {
        ForEach(this.snapshot.frames, (frame: ReaderPagedFrame) => {
          ReaderAssetNoticePanel({
            notice: frame.asset.notice as ReaderAssetNotice,
            page: frame.part.sourceIndex + 1,
            compact: true,
            actionBusy: this.noticeActionBusy,
            onAction: (): void => { void this.resolveNoticeAction(frame) },
          })
        }, (frame: ReaderPagedFrame): string =>
          readerElementKey(`${frame.slotId}:${frame.asset.assetRequestId}`))
      }.width('100%').height(220).id(`rkit-continuous-page-${this.snapshot.displayIndex}`)
        .onTouch((event: TouchEvent): void => { this.terminalTouch(event) })
        .gesture(TapGesture({ count: 1 }).onAction((event?: GestureEvent): void => { this.terminalTap(event) }))
    } else if (this.snapshot.frames[0]?.asset.phase === 'failed') {
      Stack() {
        ForEach(this.snapshot.frames, (frame: ReaderPagedFrame) => {
          ReaderFailurePanel({
            page: frame.part.sourceIndex + 1, compact: true, retryEnabled: this.active,
            failure: frame.asset.failure,
            // Failed acquisition can keep assetRequestId=0 across attempts; read the current epoch.
            onRetry: (): void => { this.onRetry(frame.slotId, this.snapshot.frames[0].asset.requestId) },
          })
        }, (frame: ReaderPagedFrame): string =>
          readerElementKey(`${frame.slotId}:${frame.asset.assetRequestId}`))
      }.width('100%').height(220).id(`rkit-continuous-page-${this.snapshot.displayIndex}`)
        .onTouch((event: TouchEvent): void => { this.terminalTouch(event) })
        .gesture(TapGesture({ count: 1 }).onAction((event?: GestureEvent): void => { this.terminalTap(event) }))
    } else {
      Stack() {
        ForEach(this.snapshot.frames, (frame: ReaderPagedFrame) => {
          ReaderContinuousZoomImage({
            imageInterpolation: this.imageInterpolation,
            doubleTapEnabled: this.doubleTapEnabled, doubleTapIntervalMs: this.doubleTapIntervalMs,
            frame: this.snapshot.frames[0], navigation: this.snapshot.navigationRevision,
            entryTransition: this.entryTransition, entryPosition: this.entryPosition,
            imageHeight: this.imageHeight, active: this.active, interactionAllowed: this.interactionAllowed,
            zoomResetCommand: this.zoomResetCommand,
            rotateClockwise: this.rotateClockwise,
            onLock: this.onLock,
            onZoomedChange: this.onZoomedChange,
            onTap: this.onTap,
            onDecodedOriginal: (identity: string): void => { this.originalDecoded(identity) },
            onPresented: this.onPresented,
            onFailed: this.onFailed,
          })
            .opacity(this.imagePresentation().pixels ? 1 : 0)
            .onDisAppear((): void => { this.onRetired(frame.slotId, frame.asset.assetRequestId) })
        }, (frame: ReaderPagedFrame): string =>
          readerElementKey(`${frame.slotId}`))
        ReaderImagePlaceholder({ loadingInk: this.loadingInk, presentation: this.imagePresentation(),
          frame: this.snapshot.frames[0] ?? null,
          entryTransition: this.entryTransition }).zIndex(2)
      }.width('100%').aspectRatio(this.imageAspectRatio)
        .id(`rkit-continuous-page-${this.snapshot.displayIndex}`)
    }
  }
}
