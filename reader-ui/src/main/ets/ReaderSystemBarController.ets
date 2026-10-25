import { window } from '@kit.ArkUI'

export type ReaderSystemBarWriter = (win: window.Window, visible: boolean,
  restoringSource: boolean, isCurrent: () => boolean) => Promise<void>

/** A native setter receipt does not mean the bar is on screen (Window API).
 * Only a window that has actually supplied a status area needs its show event.
 * Unknown/zero-area windows stay usable; no remembered height places the chrome.
 * The deadline is failure recovery, never evidence that a bar became visible.
 */
class ReaderChromeStatusCompletion {
  readonly completion: Promise<void>
  private resolve: () => void = (): void => {}
  private done: boolean = false
  private nativeFinished: boolean = false
  private timer: number = -1
  private win: window.Window
  private current: () => boolean
  private changed: (data: window.AvoidAreaOptions) => void

  constructor(win: window.Window, waitForArea: boolean, current: () => boolean) {
    this.win = win; this.current = current
    this.completion = new Promise<void>((resolve: () => void): void => { this.resolve = resolve })
    this.changed = (data: window.AvoidAreaOptions): void => {
      if (data.type === window.AvoidAreaType.TYPE_SYSTEM) this.check()
    }
    if (!waitForArea) { this.finish(); return }
    try { win.on('avoidAreaChange', this.changed) } catch (_) { this.finish(); return }
    this.timer = setTimeout((): void => {
      if (this.current()) console.warn('[ReaderSystemBarController] chrome_status_area_unavailable')
      this.finish()
    }, 2000)
  }

  nativeComplete(): void { this.nativeFinished = true; this.check() }

  private check(): void {
    if (this.done || !this.nativeFinished) return
    if (!this.current()) { this.finish(); return }
    try {
      if (this.win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height > 0) this.finish()
    } catch (_) { this.finish() }
  }

  finish(): void {
    if (this.done) return
    this.done = true
    if (this.timer >= 0) clearTimeout(this.timer)
    try { this.win.off('avoidAreaChange', this.changed) } catch (_) {}
    this.resolve()
  }
}

/** One chrome policy and one ordered color/visibility operation for every host.
 * Surface awaits the actual show boundary before revealing chrome. No window,
 * zero-area/unsupported control or failure must still settle and leave it usable.
 * Hosts supply window ownership and, optionally, their source-window bridge.
 */
@ObservedV2
export class ReaderSystemBarController {
  private static operations: Promise<void> = Promise.resolve()
  @Trace visible: boolean = true
  @Trace lightIcons: boolean = true
  private revision: number = 0
  private current: () => boolean = (): boolean => true
  private properties: window.SystemBarProperties = { statusBarContentColor: '#FFFFFFFF' }
  private getWindow: () => Promise<window.Window | null>
  private admitted: (visible: boolean, restoringSource: boolean) => boolean
  private writeVisibility: ReaderSystemBarWriter
  private visibilityEnabled: boolean
  private emptySourceStatusRect: window.Rect | null = null
  private chromeAreaWindowRect: window.Rect | null = null
  private pendingChromeStatus: ReaderChromeStatusCompletion | null = null
  private currentSubmission: Promise<void> | null = null
  private runningRevision: number = -1

  constructor(getWindow: () => Promise<window.Window | null>,
    admitted: (visible: boolean, restoringSource: boolean) => boolean,
    writeVisibility: ReaderSystemBarWriter = async (win: window.Window, visible: boolean): Promise<void> => {
      await win.setSpecificSystemBarEnabled('status', visible, false)
    }, visibilityEnabled: boolean = true) {
    this.getWindow = getWindow
    this.admitted = admitted
    this.writeVisibility = writeVisibility
    this.visibilityEnabled = visibilityEnabled
  }

