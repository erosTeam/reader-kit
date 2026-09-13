import { ReaderPagedSnapshot, ReaderFragment } from '@reader-kit/core'
import { ReaderPagedViewport } from './ReaderPagedViewport'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { ReaderBoundaryDirection, ReaderBoundarySwipe } from './ReaderBoundarySwipe'

/** Immutable within one topology revision; a changed topology gets a new native pager. */
class ReaderPagerIndexSource implements IDataSource {
  private keys: string[]
  constructor(keys: string[]) { this.keys = keys.slice() }
  totalCount(): number { return this.keys.length }
  getData(index: number): string { return this.keys[index] }
  registerDataChangeListener(_listener: DataChangeListener): void {}
  unregisterDataChangeListener(_listener: DataChangeListener): void {}
}

/** Native page container only. Session ownership and diagnostic chrome stay outside. */
@ComponentV2
export struct ReaderPagerSurface {
  @Param imageInterpolation: ImageInterpolation = ImageInterpolation.Low
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Param entryTransition: ReaderEntryTransition | null = null
  @Event onInputLockChange: (locked: boolean, topology: number) => void = () => {}
  @Event onTap: (xFraction: number, yFraction: number) => void = () => {}
  @Event onBoundary: (direction: ReaderBoundaryDirection, topologyRevision: number,
    navigationRevision: number) => void = () => {}
  @Event onSelect: (index: number, topologyRevision: number, navigationRevision: number) => void = () => {}
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (topologyRevision: number, itemKey: string, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (topologyRevision: number, itemKey: string, slotId: number, requestId: number) => void = () => {}

  build() {
    Stack() {
      if (this.snapshot.displayCount > 0) {
        ForEach([this.snapshot.topologyRevision], (revision: number) => {
          ReaderNativePager({
            imageInterpolation: this.imageInterpolation,
            snapshot: this.snapshot, active: this.active, createdRevision: revision,
            entryTransition: this.entryTransition,
            onInputLockChange: this.onInputLockChange,
            onBoundary: this.onBoundary,
            onSelect: this.onSelect, onPresented: this.onPresented, onVisible: this.onVisible, onFailed: this.onFailed,
            onRetry: this.onRetry,
            onTap: this.onTap,
          })
        }, (revision: number): string => `${revision}`)
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
  @Require @Param snapshot: ReaderPagedSnapshot
  @Require @Param active: boolean
  @Param entryTransition: ReaderEntryTransition | null = null
  @Event onInputLockChange: (locked: boolean, topology: number) => void = () => {}
  @Event onTap: (xFraction: number, yFraction: number) => void = () => {}
  @Event onBoundary: (direction: ReaderBoundaryDirection, topologyRevision: number,
    navigationRevision: number) => void = () => {}
  @Require @Param createdRevision: number
  @Event onSelect: (index: number, topologyRevision: number, navigationRevision: number) => void = () => {}
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (topologyRevision: number, itemKey: string, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (topologyRevision: number, itemKey: string, slotId: number, requestId: number) => void = () => {}
  private source: ReaderPagerIndexSource = new ReaderPagerIndexSource([])
  @Local private inputLocked: boolean = false
  @Local private moving: boolean = false
  private gestureNavigation: number = -1
  private lastNavigation: number = -1
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
      this.boundaryTopology = this.snapshot.topologyRevision
      this.boundaryNavigation = this.snapshot.navigationRevision
      this.boundarySwipe.begin(point.windowX, point.windowY,
        this.snapshot.displayIndex === 0,
        this.snapshot.displayIndex + 1 === this.snapshot.displayCount)
      return
    }
    if (event.type === TouchType.Cancel) {
      this.boundarySwipe.cancel()
      return
    }
    if (event.type !== TouchType.Up) return
    const direction = this.boundarySwipe.finish(point.windowX, point.windowY,
      this.snapshot.policy.pagingAxis === 'vertical' ? 'vertical' : 'horizontal',
      this.snapshot.policy.direction)
    if (direction !== null && this.active && this.snapshot.phase === 'ready' &&
      this.createdRevision === this.snapshot.topologyRevision && this.boundaryTopology === this.snapshot.topologyRevision &&
      this.boundaryNavigation === this.snapshot.navigationRevision) {
      this.onBoundary(direction, this.boundaryTopology, this.boundaryNavigation)
    }
  }

  aboutToAppear(): void {
    this.source = new ReaderPagerIndexSource(this.snapshot.displayKeys)
    this.lastNavigation = this.snapshot.navigationRevision
    this.reportExternalLock()
  }
  aboutToDisappear(): void {
    if (this.pendingChange !== 0) clearTimeout(this.pendingChange)
    this.pendingChange = 0
  }

  @Monitor('inputLocked', 'moving', 'active')
  reportExternalLock(): void {
    this.onInputLockChange(!this.active || this.inputLocked || this.moving, this.createdRevision)
  }

  @Monitor('snapshot')
  onNavigationChanged(): void {
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
      this.gestureNavigation = -1
      if (this.pendingChange !== 0) clearTimeout(this.pendingChange)
      this.pendingChange = 0
    }
  }

  private beginMotion(): void {
    this.entryTransition?.cancel()
    if (this.gestureNavigation < 0) this.gestureNavigation = this.snapshot.navigationRevision
    this.moving = true
  }

  private queueSelection(index: number): void {
    if (index === this.snapshot.displayIndex) {
      this.gestureNavigation = -1
      return
    }
    const navigation = this.gestureNavigation >= 0 ? this.gestureNavigation : this.snapshot.navigationRevision
    this.gestureNavigation = -1
    if (this.pendingChange !== 0) clearTimeout(this.pendingChange)
    // ArkUI forbids refreshing LazyForEach child UI recursively inside onChange.
    // Keep the revision captured by this native pager, not a newer map's index space.
    this.pendingChange = setTimeout((): void => {
      this.pendingChange = 0
      if (!this.active) return
      this.onSelect(index, this.createdRevision, navigation)
      console.info(`[ReaderPager] selected=${index} topology=${this.createdRevision} navigation=${navigation}`)
    }, 0)
  }

  build() {
    Swiper() {
      LazyForEach(this.source, (key: string) => {
        ReaderPagedViewport({
          imageInterpolation: this.imageInterpolation,
          snapshot: this.snapshot.forItem(key),
          entryTransition: key === this.snapshot.displayKeys[this.snapshot.displayIndex] ? this.entryTransition : null,
          selected: key === this.snapshot.displayKeys[this.snapshot.displayIndex],
          active: this.active && !this.moving && key === this.snapshot.displayKeys[this.snapshot.displayIndex],
          onInputLockChange: (locked: boolean): void => {
            if (key === this.snapshot.displayKeys[this.snapshot.displayIndex]) this.inputLocked = locked
          },
          onPresented: this.onPresented,
          onTap: this.onTap,
          onVisible: this.onVisible,
          onRetry: (slotId: number, requestId: number): void => {
            this.onRetry(this.createdRevision, key, slotId, requestId)
          },
          onFailed: (_selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment): void => {
            this.onFailed(this.createdRevision, key, slotId, requestId, fragment)
          },
        })
      }, (key: string): string => key)
    }
    .index(this.snapshot.displayIndex)
    .vertical(this.snapshot.policy.pagingAxis === 'vertical')
    .direction(this.snapshot.policy.pagingAxis !== 'vertical' && this.snapshot.policy.direction === 'rtl' ?
      Direction.Rtl : Direction.Ltr)
    .loop(false).indicator(false).cachedCount(1)
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
