import { common } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'

/** Host-owned foreground reading capability; no preference or reader-state ownership. */
export class ReaderKeepScreenOn {
  private static operations: Promise<void> = Promise.resolve()
  private context: common.UIAbilityContext
  private desired: boolean = false
  private closed: boolean = false
  private mainWindow: window.Window | null = null
  private previous: boolean | null = null

  constructor(context: common.UIAbilityContext) { this.context = context }

  setActive(enabled: boolean): void {
    console.info(`[ReaderKeepScreenOn] requested=${enabled} previousDesired=${this.desired} closed=${this.closed}`)
    if (this.closed || this.desired === enabled) return
    this.desired = enabled
    this.enqueue()
  }

  close(): Promise<void> {
    this.closed = true
    this.desired = false
    return this.enqueue()
  }

  private enqueue(): Promise<void> {
    const completion = ReaderKeepScreenOn.operations.then(async (): Promise<void> => {
      if (this.desired && !this.closed) {
        if (this.previous !== null) return
        const win = await window.getLastWindow(this.context)
        if (!this.desired || this.closed) return
        this.mainWindow = win
        this.previous = win.getWindowProperties().isKeepScreenOn
        await win.setWindowKeepScreenOn(true)
        console.info(`[ReaderKeepScreenOn] enabled_readback=${win.getWindowProperties().isKeepScreenOn}`)
      } else if (this.previous !== null && this.mainWindow !== null) {
        await this.mainWindow.setWindowKeepScreenOn(this.previous)
        this.previous = null
        this.mainWindow = null
      }
    }).catch((error: Error): void => {
      console.warn(`[ReaderKeepScreenOn] window_policy_failed=${error.message}`)
    })
    ReaderKeepScreenOn.operations = completion
    return completion
  }
}
