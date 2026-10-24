import { window } from '@kit.ArkUI'

export type ReaderSystemBarWriter = (win: window.Window, visible: boolean,
  restoringSource: boolean, isCurrent: () => boolean) => Promise<void>

/** One chrome policy and one ordered color/visibility operation for every host.
 * Surface awaits this finite operation before revealing chrome. No window,
 * unsupported control or failure must settle without waiting for a status inset.
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
    return this.requestVisible(chromeVisible || !fullscreen, chromeVisible || canvasDark, isCurrent)
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
    restoringSource: boolean = false): Promise<void> {
    if (!isCurrent()) return Promise.resolve()
    this.visible = visible
    this.properties = properties
    this.current = isCurrent
    return this.submit(visible, properties, isCurrent, restoringSource)
  }

  replay(): Promise<void> {
    return this.submit(this.visible, this.properties, this.current, false)
  }

  /** Closing retires queued shows before the lease restores its saved window. */
  cancel(): Promise<void> {
    this.revision += 1
    return ReaderSystemBarController.operations
  }

  private submit(visible: boolean, properties: window.SystemBarProperties, isCurrent: () => boolean,
    restoringSource: boolean): Promise<void> {
    const revision: number = ++this.revision
    const current = (): boolean => revision === this.revision && isCurrent() &&
      this.admitted(visible, restoringSource)
    const completion = ReaderSystemBarController.operations.then(async (): Promise<void> => {
      if (!current()) return
      const win = await this.getWindow()
      if (win === null || !current()) return
      if (visible || restoringSource) await win.setWindowSystemBarProperties(properties)
      if (!current()) return
      if (this.visibilityEnabled) await this.writeVisibility(win, visible, restoringSource, current)
    }).catch((error: Error): void => {
      console.warn(`[ReaderSystemBarController] update_failed=${error.message}`)
    })
    ReaderSystemBarController.operations = completion
    return completion
  }
}
