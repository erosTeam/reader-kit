import { FrameCallback, LengthMetrics } from '@kit.ArkUI'
import { ReaderPagedSnapshot, ReaderPagedFrame, ReaderFragment } from '@reader-kit/core'
import { ReaderContinuousZoomImage } from './ReaderContinuousZoomImage'
import { ReaderFailurePanel } from './ReaderFailurePanel'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { ReaderContinuousEntryPosition } from './ReaderContinuousEntryPosition'
import { ReaderTapAction } from './ReaderTapAction'

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
  @Param entryTransition: ReaderEntryTransition | null = null
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Event onInputLockChange: (locked: boolean, topology: number) => void = () => {}
  @Event onTap: (xFraction: number, yFraction: number) => ReaderTapAction = () => 'none'
  @Event onRange: (start: number, end: number, topology: number, navigation: number) => void = () => {}
  @Event onPresented: (slot: number, request: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (topology: number, navigation: number, key: string, slot: number, request: number, x: number, y: number) => void = () => {}
  @Event onFailed: (topology: number, key: string, slot: number, request: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (topology: number, key: string, slot: number, request: number) => void = () => {}

  build() {
    Stack() {
      if (this.snapshot.displayCount > 0) {
        ForEach([this.snapshot.topologyRevision], (revision: number) => {
          ReaderContinuousList({
            imageInterpolation: this.imageInterpolation,
            snapshot: this.snapshot, active: this.active, createdRevision: revision,
            entryTransition: this.entryTransition,
            onInputLockChange: this.onInputLockChange,
            onRange: this.onRange, onPresented: this.onPresented, onVisible: this.onVisible, onFailed: this.onFailed,
            onRetry: this.onRetry,
            onTap: this.onTap,
          })
        }, (revision: number): string => `${revision}`)
      } else if (this.snapshot.phase === 'idle' || this.snapshot.phase === 'catalog') {
        LoadingProgress().width(32).height(32)
      }
    }.width('100%').height('100%').clip(true)
  }
}

@ComponentV2
struct ReaderContinuousList {
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Param entryTransition: ReaderEntryTransition | null = null
  @Local private entryPosition: ReaderContinuousEntryPosition | null = null
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Event onInputLockChange: (locked: boolean, topology: number) => void = () => {}
  @Event onTap: (xFraction: number, yFraction: number) => ReaderTapAction = () => 'none'
  @Require @Param createdRevision: number
  @Event onRange: (start: number, end: number, topology: number, navigation: number) => void = () => {}
  @Event onPresented: (slot: number, request: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (topology: number, navigation: number, key: string, slot: number, request: number, x: number, y: number) => void = () => {}
  @Event onFailed: (topology: number, key: string, slot: number, request: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (topology: number, key: string, slot: number, request: number) => void = () => {}
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
  private cropRegions: Map<number, string> = new Map()

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
        this.lockedIdentity !== `${this.snapshot.navigationRevision}:${frame.slotId}:${frame.asset.assetRequestId}`) {
        this.lockedKey = ''
        this.lockedIdentity = ''
      }
    }
    if (this.lastNavigation !== this.snapshot.navigationRevision) {
      this.lastNavigation = this.snapshot.navigationRevision
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
    return width > 0 && height > 0 ? width / height / heightRatio : 0.75
  }

  private imageHeight(index: number): number { return this.viewWidth / this.imageAspectRatio(index) }

  private rowHeight(index: number): number {
    const frame = this.snapshot.forItem(this.snapshot.displayKeys[index]).frames[0]
    return frame?.asset.phase === 'failed' ? 220 : Math.max(220, this.imageHeight(index))
  }

  private onImageLock(key: string, identity: string, locked: boolean): void {
    const frame = this.snapshot.forItem(key).frames[0]
    if (frame === undefined || identity !== `${this.snapshot.navigationRevision}:${frame.slotId}:${frame.asset.assetRequestId}`) return
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
      const sourceY = this.snapshot.anchor?.y ?? 0
      const y = this.snapshot.kind === 'original'
        ? Math.max(0, Math.min(1, (sourceY - crop.top) / (1 - crop.top - crop.bottom))) : 0
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
      this.onVisible(this.createdRevision, navigation, key, frame.slotId, frame.asset.assetRequestId,
        region.sourceX(0.5), region.sourceY(y))
    }, 0)
  }

  build() {
    List({ initialIndex: this.snapshot.displayIndex, scroller: this.scroller }) {
      LazyForEach(this.source, (key: string) => {
        ListItem() {
          ReaderContinuousCell({
            imageInterpolation: this.imageInterpolation,
            snapshot: this.snapshot.forItem(key),
            entryTransition: this.entryTransition,
            entryPosition: this.entryPosition?.key === key ? this.entryPosition : null,
            active: this.active,
            onTap: (x: number, y: number): void => this.imageTap(key, x, y),
            interactionAllowed: !this.pendingPosition && this.fullyVisible &&
              (this.lockedKey.length === 0 || this.lockedKey === key),
            onLock: (identity: string, locked: boolean): void => { this.onImageLock(key, identity, locked) },
            imageHeight: this.imageHeight(this.snapshot.displayKeys.indexOf(key)),
            imageAspectRatio: this.imageAspectRatio(this.snapshot.displayKeys.indexOf(key)),
            onRetry: (slot: number, request: number): void => {
              this.onRetry(this.createdRevision, key, slot, request)
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
      }, (key: string): string => key)
    }
    .width('100%').height('100%').cachedCount(1)
    .scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
    .enableScrollInteraction(this.active && this.snapshot.phase === 'ready' && !this.pendingPosition && this.lockedKey.length === 0)
    .id('rkit-continuous-list')
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
  @Require @Param active: boolean
  @Event onTap: (windowX: number, windowY: number) => void = () => {}
  @Require @Param interactionAllowed: boolean
  @Event onLock: (identity: string, locked: boolean) => void = () => {}
  @Event onPresented: (slot: number, request: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onFailed: (slot: number, request: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetired: (slot: number, request: number) => void = () => {}
  @Event onRetry: (slot: number, request: number) => void = () => {}

  build() {
    if (this.snapshot.frames[0]?.asset.phase === 'failed') {
      Stack() {
        ForEach(this.snapshot.frames, (frame: ReaderPagedFrame) => {
          ReaderFailurePanel({
            page: frame.part.sourceIndex + 1, compact: true, retryEnabled: this.active,
            // Failed acquisition can keep assetRequestId=0 across attempts; read the current epoch.
            onRetry: (): void => { this.onRetry(frame.slotId, this.snapshot.frames[0].asset.requestId) },
          })
        }, (frame: ReaderPagedFrame): string => `${frame.slotId}:${frame.asset.assetRequestId}`)
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
              onLock: this.onLock,
              onTap: this.onTap,
              onPresented: this.onPresented,
              onFailed: this.onFailed,
            })
              .onDisAppear((): void => { this.onRetired(frame.slotId, frame.asset.assetRequestId) })
          }
        }, (frame: ReaderPagedFrame): string => `${frame.slotId}:${frame.asset.assetRequestId}`)
        if (this.snapshot.frames.length === 0 || this.snapshot.frames[0].asset.phase === 'idle' ||
          this.snapshot.frames[0].asset.phase === 'asset' || this.snapshot.frames[0].asset.phase === 'decoding') {
          LoadingProgress().width(32).height(32)
        }
      }.width('100%').aspectRatio(this.imageAspectRatio)
        .id(`rkit-continuous-page-${this.snapshot.displayIndex}`)
    }
  }
}
