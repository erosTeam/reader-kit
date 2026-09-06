import { LengthMetrics } from '@kit.ArkUI'
import { ReaderPagedSnapshot, ReaderPagedFrame, ReaderFragment } from '@reader-kit/core'
import { ReaderPagedImage } from './ReaderPagedViewport'
import { ReaderFailurePanel } from './ReaderFailurePanel'

class ReaderContinuousIndexSource implements IDataSource {
  private keys: string[]
  constructor(keys: string[]) { this.keys = keys.slice() }
  totalCount(): number { return this.keys.length }
  getData(index: number): string { return this.keys[index] }
  registerDataChangeListener(_listener: DataChangeListener): void {}
  unregisterDataChangeListener(_listener: DataChangeListener): void {}
}

/** Continuous layout only. Host navigation, commands and resource ownership stay outside. */
@ComponentV2
export struct ReaderContinuousSurface {
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
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
            snapshot: this.snapshot, active: this.active, createdRevision: revision,
            onRange: this.onRange, onPresented: this.onPresented, onVisible: this.onVisible, onFailed: this.onFailed,
            onRetry: this.onRetry,
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
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
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
  private fullyVisible: boolean = false
  private lastNavigation: number = -1
  @Local private pendingPosition: boolean = true
  private positionTimer: number = 0
  private measureTimer: number = 0
  private first: number = 0
  private last: number = 0

  aboutToAppear(): void {
    this.source = new ReaderContinuousIndexSource(this.snapshot.displayKeys)
    this.lastNavigation = this.snapshot.navigationRevision
    this.first = this.snapshot.displayIndex
    this.last = this.first
  }

  aboutToDisappear(): void {
    if (this.positionTimer !== 0) clearTimeout(this.positionTimer)
    if (this.measureTimer !== 0) clearTimeout(this.measureTimer)
  }

  @Monitor('snapshot', 'active')
  onSnapshotChanged(): void {
    if (this.lastNavigation !== this.snapshot.navigationRevision) {
      this.lastNavigation = this.snapshot.navigationRevision
      if (this.positionTimer !== 0) clearTimeout(this.positionTimer)
      if (this.measureTimer !== 0) clearTimeout(this.measureTimer)
      this.positionTimer = 0
      this.measureTimer = 0
      this.pendingPosition = true
    }
    if (this.pendingPosition) this.schedulePosition()
    else this.scheduleMeasure()
  }

  private imageHeight(index: number): number {
    const page = this.snapshot.pageMetadata.find((value) => value.sourceIndex === index)
    const width = this.snapshot.kind === 'thumbnail' ? page?.thumbnail.width ?? 0 : page?.width ?? 0
    const height = this.snapshot.kind === 'thumbnail' ? page?.thumbnail.height ?? 0 : page?.height ?? 0
    return width > 0 && height > 0 ? this.viewWidth * height / width : this.viewWidth / 0.75
  }

  private rowHeight(index: number): number {
    const frame = this.snapshot.forItem(this.snapshot.displayKeys[index]).frames[0]
    return frame?.asset.phase === 'failed' ? 220 : Math.max(220, this.imageHeight(index))
  }

  private schedulePosition(): void {
    if (this.positionTimer !== 0 || !this.active || this.viewWidth <= 1 || this.snapshot.phase !== 'ready') return
    const navigation = this.snapshot.navigationRevision
    this.positionTimer = setTimeout((): void => {
      this.positionTimer = 0
      if (!this.active || navigation !== this.snapshot.navigationRevision) return
      const index = this.snapshot.displayIndex
      const y = this.snapshot.kind === 'original' ? this.snapshot.anchor?.y ?? 0 : 0
      const inset = (this.rowHeight(index) - this.imageHeight(index)) / 2
      this.scroller.scrollToIndex(index, false, ScrollAlign.START,
        { extraOffset: LengthMetrics.vp(inset + this.imageHeight(index) * y) })
      this.pendingPosition = false
      this.scheduleMeasure()
    }, 0)
  }

