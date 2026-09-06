import { common } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'

/** Optional host-owned window lease, separate from the reader surface/session.
 * Restore exactly the pre-trial colors, including if close races window lookup.
 * It does not change status visibility, orientation or stored preferences.
 */
export class ReaderTrialWindow {
  private closed: boolean = false
  private mainWindow: window.Window | null = null
  private previous: window.SystemBarProperties | null = null
  private opening: Promise<void> = Promise.resolve()

  open(context: common.UIAbilityContext): void {
    this.opening = window.getLastWindow(context).then(async (mainWindow: window.Window): Promise<void> => {
      if (this.closed) return
      this.mainWindow = mainWindow
      this.previous = mainWindow.getWindowSystemBarProperties()
      await mainWindow.setWindowSystemBarProperties({ statusBarContentColor: '#FFFFFFFF' })
      console.info('[ReaderTrialWindow] status_content=light')
    }).catch((error: Error): void => { console.warn(`[ReaderTrialWindow] open_failed=${error.message}`) })
  }

  close(): void {
    if (this.closed) return
    this.closed = true
    void this.opening.then(async (): Promise<void> => {
      if (this.mainWindow !== null && this.previous !== null) {
        await this.mainWindow.setWindowSystemBarProperties(this.previous)
        console.info('[ReaderTrialWindow] status_properties_restored')
      }
    }).catch((error: Error): void => { console.warn(`[ReaderTrialWindow] restore_failed=${error.message}`) })
  }
}
