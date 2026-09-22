import { FrameCallback, LengthMetrics } from '@kit.ArkUI'
import { ReaderPagedSnapshot, ReaderPagedFrame, ReaderFragment, ReaderAssetNotice, readerPolicyRotatesPage } from '@reader-kit/core'
import { ReaderContinuousZoomImage } from './ReaderContinuousZoomImage'
import { ReaderFailurePanel } from './ReaderFailurePanel'
import { ReaderAssetNoticePanel } from './ReaderAssetNoticePanel'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { ReaderContinuousEntryPosition } from './ReaderContinuousEntryPosition'
import { ReaderTapAction } from './ReaderTapAction'
import { ReaderBoundaryDirection, ReaderBoundarySwipe } from './ReaderBoundarySwipe'
import { normalizedReaderPageGap } from './ReaderPageGap'
import { ReaderLoadingStage } from './ReaderLoadingStage'
import { ReaderZoomResetCommand } from './ReaderZoomResetCommand'
import { readerElementKey } from './ReaderElementKey'

class ReaderContinuousIndexSource implements IDataSource {
  private keys: string[]
  constructor(keys: string[]) { this.keys = keys.slice() }
  totalCount(): number { return this.keys.length }
  getData(index: number): string { return this.keys[index] }
  registerDataChangeListener(_listener: DataChangeListener): void {}
  unregisterDataChangeListener(_listener: DataChangeListener): void {}
}

class ReaderContinuousAfterLayout extends FrameCallback {
  private action: () => void
  constructor(action: () => void) { super(); this.action = action }
  onIdle(_remaining: number): void { this.action() }
}

/** Continuous layout only. Host navigation, commands and resource ownership stay outside. */
@ComponentV2
export struct ReaderContinuousSurface {
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Param pageGap: number = 0
  @Param entryTransition: ReaderEntryTransition | null = null
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Param zoomResetCommand: ReaderZoomResetCommand | null = null
  @Event onInputLockChange: (locked: boolean, topology: number) => void = () => {}
  @Event onZoomedChange: (zoomed: boolean, topology: number, navigation: number) => void = () => {}
  @Event onTap: (xFraction: number, yFraction: number) => ReaderTapAction = () => 'none'
  @Event onRange: (start: number, end: number, topology: number, navigation: number) => void = () => {}
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
      if (this.snapshot.displayCount > 0) {
        ForEach([this.snapshot.topologyRevision], (revision: number) => {
          ReaderContinuousList({
            imageInterpolation: this.imageInterpolation,
            pageGap: this.pageGap,
            snapshot: this.snapshot, active: this.active, createdRevision: revision,
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
        ReaderLoadingStage({ label: $r('app.string.rkit_loading_resolving') })
      }
    }.width('100%').height('100%').clip(true)
  }
}

@ComponentV2
struct ReaderContinuousList {
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
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
  @Event onRange: (start: number, end: number, topology: number, navigation: number) => void = () => {}
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
  private disposed: boolean = false
  private measureTimer: number = 0
  private first: number = 0
  private last: number = 0
  @Local private lockedKey: string = ''
  @Local private moving: boolean = false
  private lockedIdentity: string = ''
  private zoomedKey: string = ''
  private zoomedIdentity: string = ''
  private cropRegions: Map<number, string> = new Map()
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
        atEnd = this.last + 1 >= this.snapshot.displayCount && this.scroller.isAtEnd()
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
    this.first = this.snapshot.displayIndex
    this.last = this.first
    this.reportExternalLock()
  }

  aboutToDisappear(): void {
    this.disposed = true
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
    const entryFrame = this.snapshot.frames.find((frame: ReaderPagedFrame): boolean =>
      this.entryTransition?.matches(frame.part) === true)
    if (entryFrame?.asset.phase === 'failed') this.entryTransition?.cancel()
    if (this.entryPosition !== null && entryFrame !== undefined &&
      this.entryPosition.height !== this.imageHeight(entryFrame.part.sourceIndex)) this.invalidatePosition()
    let cropChanged = false
    this.snapshot.pageMetadata.forEach((page) => {
      const crop = this.snapshot.cropForPage(page.sourceIndex)
      const value = `${crop.left}:${crop.top}:${crop.right}:${crop.bottom}`
      const previous = this.cropRegions.get(page.sourceIndex)
      if (previous !== undefined && previous !== value) cropChanged = true
      this.cropRegions.set(page.sourceIndex, value)
    })
    if (cropChanged) this.invalidatePosition()
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
    const frame = this.snapshot.forItem(this.snapshot.displayKeys[this.snapshot.displayIndex]).frames[0]
    if (frame === undefined || !entry.matches(frame.part)) return
    if (frame.asset.phase === 'failed') { entry.cancel(); return }
    const width = this.viewWidth
    const height = this.imageHeight(frame.part.sourceIndex)
    const previous = this.entryPosition
    if (previous !== null && previous.matches(this.snapshot) && previous.width === width && previous.height === height) return
    const epoch = this.positionEpoch
    const token: ReaderContinuousEntryPosition = new ReaderContinuousEntryPosition(epoch, this.snapshot, frame, width, height, entry, (): boolean =>
      this.entryPosition === token && !this.disposed && this.active && !this.pendingPosition &&
      !this.positionInFlight && !this.moving && this.lockedKey.length === 0 && this.positionEpoch === epoch && token.matches(this.snapshot) &&
      this.viewWidth === width && this.imageHeight(frame.part.sourceIndex) === height)
    this.entryPosition = token
  }

  private imageTap(key: string, windowX: number, windowY: number): void {
    if (!this.active || this.disposed || this.pendingPosition || this.positionInFlight || !this.fullyVisible ||
      this.moving || (this.lockedKey.length > 0 && this.lockedKey !== key) || this.snapshot.phase !== 'ready' ||
      this.createdRevision !== this.snapshot.topologyRevision || this.entryTransition?.pending() ||
      !Number.isFinite(windowX) || !Number.isFinite(windowY)) return
    const frame = this.snapshot.forItem(key).frames[0]
    if (frame === undefined || frame.asset.phase !== 'displayed') return
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
      if (action === 'previous' || action === 'left') this.scroller.scrollBy(0, -height * 0.75)
      else if (action === 'next' || action === 'right') this.scroller.scrollBy(0, height * 0.75)
    } catch (_) { /* A missing current viewport is not permission to infer a tap position. */ }
  }