  private scheduleMeasure(): void {
    if (this.measureTimer !== 0 || !this.active || this.pendingPosition || !this.fullyVisible) return
    const navigation = this.snapshot.navigationRevision
    this.measureTimer = setTimeout((): void => {
      this.measureTimer = 0
      if (!this.active || this.pendingPosition || !this.fullyVisible || navigation !== this.snapshot.navigationRevision ||
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
      if (frame === undefined || frame.asset.kind !== 'original' || frame.asset.phase !== 'displayed' ||
        this.nativeReady.get(key) !== `${frame.slotId}:${frame.asset.assetRequestId}`) return
      const rect = this.scroller.getItemRect(first)
      const imageHeight = this.imageHeight(first)
      const imageTop = rect.y + (rect.height - imageHeight) / 2
      if (rect.height <= 0 || imageTop >= this.viewHeight || imageTop + imageHeight <= 0) return
      const y = Math.max(0, Math.min(1, -imageTop / imageHeight))
      this.onVisible(this.createdRevision, navigation, key, frame.slotId, frame.asset.assetRequestId, 0.5, y)
    }, 0)
  }

  build() {
    List({ initialIndex: this.snapshot.displayIndex, scroller: this.scroller }) {
      LazyForEach(this.source, (key: string) => {
        ListItem() {
          ReaderContinuousCell({
            snapshot: this.snapshot.forItem(key),
            active: this.active,
            imageHeight: this.imageHeight(this.snapshot.displayKeys.indexOf(key)),
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
        }.height(this.rowHeight(this.snapshot.displayKeys.indexOf(key)))
      }, (key: string): string => key)
    }
    .width('100%').height('100%').cachedCount(1)
    .scrollBar(BarState.Off).edgeEffect(EdgeEffect.None)
    .enableScrollInteraction(this.active && this.snapshot.phase === 'ready' && !this.pendingPosition)
    .id('rkit-continuous-list')
    .onAreaChange((_old: Area, area: Area): void => {
      const width = Math.max(1, Number(area.width))
      if (this.viewWidth !== width) this.pendingPosition = true
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
    .onDidScroll((): void => { this.scheduleMeasure() })
    .onScrollStop((): void => { this.scheduleMeasure() })
  }
}

@ComponentV2
struct ReaderContinuousCell {
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param imageHeight: number
  @Require @Param active: boolean
  @Event onPresented: (slot: number, request: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onFailed: (slot: number, request: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetired: (slot: number, request: number) => void = () => {}
  @Event onRetry: (slot: number, request: number) => void = () => {}

  build() {
    Stack() {
      ForEach(this.snapshot.frames, (frame: ReaderPagedFrame) => {
        if (this.snapshot.frames[0].asset.phase === 'failed') {
          ReaderFailurePanel({
            page: frame.part.sourceIndex + 1, compact: true, retryEnabled: this.active,
            // Failed acquisition can keep assetRequestId=0 across attempts; read the current epoch.
            onRetry: (): void => { this.onRetry(frame.slotId, this.snapshot.frames[0].asset.requestId) },
          })
        } else if (this.snapshot.frames[0].asset.uri.length > 0) {
          ReaderPagedImage({
            frame: this.snapshot.frames[0], slotId: frame.slotId, assetRequestId: frame.asset.assetRequestId,
            selectionId: this.snapshot.selectionId, renderedFragment: frame.part.fragment, active: false,
            onPresented: this.onPresented,
            onFailed: (_selection: number, slot: number, request: number, fragment: ReaderFragment): void => {
              this.onFailed(slot, request, fragment)
            },
          }).height(this.imageHeight)
            .onDisAppear((): void => { this.onRetired(frame.slotId, frame.asset.assetRequestId) })
        }
      }, (frame: ReaderPagedFrame): string => `${frame.slotId}:${frame.asset.assetRequestId}`)
      if (this.snapshot.frames.length === 0 || this.snapshot.frames[0].asset.phase === 'idle' ||
        this.snapshot.frames[0].asset.phase === 'asset' || this.snapshot.frames[0].asset.phase === 'decoding') {
        LoadingProgress().width(32).height(32)
      }
    }.width('100%').height('100%').clip(true)
      .id(`rkit-continuous-page-${this.snapshot.displayIndex}`)
  }
}