  /** A source with no status inset remains a valid restore target in the same
   * window. Keep this separate from return-target measurement and invalidate it
   * on every window-rectangle or source-policy change.
   */
  captureSourceLayout(win: window.Window, sourceStatusVisible: boolean | null): void {
    this.emptySourceStatusRect = null
    this.observeChromeArea(win)
    if (sourceStatusVisible !== true) return
    try {
      if (win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height !== 0) return
      const rect = win.getWindowProperties().windowRect
      this.emptySourceStatusRect = { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
    } catch (_) {}
  }

  sourceAllowsEmptyStatusArea(win: window.Window, sourceStatusVisible: boolean): boolean {
    const source = this.emptySourceStatusRect
    if (!sourceStatusVisible || source === null) return false
    try {
      const current = win.getWindowProperties().windowRect
      return current.left === source.left && current.top === source.top &&
        current.width === source.width && current.height === source.height
    } catch (_) { return false }
  }

  presentChrome(chromeVisible: boolean, fullscreen: boolean, canvasDark: boolean,
    isCurrent: () => boolean): Promise<void> {
    if (!isCurrent()) return Promise.resolve()
    const visible = chromeVisible || !fullscreen
    this.lightIcons = chromeVisible || canvasDark
    return this.request(visible, {
      statusBarContentColor: this.lightIcons ? '#FFFFFFFF' : '#FF000000',
    }, isCurrent, false, chromeVisible)
  }

  requestVisible(visible: boolean, lightIcons: boolean, isCurrent: () => boolean,
    restoringSource: boolean = false): Promise<void> {
    if (!isCurrent()) return Promise.resolve()
    this.lightIcons = lightIcons
    return this.request(visible, {
      statusBarContentColor: lightIcons ? '#FFFFFFFF' : '#FF000000',
    }, isCurrent, restoringSource)
  }

  request(visible: boolean, properties: window.SystemBarProperties, isCurrent: () => boolean,
    restoringSource: boolean = false, showingChrome: boolean = false): Promise<void> {
    if (!isCurrent()) return Promise.resolve()
    this.visible = visible
    this.properties = properties
    this.current = isCurrent
    return this.submit(visible, properties, isCurrent, restoringSource, showingChrome)
  }

  replay(): Promise<void> {
    // Replaying the same intent is not cancellation of its in-flight show.
    // In particular a host replay must not release Surface before the area arrives.
    if (this.currentSubmission !== null && this.runningRevision === this.revision) return this.currentSubmission
    return this.submit(this.visible, this.properties, this.current, false)
  }

  /** Closing retires queued shows before the lease restores its saved window. */
  cancel(): Promise<void> {
    this.revision += 1
    this.pendingChromeStatus?.finish()
    this.pendingChromeStatus = null
    return ReaderSystemBarController.operations
  }

  /** This is an applicability observation, not cached layout. A changed window
   * rectangle invalidates it, and a zero-area source never needs a positive inset.
   */
  private observeChromeArea(win: window.Window): boolean {
    try {
      const rect = win.getWindowProperties().windowRect
      const previous = this.chromeAreaWindowRect
      if (previous !== null && (previous.left !== rect.left || previous.top !== rect.top ||
        previous.width !== rect.width || previous.height !== rect.height)) this.chromeAreaWindowRect = null
      if (win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height > 0) {
        this.chromeAreaWindowRect = { left: rect.left, top: rect.top, width: rect.width, height: rect.height }
      }
      const status = win.getWindowStatus()
      return this.chromeAreaWindowRect !== null &&
        (status === window.WindowStatusType.FULL_SCREEN || status === window.WindowStatusType.MAXIMIZE)
    } catch (_) { return false }
  }

  private submit(visible: boolean, properties: window.SystemBarProperties, isCurrent: () => boolean,
    restoringSource: boolean, showingChrome: boolean = false): Promise<void> {
    this.pendingChromeStatus?.finish()
    this.pendingChromeStatus = null
    let statusCompletion: ReaderChromeStatusCompletion | null = null
    const revision: number = ++this.revision
    const current = (): boolean => revision === this.revision && isCurrent() &&
      this.admitted(visible, restoringSource)
    const completion = ReaderSystemBarController.operations.then(async (): Promise<void> => {
      if (!current()) return
      const win = await this.getWindow()
      if (win === null || !current()) return
      this.runningRevision = revision
      if (visible || restoringSource) await win.setWindowSystemBarProperties(properties)
      if (!current()) return
      const areaApplicable = this.observeChromeArea(win)
      if (showingChrome && this.visibilityEnabled) {
        statusCompletion = new ReaderChromeStatusCompletion(win, areaApplicable, current)
        this.pendingChromeStatus = statusCompletion
      }
      if (this.visibilityEnabled) await this.writeVisibility(win, visible, restoringSource, current)
      statusCompletion?.nativeComplete()
    }).catch((error: Error): void => {
      statusCompletion?.finish()
      console.warn(`[ReaderSystemBarController] update_failed=${error.message}`)
    })
    // Native writes remain ordered; a pending area must not block a newer hide,
    // cancellation or source restore. submit/cancel retire the old listener.
    ReaderSystemBarController.operations = completion
    const submitted = completion.then(async (): Promise<void> => {
      if (statusCompletion !== null) await statusCompletion.completion
      if (this.pendingChromeStatus === statusCompletion) this.pendingChromeStatus = null
    })
    this.currentSubmission = submitted
    void submitted.then((): void => {
      if (this.currentSubmission === submitted) this.currentSubmission = null
    })
    return submitted
  }
}
