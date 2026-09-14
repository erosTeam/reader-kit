/** Optional host-owned settings entry presented by reader chrome. */
export class ReaderHostSettings {
  private readonly onRequest: () => void

  constructor(onRequest: () => void) {
    this.onRequest = onRequest
  }

  request(): void {
    this.onRequest()
  }
}
