import { FrameCallback, UIContext } from '@kit.ArkUI'

class ReaderTrialLayoutFrame extends FrameCallback {
  private idle: () => void
  constructor(idle: () => void) { super(); this.idle = idle }
  onIdle(_timeLeftInNano: number): void { this.idle() }
}

class ReaderTrialLayoutWait {
  private done: boolean = false
  private watchdog: number = 0
  private frames: number = 0
  private previous: string = ''
  private uiContext: UIContext
  private sample: () => string
  private isCurrent: () => boolean
  private resolve: (ready: boolean) => void

  constructor(uiContext: UIContext, sample: () => string, isCurrent: () => boolean,
    resolve: (ready: boolean) => void) {
    this.uiContext = uiContext; this.sample = sample; this.isCurrent = isCurrent; this.resolve = resolve
  }

  start(): void {
    this.watchdog = setTimeout((): void => { this.finish(false) }, 2000)
    this.schedule()
  }

  private finish(ready: boolean): void {
    if (this.done) return
    this.done = true
    if (this.watchdog !== 0) clearTimeout(this.watchdog)
    this.watchdog = 0
    this.resolve(ready)
  }

  private schedule(): void {
    if (this.done) return
    try {
      if (!this.isCurrent()) { this.finish(false); return }
      this.uiContext.postFrameCallback(new ReaderTrialLayoutFrame((): void => { this.onFrame() }))
    } catch (_) { this.finish(false) }
  }

  private onFrame(): void {
    if (this.done) return
    try {
      if (!this.isCurrent()) { this.finish(false); return }
      const key = this.sample()
      if (!this.isCurrent()) { this.finish(false); return }
      this.frames += 1
      if (key.length > 0 && key === this.previous) { this.finish(true); return }
      this.previous = key
      if (this.frames >= 60) { this.finish(false); return }
      this.schedule()
    } catch (_) { this.finish(false) }
  }
}

/** Host-owned layout observations; no application state, geometry mutation or movement requirement. */
export class ReaderTrialLayoutCommit {
  static wait(uiContext: UIContext, sample: () => string, isCurrent: () => boolean): Promise<boolean> {
    return new Promise<boolean>((resolve: (ready: boolean) => void): void => {
      new ReaderTrialLayoutWait(uiContext, sample, isCurrent, resolve).start()
    })
  }
}
