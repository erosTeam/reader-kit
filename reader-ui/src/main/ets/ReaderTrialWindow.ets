import { common } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { ReaderEntryTransition } from './ReaderEntryTransition'

/** Source window ownership ends only after both content and root handoff. */
export function readerEntryWindowReady(entry: ReaderEntryTransition | null, rootPresentationSettled: boolean): boolean {
  return rootPresentationSettled && entry?.pending() !== true
}

/** Native navigation is also a color writer; it must consume the same admission. */
export function readerEntryStatusBarStyle(entry: ReaderEntryTransition | null, rootPresentationSettled: boolean,
  sourceContentColor: string, readerContentColor: string, statusVisible: boolean): window.SystemBarStyle {
  return { statusBarContentColor: statusVisible && readerEntryWindowReady(entry, rootPresentationSettled)
    ? readerContentColor : sourceContentColor }
}

/** Host queue owns ordering; the shared writer owns entry admission at dispatch. */
export async function applyReaderStatusBar(context: common.UIAbilityContext, visible: boolean,
  properties: window.SystemBarProperties, entry: () => ReaderEntryTransition | null,
  rootPresentationSettled: () => boolean, isCurrent: () => boolean): Promise<void> {
  const admitted = (): boolean => isCurrent() && readerEntryWindowReady(entry(), rootPresentationSettled())
  if (!admitted()) return
  const win = await window.getLastWindow(context)
  if (!admitted()) return
  if (visible) await win.setWindowSystemBarProperties(properties)
  if (!admitted()) return
  await win.setSpecificSystemBarEnabled('status', visible, false)
}

export type ReaderTrialCloseSystemAvoidAreaResult = 'pending' | 'not-required' | 'already-visible' | 'ready' | 'failed'

@ObservedV2
class ReaderStatusVisibilityRequest {
  @Trace visible: boolean
  isCurrent: () => boolean

  constructor(visible: boolean, isCurrent: () => boolean) {
    this.visible = visible
    this.isCurrent = isCurrent
  }
}

/** Optional host-owned window lease, separate from the reader surface/session.
 * Restore exactly the pre-trial colors, including if close races window lookup.
 * Status visibility is opt-in, with its restoration value supplied by the host.
 * It never changes orientation or stored preferences.
 */
export class ReaderTrialWindow {
  private static operations: Promise<void> = Promise.resolve()
  private started: boolean = false
  private closed: boolean = false
  private mainWindow: window.Window | null = null
  private previous: window.SystemBarProperties | null = null
  private closing: Promise<void> | null = null
  private closeSystemAvoidAreaResult: ReaderTrialCloseSystemAvoidAreaResult = 'not-required'

  /** Window readiness only; the host must separately await its actual layout commit. */
  getCloseSystemAvoidAreaResult(): ReaderTrialCloseSystemAvoidAreaResult {
    return this.closeSystemAvoidAreaResult
  }

