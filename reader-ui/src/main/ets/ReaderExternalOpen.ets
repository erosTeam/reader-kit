import { ReaderUnitKey } from '@reader-kit/core'

/** Optional host-owned action for opening the current unit outside the app. */
export class ReaderExternalOpen {
  private readonly onRequest: (source: ReaderUnitKey) => void

  constructor(onRequest: (source: ReaderUnitKey) => void) {
    this.onRequest = onRequest
  }

  request(source: ReaderUnitKey): void {
    this.onRequest(source.copy())
  }
}
