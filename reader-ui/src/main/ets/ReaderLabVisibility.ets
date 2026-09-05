import { AppStorageV2 } from '@kit.ArkUI'

/** Debug-lab host lifecycle signal; no window operations or persistent switch. */
@ObservedV2
export class ReaderLabVisibilityState {
  @Trace foreground: boolean = false
}

export function connectReaderLabVisibility(): ReaderLabVisibilityState {
  return AppStorageV2.connect(ReaderLabVisibilityState, () => new ReaderLabVisibilityState())!
}

export function updateReaderLabForeground(foreground: boolean, debugBuild: boolean): void {
  if (debugBuild) connectReaderLabVisibility().foreground = foreground
}