  private imageAspectRatio(index: number): number {
    const page = this.snapshot.pageMetadata.find((value) => value.sourceIndex === index)
    const width = this.snapshot.kind === 'thumbnail' ? page?.thumbnail.width ?? 0 : page?.width ?? 0
    const height = this.snapshot.kind === 'thumbnail' ? page?.thumbnail.height ?? 0 : page?.height ?? 0
    const crop = this.snapshot.cropForPage(index)
    const heightRatio = this.snapshot.kind === 'original'
      ? (1 - crop.top - crop.bottom) / (1 - crop.left - crop.right) : 1
    const ratio = width > 0 && height > 0 ? width / height / heightRatio : 0.75
    if (!readerPolicyRotatesPage(this.snapshot.policy, page ?? null)) return ratio
    const originalRatio = page !== undefined && page.width > 0 && page.height > 0
      ? page.width / page.height / ((1 - crop.top - crop.bottom) / (1 - crop.left - crop.right)) : 0
    return originalRatio > 0 ? 1 / originalRatio : 0.75
  }

  private rotates(index: number): boolean {
    const page = this.snapshot.pageMetadata.find((value) => value.sourceIndex === index)
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

  private schedulePosition(): void {
    if (this.positionTimer !== 0 || this.positionInFlight || this.disposed || !this.active ||
      this.viewWidth <= 1 || this.snapshot.phase !== 'ready') return
    const navigation = this.snapshot.navigationRevision
    const epoch = this.positionEpoch
    this.positionTimer = setTimeout((): void => {
      this.positionTimer = 0
      if (this.disposed || !this.active || epoch !== this.positionEpoch || navigation !== this.snapshot.navigationRevision) return
      const index = this.snapshot.displayIndex
      const crop = this.snapshot.cropForPage(index)
      const sourceX = this.snapshot.anchor?.x ?? 0.5
      const sourceY = this.snapshot.anchor?.y ?? 0
      const rotated = this.rotates(index)
      const defaultStart = sourceX === 0.5 && sourceY === 0
      const sourcePosition = rotated ? (defaultStart ? crop.left : sourceX) : sourceY
      const start = rotated ? crop.left : crop.top
      const end = rotated ? crop.right : crop.bottom
      const y = this.snapshot.kind === 'original'
        ? Math.max(0, Math.min(1, (sourcePosition - start) / (1 - start - end))) : 0
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
        if (width !== this.viewWidth || height !== this.imageHeight(index) || rowHeight !== this.rowHeight(index)) {
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
      const first = this.first
      const last = Math.max(first, this.last)
      this.onRange(first, last, this.createdRevision, navigation)
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
    List({ initialIndex: this.snapshot.displayIndex, scroller: this.scroller,
      space: normalizedReaderPageGap(this.pageGap) }) {
      LazyForEach(this.source, (key: string) => {
        ListItem() {
          ReaderContinuousCell({
            imageInterpolation: this.imageInterpolation,
            snapshot: this.snapshot.forItem(key),
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
              if (success) this.nativeReady.set(key, `${slot}:${request}`)
              else this.nativeReady.delete(key)
              this.onPresented(slot, request, success, width, height)
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
      }, (key: string): string => readerElementKey(key))
    }
    .width('100%').height('100%').cachedCount(1)
    .scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
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
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Param entryTransition: ReaderEntryTransition | null = null
  @Param entryPosition: ReaderContinuousEntryPosition | null = null
  @Require @Param snapshot: ReaderPagedSnapshot
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
  @Event onRetired: (slot: number, request: number) => void = () => {}
  @Event onRetry: (slot: number, request: number) => void = () => {}
  @Event onNoticeAction: (slot: number, request: number, noticeId: string) => Promise<boolean> =
    async (_slot: number, _request: number, _noticeId: string): Promise<boolean> => false
  @Local private noticeActionBusy: boolean = false

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
    } else {
      Stack() {
        ForEach(this.snapshot.frames, (frame: ReaderPagedFrame) => {
          if (this.snapshot.frames[0].asset.uri.length > 0) {
            ReaderContinuousZoomImage({
              imageInterpolation: this.imageInterpolation,
              frame: this.snapshot.frames[0], navigation: this.snapshot.navigationRevision,
              entryTransition: this.entryTransition, entryPosition: this.entryPosition,
              imageHeight: this.imageHeight, active: this.active, interactionAllowed: this.interactionAllowed,
              zoomResetCommand: this.zoomResetCommand,
              rotateClockwise: this.rotateClockwise,
              onLock: this.onLock,
              onZoomedChange: this.onZoomedChange,
              onTap: this.onTap,
              onPresented: this.onPresented,
              onFailed: this.onFailed,
            })
              .onDisAppear((): void => { this.onRetired(frame.slotId, frame.asset.assetRequestId) })
          }
        }, (frame: ReaderPagedFrame): string =>
          readerElementKey(`${frame.slotId}:${frame.asset.assetRequestId}`))
        if (this.snapshot.frames.length === 0 || this.snapshot.frames[0].asset.phase === 'idle' ||
          this.snapshot.frames[0].asset.phase === 'asset' || this.snapshot.frames[0].asset.phase === 'decoding') {
          ReaderLoadingStage({
            label: this.snapshot.frames.length === 0 || this.snapshot.frames[0].asset.phase === 'idle'
              ? $r('app.string.rkit_loading_resolving')
              : this.snapshot.frames[0].asset.phase === 'decoding'
                ? $r('app.string.rkit_loading_decoding')
                  : $r('app.string.rkit_loading_image'),
            loaded: this.snapshot.frames.length === 0 ? 0 : this.snapshot.frames[0].asset.loadProgressLoaded,
            total: this.snapshot.frames.length === 0 ? 0 : this.snapshot.frames[0].asset.loadProgressTotal,
          })
        }
      }.width('100%').aspectRatio(this.imageAspectRatio)
        .id(`rkit-continuous-page-${this.snapshot.displayIndex}`)
    }
  }
}
