import { common } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'

export type ReaderTrialCloseSystemAvoidAreaResult = 'pending' | 'not-required' | 'already-visible' | 'ready' | 'failed'

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

  private async restoreVisibleStatus(restoring: boolean = true): Promise<void> {
    const win = this.mainWindow
    if (win === null) return
    const visibleTop = (): boolean => {
      return win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height > 0
    }
    let alreadyVisible: boolean = false
    try { alreadyVisible = visibleTop() } catch (error) {
      // A failed readiness read must not suppress the host's restoration request.
      try { await this.writeStatusVisible(true) } catch (_) {}
      throw error as Error
    }
    if (alreadyVisible) {
      await this.writeStatusVisible(true)
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
        if (!restoring && this.closed) {
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
        this.writeStatusVisible(true).then((): void => {
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
      this.writeStatusVisible(true).then((): void => {
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
  private desiredStatusVisible: boolean = true

  /** System top-area readiness only; callers must separately await their layout. */
  async prepareStatusBarVisible(): Promise<boolean> {
    if (this.closed || this.restoreStatusVisible === null || !this.started || this.mainWindow === null) return false
    let ready: boolean = false
    await ReaderTrialWindow.enqueue(async (): Promise<void> => {
      if (this.closed || this.mainWindow === null) return
      this.desiredStatusVisible = true
      this.observe('prepare_system_avoid_area_requested')
      try {
        await this.restoreVisibleStatus(false)
        ready = !this.closed
        this.observe(`prepare_status_visibility_completed ready=${ready}`)
      } catch (error) {
        this.observe(`prepare_status_visibility_failed ${(error as Error).message}`)
      }
    }, 'prepare_status_visibility_failed')
    return ready
  }

  constructor(observer: ((event: string) => void) | null = null, restoreStatusVisible: boolean | null = null) {
    this.observer = observer
    this.restoreStatusVisible = restoreStatusVisible
  }

  private async writeStatusVisible(visible: boolean): Promise<void> {
    if (this.mainWindow === null) return
    this.observe(`status_visibility_requested visible=${visible}`)
    await this.mainWindow.setSpecificSystemBarEnabled('status', visible, false)
    this.observe(`status_visibility_succeeded visible=${visible}`)
  }

  setStatusBarVisible(visible: boolean): void {
    if (this.closed) return
    this.desiredStatusVisible = visible
    if (this.restoreStatusVisible === null || !this.started) return
    ReaderTrialWindow.enqueue(async (): Promise<void> => {
      if (this.closed || this.mainWindow === null) return
      await this.writeStatusVisible(this.desiredStatusVisible)
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
      if (this.closed) return
      const mainWindow = await window.getLastWindow(context)
      if (this.closed) return
      this.mainWindow = mainWindow
      this.previous = mainWindow.getWindowSystemBarProperties()
      this.observe(`saved ${JSON.stringify(this.previous)}`)
      await mainWindow.setWindowSystemBarProperties({ statusBarContentColor: '#FFFFFFFF' })
      console.info('[ReaderTrialWindow] status_content=light')
      if (!this.closed && this.restoreStatusVisible !== null) {
        await this.writeStatusVisible(this.desiredStatusVisible)
      }
    }, 'open_failed')
  }

  close(): Promise<void> {
    if (this.closing !== null) return this.closing
    this.closed = true
    this.closeSystemAvoidAreaResult = this.restoreStatusVisible === true ? 'pending' : 'not-required'
    this.closing = ReaderTrialWindow.enqueue(async (): Promise<void> => {
      if (this.mainWindow !== null && this.previous !== null) {
        let restoreError: Error | null = null
        this.observe(`restore_called ${JSON.stringify(this.previous)}`)
        try {
          await this.mainWindow.setWindowSystemBarProperties(this.previous)
          this.observe('restore_succeeded')
          this.observeProperties('restore_readback')
          console.info('[ReaderTrialWindow] status_properties_restored')
        } catch (error) {
          this.observe(`restore_failed ${(error as Error).message}`)
          restoreError = error as Error
        }
        if (this.restoreStatusVisible !== null) {
          try {
            if (this.restoreStatusVisible) await this.restoreVisibleStatus()
            else await this.writeStatusVisible(false)
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
