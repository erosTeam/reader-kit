/** Passive host notifications about reader UI activity. */
export class ReaderActivitySink {
  private readonly onChromeVisible: ((visible: boolean) => void) | null
  private readonly onInteractionBusy: ((busy: boolean) => void) | null

  constructor(onChromeVisible: ((visible: boolean) => void) | null = null,
    onInteractionBusy: ((busy: boolean) => void) | null = null) {
    this.onChromeVisible = onChromeVisible
    this.onInteractionBusy = onInteractionBusy
  }

  chromeChanged(visible: boolean): void {
    this.onChromeVisible?.(visible)
  }

  interactionBusyChanged(busy: boolean): void {
    this.onInteractionBusy?.(busy)
  }
}
