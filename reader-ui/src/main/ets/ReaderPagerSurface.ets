import { ReaderPagedSnapshot, ReaderFragment } from '@reader-kit/core'
import { ReaderPagedViewport } from './ReaderPagedViewport'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { ReaderBoundaryDirection, ReaderBoundarySwipe } from './ReaderBoundarySwipe'
import { ReaderZoomResetCommand } from './ReaderZoomResetCommand'
import { readerElementKey } from './ReaderElementKey'
import { ReaderPagerIdentityMap, ReaderPagerItemIdentity } from './ReaderPagerIdentityMap'

/** One host-requested pager move. The native pager consumes each serial at most once.
 * A command may target a non-adjacent display item: the legacy readers commit an
 * arbitrary target through the animated pager (NextE `jumpToPage`/`animateReaderPagerToIndex`
 * -> `changeIndex(target, true)`), so the native owner animates the whole delta instead
 * of hard-cutting or dropping the jump. */
export class ReaderPagerCommand {
  serial: number
  targetIndex: number
  topologyRevision: number
  navigationRevision: number

  constructor(serial: number, targetIndex: number, topologyRevision: number, navigationRevision: number) {
    this.serial = serial
    this.targetIndex = targetIndex
    this.topologyRevision = topologyRevision
    this.navigationRevision = navigationRevision
  }
}

/** Observable render data keeps its native identity across regrouping. */
@ObservedV2
class ReaderPagerRenderItem {
  @Trace key: string
  nativeKey: string
  @Trace snapshot: ReaderPagedSnapshot
  constructor(identity: ReaderPagerItemIdentity, snapshot: ReaderPagedSnapshot) {
    this.key = identity.key
    this.nativeKey = identity.nativeKey
    this.snapshot = snapshot
  }
}

/** Publish the keyed data synchronously before Swiper consumes a new index. */
class ReaderPagerDataSource implements IDataSource {
  private items: ReaderPagerRenderItem[] = []
  private listeners: DataChangeListener[] = []
  totalCount(): number { return this.items.length }
  getData(index: number): ReaderPagerRenderItem { return this.items[index] }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener)
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((value: DataChangeListener): boolean => value !== listener)
  }
  update(identities: ReaderPagerItemIdentity[], snapshot: ReaderPagedSnapshot): void {
    const previous: Map<string, ReaderPagerRenderItem> = new Map<string, ReaderPagerRenderItem>()
    this.items.forEach((item: ReaderPagerRenderItem): void => { previous.set(item.nativeKey, item) })
    const changed = identities.length !== this.items.length || identities.some(
      (identity: ReaderPagerItemIdentity, index: number): boolean => this.items[index]?.nativeKey !== identity.nativeKey)
    this.items = identities.map((identity: ReaderPagerItemIdentity): ReaderPagerRenderItem => {
      const item = previous.get(identity.nativeKey) ?? new ReaderPagerRenderItem(identity, snapshot)
      item.key = identity.key
      item.snapshot = snapshot
      return item
    })
    // Reload compares stable keys and retains matching nodes. Ordinary image or
    // selection updates only change observed fields, with no structural signal.
    if (changed) this.listeners.forEach((listener: DataChangeListener): void => listener.onDataReloaded())
  }
}

