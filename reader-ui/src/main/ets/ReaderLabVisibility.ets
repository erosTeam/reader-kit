import { AppStorageV2 } from '@kit.ArkUI'

/** Host lifecycle signal for reader lab/surface activity gating; updated in every build. */
@ObservedV2
export class ReaderLabVisibilityState {
  @Trace foreground: boolean = false
}

export function connectReaderLabVisibility(): ReaderLabVisibilityState {
  return AppStorageV2.connect(ReaderLabVisibilityState, () => new ReaderLabVisibilityState())!
}

/**
 * Foreground signal for the production reader active gate. The debugBuild parameter
 * is kept for source compatibility and ignored: a release reader must observe real
 * foreground changes or every interaction gate stays closed (2026-09-22 release defect).
 */
export function updateReaderLabForeground(foreground: boolean, _debugBuild: boolean): void {
  connectReaderLabVisibility().foreground = foreground
}
