import { ReaderPagedSnapshot, ReaderFragment } from '@reader-kit/core'
import { ReaderPagedViewport } from './ReaderPagedViewport'
import { ReaderEntryTransition } from './ReaderEntryTransition'

/** One adjacent host-requested move. The native pager consumes each serial at most once. */
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
  @Param command: ReaderPagerCommand | null = null
  @Param entryTransition: ReaderEntryTransition | null = null
  @Event onInputLockChange: (locked: boolean, topology: number) => void = () => {}
  @Event onTap: (xFraction: number, yFraction: number) => void = () => {}
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
            command: this.command,
            entryTransition: this.entryTransition,
            onInputLockChange: this.onInputLockChange,
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
  @Param command: ReaderPagerCommand | null = null
  @Param entryTransition: ReaderEntryTransition | null = null
  @Event onInputLockChange: (locked: boolean, topology: number) => void = () => {}
  @Event onTap: (xFraction: number, yFraction: number) => void = () => {}
  @Require @Param createdRevision: number
  @Event onSelect: (index: number, topologyRevision: number, navigationRevision: number) => void = () => {}
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onFailed: (topologyRevision: number, itemKey: string, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (topologyRevision: number, itemKey: string, slotId: number, requestId: number) => void = () => {}
  private source: ReaderPagerIndexSource = new ReaderPagerIndexSource([])
  private controller: SwiperController = new SwiperController()
  @Local private inputLocked: boolean = false
  @Local private moving: boolean = false
  private gestureNavigation: number = -1
  private lastNavigation: number = -1
  private lastCommandSerial: number = 0
  private pendingChange: number = 0

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

  @Monitor('command')
  onCommandChanged(): void {
    const command = this.command
    if (command === null || command.serial <= this.lastCommandSerial) return
    this.lastCommandSerial = command.serial
    if (!this.active || this.inputLocked || this.moving || command.topologyRevision !== this.createdRevision ||
      command.topologyRevision !== this.snapshot.topologyRevision ||
      command.navigationRevision !== this.snapshot.navigationRevision ||
      Math.abs(command.targetIndex - this.snapshot.displayIndex) !== 1 ||
      command.targetIndex < 0 || command.targetIndex >= this.snapshot.displayCount) return
    this.gestureNavigation = command.navigationRevision
    this.beginMotion()
    try {
      this.controller.changeIndex(command.targetIndex, true)
      console.info(`[ReaderPager] command=${command.serial} target=${command.targetIndex} ` +
        `topology=${command.topologyRevision} navigation=${command.navigationRevision}`)
    } catch (error) {
      this.moving = false
      this.gestureNavigation = -1
      console.warn(`[ReaderPager] command_failed=${command.serial} ${(error as Error).message}`)
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
    Swiper(this.controller) {
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