/** Native page container only. Session ownership and diagnostic chrome stay outside. */
@ComponentV2
export struct ReaderPagerSurface {
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Param pageGap: number = 0
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Param command: ReaderPagerCommand | null = null
  @Param zoomResetCommand: ReaderZoomResetCommand | null = null
  @Param entryTransition: ReaderEntryTransition | null = null
  @Event onInputLockChange: (locked: boolean, topology: number) => void = () => {}
  @Event onZoomedChange: (zoomed: boolean, topology: number, navigation: number) => void = () => {}
  @Event onTap: (xFraction: number, yFraction: number) => void = () => {}
  @Event onBoundary: (direction: ReaderBoundaryDirection, topologyRevision: number,
    navigationRevision: number) => void = () => {}
  @Event onSelect: (index: number, topologyRevision: number, navigationRevision: number) => void = () => {}
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (topologyRevision: number, itemKey: string, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (topologyRevision: number, itemKey: string, slotId: number, requestId: number) => void = () => {}
  @Event onNoticeAction: (topologyRevision: number, navigationRevision: number, itemKey: string,
    slotId: number, requestId: number, noticeId: string) => Promise<boolean> =
    async (_topologyRevision: number, _navigationRevision: number, _itemKey: string,
      _slotId: number, _requestId: number, _noticeId: string): Promise<boolean> => false

  build() {
    Stack() {
      if (this.snapshot.displayCount > 0) {
        ReaderNativePager({
          imageInterpolation: this.imageInterpolation,
          pageGap: this.pageGap,
          snapshot: this.snapshot, active: this.active,
          command: this.command,
          zoomResetCommand: this.zoomResetCommand,
          entryTransition: this.entryTransition,
          onInputLockChange: this.onInputLockChange,
          onZoomedChange: this.onZoomedChange,
          onBoundary: this.onBoundary,
          onSelect: this.onSelect, onPresented: this.onPresented, onVisible: this.onVisible, onFailed: this.onFailed,
          onRetry: this.onRetry, onNoticeAction: this.onNoticeAction,
          onTap: this.onTap,
        })
      } else if (this.snapshot.phase === 'idle' || this.snapshot.phase === 'catalog') {
        LoadingProgress().width(32).height(32)
      }
    }
    .width('100%').height('100%').clip(true)
  }
}

@ComponentV2
struct ReaderNativePager {
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Param pageGap: number = 0
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Param command: ReaderPagerCommand | null = null
  @Param zoomResetCommand: ReaderZoomResetCommand | null = null
  @Param entryTransition: ReaderEntryTransition | null = null
  @Event onInputLockChange: (locked: boolean, topology: number) => void = () => {}
  @Event onZoomedChange: (zoomed: boolean, topology: number, navigation: number) => void = () => {}
  @Event onTap: (xFraction: number, yFraction: number) => void = () => {}
  @Event onBoundary: (direction: ReaderBoundaryDirection, topologyRevision: number,
    navigationRevision: number) => void = () => {}
  @Event onSelect: (index: number, topologyRevision: number, navigationRevision: number) => void = () => {}
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (topologyRevision: number, itemKey: string, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (topologyRevision: number, itemKey: string, slotId: number, requestId: number) => void = () => {}
  @Event onNoticeAction: (topologyRevision: number, navigationRevision: number, itemKey: string,
    slotId: number, requestId: number, noticeId: string) => Promise<boolean> =
    async (_topologyRevision: number, _navigationRevision: number, _itemKey: string,
      _slotId: number, _requestId: number, _noticeId: string): Promise<boolean> => false
  private identities: ReaderPagerIdentityMap = new ReaderPagerIdentityMap()
  private pageSource: ReaderPagerDataSource = new ReaderPagerDataSource()

  private syncPageItems(): void {
    const unit = this.snapshot.unit?.key
    const identities = this.identities.update(this.snapshot.displayKeys, this.snapshot.displayIndex,
      this.snapshot.topologyRevision, JSON.stringify(unit === undefined ? [] : [unit.scope, unit.work, unit.unit]))
    this.pageSource.update(identities, this.snapshot)
  }
  private controller: SwiperController = new SwiperController()
  @Local private inputLocked: boolean = false
  @Local private moving: boolean = false
  private gestureTopology: number = -1
  private gestureNavigation: number = -1
  private lastTopology: number = -1
  private lastNavigation: number = -1
  private lastCommandSerial: number = 0
  private pendingChange: number = 0
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
      if (this.inputLocked || this.moving) {
        this.boundarySwipe.cancel()
        return
      }
      this.gestureTopology = this.snapshot.topologyRevision
      this.gestureNavigation = this.snapshot.navigationRevision
      this.boundaryTopology = this.snapshot.topologyRevision
      this.boundaryNavigation = this.snapshot.navigationRevision
      this.boundarySwipe.begin(point.windowX, point.windowY,
        this.snapshot.displayIndex === 0,
        this.snapshot.displayIndex + 1 === this.snapshot.displayCount)
      return
    }
    if (event.type === TouchType.Cancel) {
      this.gestureTopology = -1
      this.gestureNavigation = -1
      this.boundarySwipe.cancel()
      return
    }
    if (event.type !== TouchType.Up) return
    const direction = this.boundarySwipe.finish(point.windowX, point.windowY,
      this.snapshot.policy.pagingAxis === 'vertical' ? 'vertical' : 'horizontal',
      this.snapshot.policy.direction)
    if (direction !== null && this.active && this.snapshot.phase === 'ready' &&
      this.boundaryTopology === this.snapshot.topologyRevision &&
      this.boundaryNavigation === this.snapshot.navigationRevision) {
      this.onBoundary(direction, this.boundaryTopology, this.boundaryNavigation)
    }
  }

