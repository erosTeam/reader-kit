import { common } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'

/** Optional host-owned window lease, separate from the reader surface/session.
 * Restore exactly the pre-trial colors, including if close races window lookup.
 * It does not change status visibility, orientation or stored preferences.
 */
export class ReaderTrialWindow {
  private static operations: Promise<void> = Promise.resolve()
  private started: boolean = false
  private closed: boolean = false
  private mainWindow: window.Window | null = null
  private previous: window.SystemBarProperties | null = null
  private closing: Promise<void> | null = null

  private observer: ((event: string) => void) | null = null

  constructor(observer: ((event: string) => void) | null = null) {
    this.observer = observer
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
    }, 'open_failed')
  }

  close(): Promise<void> {
    if (this.closing !== null) return this.closing
    this.closed = true
    this.closing = ReaderTrialWindow.enqueue(async (): Promise<void> => {
      if (this.mainWindow !== null && this.previous !== null) {
        this.observe(`restore_called ${JSON.stringify(this.previous)}`)
        try {
          await this.mainWindow.setWindowSystemBarProperties(this.previous)
        } catch (error) {
          this.observe(`restore_failed ${(error as Error).message}`)
          throw error as Error
        }
        this.observe('restore_succeeded')
        this.observeProperties('restore_readback')
        console.info('[ReaderTrialWindow] status_properties_restored')
      }
    }, 'restore_failed')
    return this.closing
  }
}
