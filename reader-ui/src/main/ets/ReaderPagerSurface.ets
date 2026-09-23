import { ReaderPagedSnapshot, ReaderFragment } from '@reader-kit/core'
import { ReaderPagedViewport } from './ReaderPagedViewport'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { ReaderBoundaryDirection, ReaderBoundarySwipe } from './ReaderBoundarySwipe'
import { ReaderZoomResetCommand } from './ReaderZoomResetCommand'
import { readerElementKey } from './ReaderElementKey'
import { ReaderPositionHandoff } from './ReaderPositionHandoff'
import { FrameCallback } from '@kit.ArkUI'

class ReaderPagerAfterFrame extends FrameCallback {
  private action: () => void
  constructor(action: () => void) { super(); this.action = action }
  onIdle(_remaining: number): void { this.action() }
}

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
  animated: boolean

  constructor(serial: number, targetIndex: number, topologyRevision: number, navigationRevision: number,
    animated: boolean = true) {
    this.serial = serial
    this.targetIndex = targetIndex
    this.topologyRevision = topologyRevision
    this.navigationRevision = navigationRevision
    this.animated = animated
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
  @Param pageGap: number = 0
  @Param retainedProjectionDiagnostic: boolean = false
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
  @Event onVisualClaim: (slotId: number, requestId: number, visualRevision: number,
    width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onPositionHandoff: (claim: ReaderPositionHandoff | null) => void = () => {}
  @Event onFailed: (topologyRevision: number, itemKey: string, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (topologyRevision: number, itemKey: string, slotId: number, requestId: number) => void = () => {}
  @Event onNoticeAction: (topologyRevision: number, navigationRevision: number, itemKey: string,
    slotId: number, requestId: number, noticeId: string) => Promise<boolean> =
    async (_topologyRevision: number, _navigationRevision: number, _itemKey: string,
      _slotId: number, _requestId: number, _noticeId: string): Promise<boolean> => false

  build() {
    Stack() {
      if (this.snapshot.displayCount > 0) {
        ForEach([this.snapshot.topologyRevision], (revision: number) => {
          ReaderNativePager({
            imageInterpolation: this.imageInterpolation,
            pageGap: this.pageGap,
            retainedProjectionDiagnostic: this.retainedProjectionDiagnostic,
            snapshot: this.snapshot, active: this.active, createdRevision: revision,
            command: this.command,
            zoomResetCommand: this.zoomResetCommand,
            entryTransition: this.entryTransition,
            onInputLockChange: this.onInputLockChange,
            onZoomedChange: this.onZoomedChange,
            onBoundary: this.onBoundary,
            onSelect: this.onSelect, onPresented: this.onPresented, onVisualClaim: this.onVisualClaim,
            onVisible: this.onVisible, onFailed: this.onFailed,
            onPositionHandoff: this.onPositionHandoff,
            onRetry: this.onRetry, onNoticeAction: this.onNoticeAction,
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
  @Param pageGap: number = 0
  @Param retainedProjectionDiagnostic: boolean = false
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
  @Require @Param createdRevision: number
  @Event onSelect: (index: number, topologyRevision: number, navigationRevision: number) => void = () => {}
  @Event onPresented: (slotId: number, requestId: number, success: boolean, width: number, height: number) => void = () => {}
  @Event onVisualClaim: (slotId: number, requestId: number, visualRevision: number,
    width: number, height: number) => void = () => {}
  @Event onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onPositionHandoff: (claim: ReaderPositionHandoff | null) => void = () => {}
  @Event onFailed: (topologyRevision: number, itemKey: string, slotId: number, requestId: number, fragment: ReaderFragment) => void = () => {}
  @Event onRetry: (topologyRevision: number, itemKey: string, slotId: number, requestId: number) => void = () => {}
  @Event onNoticeAction: (topologyRevision: number, navigationRevision: number, itemKey: string,
    slotId: number, requestId: number, noticeId: string) => Promise<boolean> =
    async (_topologyRevision: number, _navigationRevision: number, _itemKey: string,
      _slotId: number, _requestId: number, _noticeId: string): Promise<boolean> => false
  private source: ReaderPagerIndexSource = new ReaderPagerIndexSource([])
  private controller: SwiperController = new SwiperController()
  @Local private inputLocked: boolean = false
  @Local private moving: boolean = false
  private gestureNavigation: number = -1
  private lastNavigation: number = -1
  private lastCommandSerial: number = 0
  // Keep the newest native command's target until a real swipe starts. A delayed
  // onChange from an older changeIndex must never commit a different page.
  private commandTarget: number = -1
  private commandNavigation: number = -1
  @Local private positionHandoff: ReaderPositionHandoff | null = null
  private pendingOffCommand: ReaderPagerCommand | null = null
  private oldVisualMounted: boolean = false
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
    this.commandTarget = -1
    this.pendingOffCommand = null
    this.positionHandoff = null
    this.onPositionHandoff(null)
    this.oldVisualMounted = false
  }

  @Monitor('inputLocked', 'moving', 'active', 'positionHandoff')
  reportExternalLock(): void {
    this.onInputLockChange(!this.active || this.inputLocked || this.moving ||
      this.positionHandoff !== null, this.createdRevision)
  }

  @Monitor('snapshot')
  onNavigationChanged(): void {
    if (this.lastNavigation !== this.snapshot.navigationRevision) {
      this.lastNavigation = this.snapshot.navigationRevision
      this.inputLocked = false
      this.boundarySwipe.cancel()
    }
    // Provider load failures publish a failed snapshot without invoking the
    // image-render onFailed callback. The selected native failure panel must
    // still become visible instead of remaining behind the old-image claim.
    const handoff = this.positionHandoff
    if (handoff !== null && this.snapshot.displayIndex === handoff.targetIndex &&
      this.snapshot.navigationRevision > handoff.navigationRevision) {
      const failed = this.snapshot.forItem(handoff.targetKey).frames.find(frame => frame.asset.phase === 'failed')
      if (failed !== undefined) this.revealFailedTarget(handoff.targetKey, this.snapshot.selectionId,
        failed.slotId, failed.asset.assetRequestId)
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
      this.commandTarget = -1
      this.pendingOffCommand = null
      this.positionHandoff = null
      this.onPositionHandoff(null)
      this.oldVisualMounted = false
    }
  }

  @Monitor('command')
  onCommandChanged(): void {
    const command = this.command
    if (command === null || command.serial <= this.lastCommandSerial) return
    if (!this.active || this.inputLocked || (command.animated && this.moving) ||
      command.topologyRevision !== this.createdRevision ||
      command.topologyRevision !== this.snapshot.topologyRevision ||
      command.navigationRevision !== this.snapshot.navigationRevision ||
      command.targetIndex < 0 || command.targetIndex >= this.snapshot.displayCount) return
    this.lastCommandSerial = command.serial
    this.commandTarget = command.targetIndex
    this.commandNavigation = command.navigationRevision
    if (this.pendingChange !== 0) clearTimeout(this.pendingChange)
    this.pendingChange = 0
    this.gestureNavigation = command.navigationRevision
    if (!command.animated) {
      this.positionHandoff = new ReaderPositionHandoff(command.serial, command.targetIndex,
        command.topologyRevision, command.navigationRevision, this.snapshot, this.positionHandoff)
      this.onPositionHandoff(this.positionHandoff)
      this.pendingOffCommand = command
      if (this.oldVisualMounted) this.startOffCommandAfterFrame(command)
      return
    }
    this.positionHandoff = null
    this.onPositionHandoff(null)
    this.pendingOffCommand = null
    this.beginMotion()
    try {
      this.controller.changeIndex(command.targetIndex, command.animated)
      console.info(`[ReaderPager] command=${command.serial} target=${command.targetIndex} ` +
        `topology=${command.topologyRevision} navigation=${command.navigationRevision} animated=${command.animated}`)
    } catch (error) {
      this.moving = false
      this.gestureNavigation = -1
      this.commandTarget = -1
      console.warn(`[ReaderPager] command_failed=${command.serial} ${(error as Error).message}`)
    }
  }

  private startOffCommandAfterFrame(command: ReaderPagerCommand): void {
    this.getUIContext().postFrameCallback(new ReaderPagerAfterFrame((): void => {
      if (!this.active || !this.oldVisualMounted || this.pendingOffCommand?.serial !== command.serial ||
        this.positionHandoff?.current(command.serial, this.snapshot) !== true) return
      this.pendingOffCommand = null
      try {
        this.controller.changeIndex(command.targetIndex, false)
        console.info(`[ReaderPager] command=${command.serial} target=${command.targetIndex} ` +
          `topology=${command.topologyRevision} navigation=${command.navigationRevision} animated=false old_visual_held=true`)
        // A superseding seek back to the still-current old item need not emit
        // onChange/onVisible. Let the native pager reclaim that item for a frame,
        // then retire the duplicate old visual without changing session state.
        const handoff = this.positionHandoff
        if (handoff !== null && command.targetIndex === this.snapshot.displayIndex &&
          handoff.targetKey === handoff.oldKey) {
          this.getUIContext().postFrameCallback(new ReaderPagerAfterFrame((): void => {
            if (this.positionHandoff?.serial !== command.serial ||
              this.snapshot.displayIndex !== command.targetIndex ||
              this.snapshot.displayKeys[command.targetIndex] !== handoff.oldKey) return
            this.positionHandoff = null
            this.onPositionHandoff(null)
            this.oldVisualMounted = false
            this.commandTarget = -1
            this.commandNavigation = -1
            console.info(`[ReaderPager] old_visual_restored=${command.serial} target=${command.targetIndex}`)
          }))
        }
      } catch (error) {
        this.positionHandoff = null
        this.onPositionHandoff(null)
        this.commandTarget = -1
        console.warn(`[ReaderPager] command_failed=${command.serial} ${(error as Error).message}`)
      }
    }))
  }

  private visibleAfterHandoff(key: string, selectionId: number, slotId: number, requestId: number,
    fragment: ReaderFragment): void {
    const handoff = this.positionHandoff
    if (handoff === null) {
      this.onVisible(selectionId, slotId, requestId, fragment)
      return
    }
    if (!handoff.targetDrawable(key, selectionId, this.snapshot)) return
    this.positionHandoff = null
    this.onPositionHandoff(null)
    this.oldVisualMounted = false
    this.getUIContext().postFrameCallback(new ReaderPagerAfterFrame((): void => {
      if (!this.active || this.lastCommandSerial !== handoff.serial ||
        this.snapshot.topologyRevision !== handoff.topologyRevision ||
        this.snapshot.displayKeys[this.snapshot.displayIndex] !== handoff.targetKey ||
        this.snapshot.selectionId !== selectionId) return
      this.onVisible(selectionId, slotId, requestId, fragment)
      console.info(`[ReaderPager] old_visual_retired=${handoff.serial} target=${handoff.targetIndex}`)
    }))
  }

  private failedAfterHandoff(key: string, selectionId: number, slotId: number, requestId: number,
    fragment: ReaderFragment): void {
    this.onFailed(this.createdRevision, key, slotId, requestId, fragment)
    this.revealFailedTarget(key, selectionId, slotId, requestId)
  }

  private revealFailedTarget(key: string, selectionId: number, slotId: number, requestId: number): void {
    const handoff = this.positionHandoff
    if (handoff === null || key !== handoff.targetKey ||
      selectionId !== this.snapshot.selectionId) return
    this.getUIContext().postFrameCallback(new ReaderPagerAfterFrame((): void => {
      if (this.positionHandoff?.serial !== handoff.serial ||
        this.snapshot.selectionId !== selectionId ||
        this.snapshot.displayKeys[this.snapshot.displayIndex] !== key) return
      const failed = this.snapshot.forItem(key).frames.some(frame => frame.slotId === slotId &&
        frame.asset.assetRequestId === requestId && frame.asset.phase === 'failed')
      if (failed) {
        // Reveal the target's native failure face; L1 still leases the last
        // observed body until a real target-visible report or session close.
        this.positionHandoff = null
        this.onPositionHandoff(null)
        console.info(`[ReaderPager] old_visual_revealed_failure=${handoff.serial} target=${handoff.targetIndex}`)
      }
    }))
  }

  private beginMotion(): void {
    this.entryTransition?.cancel('pager-motion')
    if (this.gestureNavigation < 0) this.gestureNavigation = this.snapshot.navigationRevision
    this.moving = true
  }

  private queueSelection(index: number): void {
    if (this.commandTarget >= 0 && index !== this.commandTarget) return
    if (index === this.snapshot.displayIndex) {
      this.gestureNavigation = -1
      return
    }
    const navigation = this.gestureNavigation >= 0 ? this.gestureNavigation : this.snapshot.navigationRevision
    const commandSerial = this.commandTarget >= 0 ? this.lastCommandSerial : 0
    this.gestureNavigation = -1
    if (this.pendingChange !== 0) clearTimeout(this.pendingChange)
    // ArkUI forbids refreshing LazyForEach child UI recursively inside onChange.
    // Keep the revision captured by this native pager, not a newer map's index space.
    this.pendingChange = setTimeout((): void => {
      this.pendingChange = 0
      if (!this.active) return
      if (commandSerial !== 0 && (commandSerial !== this.lastCommandSerial ||
        index !== this.commandTarget || navigation !== this.commandNavigation)) return
      this.onSelect(index, this.createdRevision, navigation)
      console.info(`[ReaderPager] selected=${index} topology=${this.createdRevision} navigation=${navigation}`)
    }, 0)
  }

  build() {
    Stack() {
    Swiper(this.controller) {
      LazyForEach(this.source, (key: string) => {
        ReaderPagedViewport({
          imageInterpolation: this.imageInterpolation,
          pageGap: this.pageGap,
          retainedProjectionDiagnostic: this.retainedProjectionDiagnostic,
          snapshot: this.snapshot.forItem(key),
          entryTransition: key === this.snapshot.displayKeys[this.snapshot.displayIndex] ? this.entryTransition : null,
          selected: key === this.snapshot.displayKeys[this.snapshot.displayIndex],
          active: this.active && !this.moving && key === this.snapshot.displayKeys[this.snapshot.displayIndex],
          zoomResetCommand: this.zoomResetCommand,
          onInputLockChange: (locked: boolean): void => {
            if (key === this.snapshot.displayKeys[this.snapshot.displayIndex]) this.inputLocked = locked
          },
          onZoomedChange: (zoomed: boolean): void => {
            if (key === this.snapshot.displayKeys[this.snapshot.displayIndex]) {
              this.onZoomedChange(zoomed, this.createdRevision, this.snapshot.navigationRevision)
            }
          },
          onPresented: this.onPresented,
          onVisualClaim: this.onVisualClaim,
          onTap: this.onTap,
          onVisible: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment): void => {
            this.visibleAfterHandoff(key, selectionId, slotId, requestId, fragment)
          },
          onRetry: (slotId: number, requestId: number): void => {
            this.onRetry(this.createdRevision, key, slotId, requestId)
          },
          onNoticeAction: (slotId: number, requestId: number, noticeId: string): Promise<boolean> => {
            return this.onNoticeAction(this.createdRevision, this.snapshot.navigationRevision,
              key, slotId, requestId, noticeId)
          },
          onFailed: (selectionId: number, slotId: number, requestId: number, fragment: ReaderFragment): void => {
            this.failedAfterHandoff(key, selectionId, slotId, requestId, fragment)
          },
        })
      }, (key: string): string => readerElementKey(key))
    }
    .index(this.snapshot.displayIndex)
    .vertical(this.snapshot.policy.pagingAxis === 'vertical')
    .direction(this.snapshot.policy.pagingAxis !== 'vertical' && this.snapshot.policy.direction === 'rtl' ?
      Direction.Rtl : Direction.Ltr)
    .loop(false).indicator(false).cachedCount(1)
    .disableSwipe(!this.active || this.snapshot.phase !== 'ready' || this.inputLocked ||
      this.positionHandoff !== null)
    .width('100%').height('100%').id('rkit-native-pager')
    .onTouch((event: TouchEvent): void => { this.handleBoundaryTouch(event) })
    .onGestureSwipe((): void => {
      this.commandTarget = -1
      this.commandNavigation = -1
      this.beginMotion()
    })
    .onAnimationStart((): void => { this.beginMotion() })
    .onScrollStateChanged((state: ScrollState): void => {
      if (state !== ScrollState.Idle) this.entryTransition?.cancel(`pager-scroll-state=${state}`)
      this.moving = state !== ScrollState.Idle
    })
    .onAnimationEnd((): void => { this.moving = false })
    .onChange((index: number): void => { this.queueSelection(index) })
    if (this.positionHandoff !== null) {
      ReaderPagedViewport({
        imageInterpolation: this.imageInterpolation,
        pageGap: this.pageGap,
        snapshot: this.positionHandoff.oldProjection,
        selected: false,
        active: false,
      })
      .width('100%').height('100%').hitTestBehavior(HitTestMode.None)
      .onAppear((): void => {
        this.oldVisualMounted = true
        const command = this.pendingOffCommand
        if (command !== null) this.startOffCommandAfterFrame(command)
      })
      .onDisAppear((): void => { this.oldVisualMounted = false })
    }
    }
    .width('100%').height('100%')
  }
}
