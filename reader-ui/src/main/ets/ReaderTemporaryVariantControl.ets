/** Host capability and localized feedback for the current-unit enhancement control. */
export class ReaderTemporaryVariantControl {
  readonly available: boolean
  private readonly onChanged: ((enabled: boolean) => void) | null
  readonly sessionEnabled: boolean | null
  readonly onToggleSession: (() => void) | null
  constructor(available: boolean = false, onChanged: ((enabled: boolean) => void) | null = null,
    sessionEnabled: boolean | null = null, onToggleSession: (() => void) | null = null) {
    this.available = available
    this.onChanged = onChanged
    this.sessionEnabled = sessionEnabled
    this.onToggleSession = onToggleSession
  }
  changed(enabled: boolean): void { this.onChanged?.(enabled) }
}
