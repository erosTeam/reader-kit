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
      await mainWindow.setWindowSystemBarProperties({ statusBarContentColor: '#FFFFFFFF' })
      console.info('[ReaderTrialWindow] status_content=light')
    }, 'open_failed')
  }

  close(): Promise<void> {
    if (this.closing !== null) return this.closing
    this.closed = true
    this.closing = ReaderTrialWindow.enqueue(async (): Promise<void> => {
      if (this.mainWindow !== null && this.previous !== null) {
        await this.mainWindow.setWindowSystemBarProperties(this.previous)
        console.info('[ReaderTrialWindow] status_properties_restored')
      }
    }, 'restore_failed')
    return this.closing
  }
}