  private async restoreVisibleStatus(restoring: boolean = true, isCurrent: () => boolean = (): boolean => true): Promise<void> {
    const win = this.mainWindow
    if (win === null) return
    const visibleTop = (): boolean => {
      return win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height > 0
    }
    let alreadyVisible: boolean = false
    try { alreadyVisible = visibleTop() } catch (error) {
      // A failed readiness read must not suppress the host's restoration request.
      try { await this.writeStatusVisible(true, restoring, isCurrent) } catch (_) {}
      throw error as Error
    }
    if (alreadyVisible) {
      await this.writeStatusVisible(true, restoring, isCurrent)
      if (restoring) this.closeSystemAvoidAreaResult = 'already-visible'
      return
    }
    await new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
      let settled: boolean = false
      let setterSucceeded: boolean = false
      let setterCompleted: boolean = false
      let pendingFailure: string = ''
      let timer: number = -1
      const finish = (ready: boolean, message: string): void => {
        if (settled) return
        settled = true
        if (timer >= 0) clearTimeout(timer)
        try { win.off('avoidAreaChange', changed) } catch (_) {}
        if (restoring) this.closeSystemAvoidAreaResult = ready ? 'ready' : 'failed'
        this.observe(`${restoring ? 'close' : 'prepare'}_system_avoid_area_${ready ? 'ready' : 'failed'} ${message}`)
        if (ready) resolve()
        else if (setterCompleted) reject(new Error(message))
        else pendingFailure = message
      }
      const check = (): void => {
        if (settled || !setterSucceeded) return
        if (!restoring && (!this.canPresent() || !isCurrent())) {
          finish(false, 'closed')
          return
        }
        try { if (visibleTop()) finish(true, 'visible') } catch (error) {
          finish(false, (error as Error).message)
        }
      }
      const changed = (data: window.AvoidAreaOptions): void => {
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM) check()
      }
      try { win.on('avoidAreaChange', changed) } catch (error) {
        this.writeStatusVisible(true, restoring, isCurrent).then((): void => {
          setterCompleted = true
          finish(false, (error as Error).message)
        }).catch((restoreError: Error): void => {
          setterCompleted = true
          finish(false, restoreError.message)
        })
        return
      }
      // Failure bound, never a delay that implies presentation or layout success.
      timer = setTimeout((): void => finish(false, 'timeout'), 2000)
      this.writeStatusVisible(true, restoring, isCurrent).then((): void => {
        setterCompleted = true
        if (settled) {
          reject(new Error(pendingFailure))
          return
        }
        setterSucceeded = true
        check()
      }).catch((error: Error): void => {
        setterCompleted = true
        if (settled) reject(new Error(pendingFailure || error.message))
        else finish(false, error.message)
      })
    })
  }

  private observer: ((event: string) => void) | null = null
  private restoreStatusVisible: boolean | null
  private desiredStatus: ReaderStatusVisibilityRequest = new ReaderStatusVisibilityRequest(true,
    (): boolean => this.canPresent())
  private entry: () => ReaderEntryTransition | null
  private rootPresentationSettled: () => boolean

  private canPresent(): boolean {
    return !this.closed && readerEntryWindowReady(this.entry(), this.rootPresentationSettled())
  }

  /** Navigation colors consume the same intent as the serialized Window writer. */
  statusBarVisible(): boolean { return this.desiredStatus.visible }

  /** System top-area readiness only; callers must separately await their layout. */
  async prepareStatusBarVisible(isCurrent: () => boolean): Promise<boolean> {
    if (!isCurrent() || !this.canPresent() || this.restoreStatusVisible === null || !this.started || this.mainWindow === null) return false
    let ready: boolean = false
    await ReaderTrialWindow.enqueue(async (): Promise<void> => {
      if (!isCurrent() || !this.canPresent() || this.mainWindow === null) return
      this.desiredStatus.isCurrent = isCurrent
      this.desiredStatus.visible = true
      this.observe('prepare_system_avoid_area_requested')
      try {
        await this.mainWindow.setWindowSystemBarProperties({ statusBarContentColor: '#FFFFFFFF' })
        if (!isCurrent() || !this.canPresent()) return
        await this.restoreVisibleStatus(false, isCurrent)
        ready = isCurrent() && this.canPresent()
        this.observe(`prepare_status_visibility_completed ready=${ready}`)
      } catch (error) {
        this.observe(`prepare_status_visibility_failed ${(error as Error).message}`)
      }
    }, 'prepare_status_visibility_failed')
    return ready
  }

  constructor(observer: ((event: string) => void) | null, restoreStatusVisible: boolean | null,
    entry: () => ReaderEntryTransition | null, rootPresentationSettled: () => boolean) {
    this.observer = observer
    this.restoreStatusVisible = restoreStatusVisible
    this.entry = entry
    this.rootPresentationSettled = rootPresentationSettled
  }

  private async writeStatusVisible(visible: boolean, restoring: boolean = false,
    isCurrent: () => boolean = (): boolean => true): Promise<void> {
    if (this.mainWindow === null || (!restoring && (!isCurrent() || !this.canPresent()))) return
    this.observe(`status_visibility_requested visible=${visible}`)
    await this.mainWindow.setSpecificSystemBarEnabled('status', visible, false)
    this.observe(`status_visibility_succeeded visible=${visible}`)
  }

  setStatusBarVisible(visible: boolean, isCurrent: () => boolean): void {
    if (this.closed || !isCurrent()) return
    this.desiredStatus.isCurrent = isCurrent
    this.desiredStatus.visible = visible
    if (this.restoreStatusVisible === null || !this.started) return
    ReaderTrialWindow.enqueue(async (): Promise<void> => {
      if (!isCurrent() || !this.canPresent() || this.mainWindow === null) return
      const request = this.desiredStatus
      await this.writeStatusVisible(request.visible, false, request.isCurrent)
    }, 'status_visibility_failed')
  }

  private observe(event: string): void {
    // Diagnostics must not change lease completion or platform error handling.
    try { this.observer?.(`${Date.now()} ${event}`) } catch (_) {}
  }

  private observeProperties(event: string): void {
    if (this.observer === null || this.mainWindow === null) return
    try {
      this.observe(`${event} ${JSON.stringify(this.mainWindow.getWindowSystemBarProperties())}`)
    } catch (error) {
      this.observe(`${event}_failed ${(error as Error).message}`)
    }
  }

  private static enqueue(operation: () => Promise<void>, failure: string): Promise<void> {
    const completion = ReaderTrialWindow.operations.then(operation).catch((error: Error): void => {
      console.warn(`[ReaderTrialWindow] ${failure}=${error.message}`)
    })
    // Each submitted platform operation settles before another lease reads or writes colors.
    // The observed failure is handled here so legacy void consumers cannot leak a rejection.
    ReaderTrialWindow.operations = completion
    return completion
  }

  open(context: common.UIAbilityContext): void {
    if (this.started || this.closed) return
    this.started = true
    ReaderTrialWindow.enqueue(async (): Promise<void> => {
      if (this.closed) { this.started = false; return }
      // Capture while navigation still uses the source style. Reading the
      // baseline does not grant presentation; a later replay reuses it.
      if (this.mainWindow === null) {
        const mainWindow = await window.getLastWindow(context)
        if (this.closed) { this.started = false; return }
        this.mainWindow = mainWindow
        this.previous = mainWindow.getWindowSystemBarProperties()
        this.observe(`saved ${JSON.stringify(this.previous)}`)
      }
      if (!this.canPresent()) { this.started = false; return }
      const mainWindow = this.mainWindow
      if (this.restoreStatusVisible === null || this.desiredStatus.visible) {
        await mainWindow.setWindowSystemBarProperties({ statusBarContentColor: '#FFFFFFFF' })
        console.info('[ReaderTrialWindow] status_content=light')
      }
      if (this.canPresent() && this.restoreStatusVisible !== null) {
        const request = this.desiredStatus
        await this.writeStatusVisible(request.visible, false, request.isCurrent)
      }
    }, 'open_failed')
  }

  /** The optional bounded host-layout callback must not await this window queue.
   * Only restore-visible leases use it; other leases retain their legacy order.
   */
  close(beforeRestoreColors: (() => Promise<boolean>) | null = null): Promise<void> {
    if (this.closing !== null) return this.closing
    this.closed = true
    this.closeSystemAvoidAreaResult = this.restoreStatusVisible === true ? 'pending' : 'not-required'
    this.closing = ReaderTrialWindow.enqueue(async (): Promise<void> => {
      if (this.mainWindow !== null && this.previous !== null) {
        let restoreError: Error | null = null
        const layoutBeforeColors = this.restoreStatusVisible === true && beforeRestoreColors !== null
        if (layoutBeforeColors) {
          try {
            await this.restoreVisibleStatus()
            this.observe('close_before_restore_colors_requested')
            const layoutReady = await beforeRestoreColors!()
            this.observe(`close_before_restore_colors_completed ready=${layoutReady}`)
            if (!layoutReady) throw new Error('host_layout_not_ready')
          } catch (error) {
            this.closeSystemAvoidAreaResult = 'failed'
            this.observe(`close_before_restore_colors_failed ${(error as Error).message}`)
            restoreError = error as Error
          }
        }
        this.observe(`restore_called ${JSON.stringify(this.previous)}`)
        try {
          await this.mainWindow.setWindowSystemBarProperties(this.previous)
          this.observe('restore_succeeded')
          this.observeProperties('restore_readback')
          console.info('[ReaderTrialWindow] status_properties_restored')
        } catch (error) {
          this.observe(`restore_failed ${(error as Error).message}`)
          restoreError = restoreError === null ? error as Error :
            new Error(`${restoreError.message}; restore_failed ${(error as Error).message}`)
        }
        if (!layoutBeforeColors && this.restoreStatusVisible !== null) {
          try {
            if (this.restoreStatusVisible) await this.restoreVisibleStatus()
            else await this.writeStatusVisible(false, true)
          } catch (error) {
            if (this.restoreStatusVisible) this.closeSystemAvoidAreaResult = 'failed'
            this.observe(`status_visibility_restore_failed ${(error as Error).message}`)
            if (restoreError === null) restoreError = error as Error
            else restoreError = new Error(`${restoreError.message}; status_visibility_restore_failed ${(error as Error).message}`)
          }
        }
        if (restoreError !== null) {
          if (this.restoreStatusVisible) this.closeSystemAvoidAreaResult = 'failed'
          throw restoreError
        }
      } else {
        this.closeSystemAvoidAreaResult = 'not-required'
      }
    }, 'restore_failed')
    return this.closing
  }
}