  aboutToAppear(): void {
    this.syncPageItems()
    this.lastTopology = this.snapshot.topologyRevision
    this.lastNavigation = this.snapshot.navigationRevision
    this.reportExternalLock()
  }
  aboutToDisappear(): void {
    if (this.pendingChange !== 0) clearTimeout(this.pendingChange)
    this.pendingChange = 0
  }

  @Monitor('inputLocked', 'moving', 'active', 'snapshot')
  reportExternalLock(): void {
    this.onInputLockChange(!this.active || this.inputLocked || this.moving, this.snapshot.topologyRevision)
  }

  @Monitor('snapshot')
  onNavigationChanged(): void {
    this.syncPageItems()
    if (this.lastTopology !== this.snapshot.topologyRevision) {
      this.lastTopology = this.snapshot.topologyRevision
      if (this.pendingChange !== 0) clearTimeout(this.pendingChange)
      this.pendingChange = 0
      this.inputLocked = false
      this.moving = false
      this.gestureTopology = -1
      this.gestureNavigation = -1
      this.boundarySwipe.cancel()
    }
    if (this.lastNavigation !== this.snapshot.navigationRevision) {
      this.lastNavigation = this.snapshot.navigationRevision
      this.inputLocked = false
      this.boundarySwipe.cancel()
    }
  }

  @Monitor('active')
  onActiveChanged(): void {
    if (!this.active) {
      this.inputLocked = false
      this.moving = false
      this.gestureTopology = -1
      this.gestureNavigation = -1
      if (this.pendingChange !== 0) clearTimeout(this.pendingChange)
      this.pendingChange = 0
    }
  }

  @Monitor('command')
  onCommandChanged(): void {
    const command = this.command
    if (command === null || command.serial <= this.lastCommandSerial) return
    this.lastCommandSerial = command.serial
    if (!this.active || this.inputLocked || this.moving || command.topologyRevision !== this.snapshot.topologyRevision ||
      command.navigationRevision !== this.snapshot.navigationRevision ||
      command.targetIndex < 0 || command.targetIndex >= this.snapshot.displayCount) return
    this.gestureTopology = command.topologyRevision
    this.gestureNavigation = command.navigationRevision
    this.beginMotion()
    try {
      this.controller.changeIndex(command.targetIndex, true)
      console.info(`[ReaderPager] command=${command.serial} target=${command.targetIndex} ` +
        `topology=${command.topologyRevision} navigation=${command.navigationRevision}`)
    } catch (error) {
      this.moving = false
      this.gestureTopology = -1
      this.gestureNavigation = -1
      console.warn(`[ReaderPager] command_failed=${command.serial} ${(error as Error).message}`)
    }
  }

  private beginMotion(): void {
    this.entryTransition?.cancel()
    this.moving = true
  }

