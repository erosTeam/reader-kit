import { common, Configuration, ConfigurationConstant } from '@kit.AbilityKit'
import { window } from '@kit.ArkUI'
import { deviceInfo } from '@kit.BasicServicesKit'

// The host Ability binds its main window. Configuration is the source policy,
// not a snapshot of an avoid area or an app-set fullscreen flag.
let sourceWindow: window.Window | null = null
let sourceDirection: number = ConfigurationConstant.Direction.DIRECTION_NOT_SET
let sourceOwnsWindow: boolean = true
let readerOverrideApplied: boolean = false
let statusWriteRevision: number = 0
let statusWriteTail: Promise<void> = Promise.resolve()

export function bindReaderSourceWindow(context: common.UIAbilityContext, win: window.Window): void {
  sourceWindow = win
  sourceOwnsWindow = true
  readerOverrideApplied = false
  statusWriteRevision += 1
  try { sourceDirection = context.resourceManager.getConfigurationSync().direction } catch (_error) {
    sourceDirection = ConfigurationConstant.Direction.DIRECTION_NOT_SET
  }
}

export function unbindReaderSourceWindow(): void {
  sourceWindow = null
  readerOverrideApplied = false
  statusWriteRevision += 1
}

/** Preserve the phone's native portrait/landscape source policy. Other form
 * factors retain the hosts' existing restore-visible policy. */
export function readerSourceStatusBarVisible(): boolean {
  return deviceInfo.deviceType !== 'phone' ||
    sourceDirection !== ConfigurationConstant.Direction.DIRECTION_HORIZONTAL
}

// A native setter receipt is not a source-layout receipt. Only the new hidden
// source policy needs this zero-area boundary; existing visible/body gates stay.
function waitForHiddenSourceArea(win: window.Window, isCurrent: () => boolean): Promise<void> {
  return new Promise<void>((resolve: () => void, reject: (error: Error) => void): void => {
    let settled: boolean = false
    let timer: number = -1
    const finish = (error: Error | null = null): void => {
      if (settled) return
      settled = true
      if (timer >= 0) clearTimeout(timer)
      try { win.off('avoidAreaChange', changed) } catch (_error) {}
      if (error === null) resolve()
      else reject(error)
    }
    const check = (): void => {
      if (!isCurrent()) { finish(); return }
      try {
        if (win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect.height <= 0) finish()
      } catch (error) { finish(error as Error) }
    }
    const changed = (data: window.AvoidAreaOptions): void => {
      if (data.type === window.AvoidAreaType.TYPE_SYSTEM) check()
    }
    check()
    if (settled) return
    try { win.on('avoidAreaChange', changed) } catch (error) { finish(error as Error); return }
    // Failure bound only; a timeout must never imply source layout readiness.
    timer = setTimeout((): void => finish(isCurrent() ? new Error('source_hidden_area_timeout') : null), 2000)
    check()
  })
}

/** One native visibility queue includes source direction events. Host queues
 * continue to own colors, admission and close-layout ordering. */
export function writeReaderSystemBarVisibility(win: window.Window, visible: boolean,
  readerOwnsWindow: boolean, isCurrent: () => boolean = (): boolean => true): Promise<void> {
  if (!isCurrent()) return Promise.resolve()
  sourceOwnsWindow = !readerOwnsWindow
  readerOverrideApplied = true
  const revision: number = ++statusWriteRevision
  const completion: Promise<void> = statusWriteTail.then(async (): Promise<void> => {
    if (revision !== statusWriteRevision || !isCurrent()) return
    await win.setSpecificSystemBarEnabled('status', visible, false)
  })
  statusWriteTail = completion.catch((): void => {})
  return completion.then((): Promise<void> => {
    const current = (): boolean => revision === statusWriteRevision && isCurrent()
    // Readiness must not hold the native write queue against a newer intent.
    return !readerOwnsWindow && !visible && current()
      ? waitForHiddenSourceArea(win, current) : Promise.resolve()
  })
}

/** UIAbility.onConfigurationUpdate supplies direction; ApplicationContext's
 * environment callback does not. Until Reader overrides visibility, leave the
 * native source untouched. While Reader owns it, retain its chrome/fullscreen. */
export function updateReaderSourceConfiguration(config: Configuration): void {
  if (config.direction === undefined || config.direction === ConfigurationConstant.Direction.DIRECTION_NOT_SET) return
  if (sourceDirection === config.direction) return
  sourceDirection = config.direction
  if (!readerOverrideApplied || !sourceOwnsWindow || sourceWindow === null) return
  const win = sourceWindow
  const direction: number = sourceDirection
  const visible: boolean = readerSourceStatusBarVisible()
  writeReaderSystemBarVisibility(win, visible, false, (): boolean => sourceOwnsWindow &&
    sourceWindow === win && sourceDirection === direction).catch((error: Error): void => {
    console.warn(`[ReaderSourceWindow] configuration_status_failed=${error.message}`)
  })
}
