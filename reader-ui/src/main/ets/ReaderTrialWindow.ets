import { ReaderSystemBarController } from './ReaderSystemBarController'
import { common } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { ReaderEntryTransition } from './ReaderEntryTransition'
import { readerSourceStatusBarVisible, writeReaderSystemBarVisibility } from './ReaderSourceWindowPolicy'

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

/** Compatibility entrypoint; all callers use the same ordered shared controller. */
export async function applyReaderStatusBar(context: common.UIAbilityContext, visible: boolean,
  properties: window.SystemBarProperties, entry: () => ReaderEntryTransition | null,
  rootPresentationSettled: () => boolean, isCurrent: () => boolean, restoringSource: boolean = false): Promise<void> {
  const controller = new ReaderSystemBarController(
    (): Promise<window.Window> => window.getLastWindow(context),
    (): boolean => readerEntryWindowReady(entry(), rootPresentationSettled()),
    (win: window.Window, statusVisible: boolean, restoring: boolean, current: () => boolean): Promise<void> =>
      writeReaderSystemBarVisibility(win, statusVisible, !restoring, current))
  await controller.request(restoringSource ? readerSourceStatusBarVisible() : visible,
    properties, isCurrent, restoringSource)
}

export type ReaderTrialCloseSystemAvoidAreaResult = 'pending' | 'not-required' | 'already-visible' | 'source-area-unchanged' | 'ready' | 'failed'

/** Optional host-owned window lease, separate from the reader surface/session.
 * Restore exactly the pre-trial colors, including if close races window lookup.
 * Status visibility is opt-in, with its restoration value supplied by the host.
 * It never changes orientation or stored preferences.
 */
export class ReaderTrialWindow {
  private static operations: Promise<void> = Promise.resolve()
  readonly presentation: ReaderSystemBarController
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

  private async restoreStatus(visible: boolean, restoring: boolean = true, isCurrent: () => boolean = (): boolean => true): Promise<void> {
    const win = this.mainWindow
    if (win === null) return
    let sourceAreaUnchanged: boolean = false
    const visibleTop = (): boolean => {
      const top = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height
      sourceAreaUnchanged = restoring && visible && top === 0 &&
        this.presentation.sourceAllowsEmptyStatusArea(win, visible)
      return (top > 0) === visible || sourceAreaUnchanged
    }
    let alreadyVisible: boolean = false
    try { alreadyVisible = visibleTop() } catch (error) {
      // A failed readiness read must not suppress the host's restoration request.
      try { await this.writeStatusVisible(visible, restoring, isCurrent) } catch (_) {}
      throw error as Error
    }
    if (alreadyVisible) {
      await this.writeStatusVisible(visible, restoring, isCurrent)
      if (restoring) this.closeSystemAvoidAreaResult = sourceAreaUnchanged ? 'source-area-unchanged' :
        visible ? 'already-visible' : 'ready'
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
        if (restoring) this.closeSystemAvoidAreaResult = ready ? (sourceAreaUnchanged ? 'source-area-unchanged' : 'ready') : 'failed'
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
        this.writeStatusVisible(visible, restoring, isCurrent).then((): void => {
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
      this.writeStatusVisible(visible, restoring, isCurrent).then((): void => {
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
  private restoreStatusVisible: boolean | (() => boolean) | null
  private entry: () => ReaderEntryTransition | null
  private rootPresentationSettled: () => boolean

  private canPresent(): boolean {
    return !this.closed && readerEntryWindowReady(this.entry(), this.rootPresentationSettled())
  }

  /** Navigation colors consume the same intent as the serialized Window writer. */
  statusBarVisible(): boolean { return this.presentation.visible }

  constructor(observer: ((event: string) => void) | null, restoreStatusVisible: boolean | (() => boolean) | null,
    entry: () => ReaderEntryTransition | null, rootPresentationSettled: () => boolean) {
    this.observer = observer
    this.restoreStatusVisible = restoreStatusVisible
    this.entry = entry
    this.rootPresentationSettled = rootPresentationSettled
    this.presentation = new ReaderSystemBarController(async (): Promise<window.Window | null> => this.mainWindow,
      (): boolean => this.started && this.canPresent(),
      (win: window.Window, visible: boolean, restoring: boolean, current: () => boolean): Promise<void> =>
        writeReaderSystemBarVisibility(win, visible, !restoring, current), restoreStatusVisible !== null)
  }

  private async writeStatusVisible(visible: boolean, restoring: boolean = false,
    isCurrent: () => boolean = (): boolean => true): Promise<void> {
    if (this.mainWindow === null || (!restoring && (!isCurrent() || !this.canPresent()))) return
    this.observe(`status_visibility_requested visible=${visible}`)
    await writeReaderSystemBarVisibility(this.mainWindow, visible, !restoring,
      (): boolean => restoring || (isCurrent() && this.canPresent()))
    this.observe(`status_visibility_succeeded visible=${visible}`)
  }

  setStatusBarVisible(visible: boolean, isCurrent: () => boolean = (): boolean => true): void {
    if (this.closed) return
    void this.presentation.requestVisible(visible, true, isCurrent)
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
        this.presentation.captureSourceLayout(mainWindow, typeof this.restoreStatusVisible === 'function'
          ? this.restoreStatusVisible() : this.restoreStatusVisible)
        this.observe(`saved ${JSON.stringify(this.previous)}`)
      }
      if (!this.canPresent()) { this.started = false; return }
      await this.presentation.replay()
    }, 'open_failed')
  }

  /** The optional bounded host-layout callback must not await this window queue.
   * Visibility policies are resolved at close dispatch; both visible and hidden
   * source layouts settle before colors and the host's return flight.
   */
  close(beforeRestoreColors: (() => Promise<boolean>) | null = null): Promise<void> {
    if (this.closing !== null) return this.closing
    this.closed = true
    const presentationSettled = this.presentation.cancel()
    this.closeSystemAvoidAreaResult = this.restoreStatusVisible !== null ? 'pending' : 'not-required'
    this.closing = ReaderTrialWindow.enqueue(async (): Promise<void> => {
      await presentationSettled
      if (this.mainWindow !== null && this.previous !== null) {
        let restoreError: Error | null = null
        const restoreVisible: boolean | null = typeof this.restoreStatusVisible === 'function'
          ? this.restoreStatusVisible() : this.restoreStatusVisible
        const layoutBeforeColors = restoreVisible !== null && beforeRestoreColors !== null
        if (layoutBeforeColors) {
          try {
            await this.restoreStatus(restoreVisible!)
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
        if (!layoutBeforeColors && restoreVisible !== null) {
          try {
            await this.restoreStatus(restoreVisible!)
          } catch (error) {
            if (restoreVisible !== null) this.closeSystemAvoidAreaResult = 'failed'
            this.observe(`status_visibility_restore_failed ${(error as Error).message}`)
            if (restoreError === null) restoreError = error as Error
            else restoreError = new Error(`${restoreError.message}; status_visibility_restore_failed ${(error as Error).message}`)
          }
        }
        if (restoreError !== null) {
          if (restoreVisible !== null) this.closeSystemAvoidAreaResult = 'failed'
          throw restoreError
        }
      } else {
        this.closeSystemAvoidAreaResult = 'not-required'
      }
    }, 'restore_failed')
    return this.closing
  }
}