  private queueSelection(index: number): void {
    // Declarative map/index updates are not user navigation. Only a gesture or
    // native command started in this map may publish a new reading selection.
    const topology = this.gestureTopology
    const navigation = this.gestureNavigation
    this.gestureTopology = -1
    this.gestureNavigation = -1
    if (index === this.snapshot.displayIndex || topology !== this.snapshot.topologyRevision ||
      navigation !== this.snapshot.navigationRevision) return
    if (this.pendingChange !== 0) clearTimeout(this.pendingChange)
    // LazyForEach cannot refresh its children recursively from native onChange.
    this.pendingChange = setTimeout((): void => {
      this.pendingChange = 0
      if (!this.active || topology !== this.snapshot.topologyRevision ||
        navigation !== this.snapshot.navigationRevision) return
      this.onSelect(index, topology, navigation)
      console.info(`[ReaderPager] selected=${index} topology=${topology} navigation=${navigation}`)
    }, 0)
  }

  build() {
    Swiper(this.controller) {
      LazyForEach(this.pageSource, (item: ReaderPagerRenderItem) => {
        ReaderPagedViewport({
          imageInterpolation: this.imageInterpolation,
          pageGap: this.pageGap,
          snapshot: item.snapshot.forItem(item.key),
          entryTransition: item.key === item.snapshot.displayKeys[item.snapshot.displayIndex] ? this.entryTransition : null,
          selected: item.key === item.snapshot.displayKeys[item.snapshot.displayIndex],
          active: this.active && !this.moving && item.key === item.snapshot.displayKeys[item.snapshot.displayIndex],
          zoomResetCommand: this.zoomResetCommand,
          onInputLockChange: (locked: boolean): void => {
            if (item.snapshot.topologyRevision === this.snapshot.topologyRevision &&
              item.snapshot.navigationRevision === this.snapshot.navigationRevision &&
              item.key === this.snapshot.displayKeys[this.snapshot.displayIndex]) this.inputLocked = locked
          },
          onZoomedChange: (zoomed: boolean): void => {
            if (item.snapshot.topologyRevision === this.snapshot.topologyRevision &&
              item.snapshot.navigationRevision === this.snapshot.navigationRevision &&
              item.key === this.snapshot.displayKeys[this.snapshot.displayIndex]) {
              this.onZoomedChange(zoomed, this.snapshot.topologyRevision, this.snapshot.navigationRevision)
            }
          },
          onPresented: this.onPresented,
          onTap: this.onTap,
          onVisible: this.onVisible,
          onRetry: (slotId: number, requestId: number): void => {
            this.onRetry(this.snapshot.topologyRevision, item.key, slotId, requestId)
          },
          onNoticeAction: (slotId: number, requestId: number, noticeId: string): Promise<boolean> => {
            return this.onNoticeAction(this.snapshot.topologyRevision, this.snapshot.navigationRevision,
              item.key, slotId, requestId, noticeId)
          },
          onFailed: (_selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment): void => {
            this.onFailed(this.snapshot.topologyRevision, item.key, slotId, requestId, fragment)
          },
        })
      // Keep the visible native viewport when its source pages are regrouped.
      }, (item: ReaderPagerRenderItem): string => readerElementKey(item.nativeKey))
    }
    .index(this.snapshot.displayIndex)
    .vertical(this.snapshot.policy.pagingAxis === 'vertical')
    .direction(this.snapshot.policy.pagingAxis !== 'vertical' && this.snapshot.policy.direction === 'rtl' ?
      Direction.Rtl : Direction.Ltr)
    // Window resources resolve after cached cells are created. Keep those cells
    // on the render tree so their Image branches decode before a swipe reveals them.
    .loop(false).indicator(false).cachedCount(this.snapshot.nativeCacheDepth, true)
    .disableSwipe(!this.active || this.snapshot.phase !== 'ready' || this.inputLocked)
    .width('100%').height('100%').id('rkit-native-pager')
    .onTouch((event: TouchEvent): void => { this.handleBoundaryTouch(event) })
    .onGestureSwipe((): void => { this.beginMotion() })
    .onAnimationStart((): void => { this.beginMotion() })
    .onScrollStateChanged((state: ScrollState): void => {
      if (state !== ScrollState.Idle) this.entryTransition?.cancel()
      this.moving = state !== ScrollState.Idle
    })
    .onAnimationEnd((): void => { this.moving = false })
    .onChange((index: number): void => { this.queueSelection(index) })
  }
}
