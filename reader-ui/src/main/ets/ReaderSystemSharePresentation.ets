import { common } from '@kit.AbilityKit'
import { systemShare } from '@kit.ShareKit'
import { ReaderImageSharePresentation } from '@reader-kit/core'

/** Platform presentation only. Hosts construct the record and retain source ownership. */
export class ReaderSystemSharePresentation implements ReaderImageSharePresentation {
  private context: common.UIAbilityContext
  private controller: systemShare.ShareController
  private options: systemShare.ShareControllerOptions
  private started: boolean = false

  constructor(context: common.UIAbilityContext, data: systemShare.SharedData,
    options: systemShare.ShareControllerOptions) {
    this.context = context
    this.controller = new systemShare.ShareController(data)
    this.options = options
  }

  present(): Promise<void> {
    if (this.started) return Promise.reject(new Error('reader_share_already_presented'))
    this.started = true
    return new Promise<void>((resolve, reject): void => {
      let finished = false
      let listening = false
      const finish = (failed: boolean): void => {
        if (finished) return
        finished = true
        if (listening) {
          try { this.controller.off('dismiss', dismissed) } catch (_) {
            console.warn('[ReaderShare] dismiss listener cleanup failed')
          }
        }
        if (failed) reject(new Error('reader_share_presentation_failed'))
        else resolve()
      }
      const dismissed = (): void => { finish(false) }
      try {
        this.controller.on('dismiss', dismissed)
        listening = true
        // The show Promise resolves on appearance. Only dismiss completes this operation.
        this.controller.show(this.context, this.options).catch((): void => { finish(true) })
      } catch (_) { finish(true) }
    })
  }

  release(): void { /* Host cache/URL lifetime is not owned by the system sheet wrapper. */ }
}
