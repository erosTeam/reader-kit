/**
 * Host capability and localized feedback for the current-unit enhancement
 * control. reader-kit owns the route-local override; hosts retain all model,
 * service, cache and preference ownership.
 */
export class ReaderTemporaryVariantControl {
  readonly available: boolean
  private readonly onChanged: ((enabled: boolean) => void) | null

  constructor(available: boolean = false, onChanged: ((enabled: boolean) => void) | null = null) {
    this.available = available
    this.onChanged = onChanged
  }

  changed(enabled: boolean): void {
    this.onChanged?.(enabled)
  }
}
