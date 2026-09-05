/** Source identifiers are opaque to the reader. Never put credentials in scope. */
export class ReaderUnitKey {
  scope: string
  work: string
  unit: string

  constructor(scope: string, work: string, unit: string) {
    this.scope = scope
    this.work = work
    this.unit = unit
  }

  equals(other: ReaderUnitKey): boolean {
    return this.scope === other.scope && this.work === other.work && this.unit === other.unit
  }

  copy(): ReaderUnitKey { return new ReaderUnitKey(this.scope, this.work, this.unit) }
}

export class ReaderUnit {
  key: ReaderUnitKey
  title: string
  pageCount: number

  constructor(key: ReaderUnitKey, title: string, pageCount: number) {
    this.key = key
    this.title = title
    this.pageCount = pageCount
  }

  copy(): ReaderUnit { return new ReaderUnit(this.key.copy(), this.title, this.pageCount) }
}

export class ReaderThumbnail {
  available: boolean = true
  kind: 'image' | 'sprite' | 'derived' = 'image'
  width: number = 0
  height: number = 0
  spriteWidth: number = 0
  spriteHeight: number = 0
  offsetX: number = 0
  offsetY: number = 0

  copy(): ReaderThumbnail {
    const value = new ReaderThumbnail()
    value.available = this.available
    value.kind = this.kind
    value.width = this.width
    value.height = this.height
    value.spriteWidth = this.spriteWidth
    value.spriteHeight = this.spriteHeight
    value.offsetX = this.offsetX
    value.offsetY = this.offsetY
    return value
  }
}

export class ReaderPage {
  unit: ReaderUnitKey
  key: string
  sourceIndex: number
  width: number = 0
  height: number = 0
  thumbnail: ReaderThumbnail = new ReaderThumbnail()

  constructor(unit: ReaderUnitKey, key: string, sourceIndex: number) {
    this.unit = unit
    this.key = key
    this.sourceIndex = sourceIndex
  }

  copy(): ReaderPage {
    const value = new ReaderPage(this.unit.copy(), this.key, this.sourceIndex)
    value.width = this.width
    value.height = this.height
    value.thumbnail = this.thumbnail.copy()
    return value
  }
}

export type ReaderAssetKind = 'original' | 'thumbnail'
export type ReaderPhase = 'idle' | 'catalog' | 'asset' | 'decoding' | 'displayed' | 'failed' | 'closed'

/** A consumer cancellation fence; adapters must separately declare transport support. */
export class ReaderCancellation {
  private cancelled: boolean = false

  cancel(): void { this.cancelled = true }
  isCancelled(): boolean { return this.cancelled }
  check(): void {
    if (this.cancelled) throw new Error('reader_request_cancelled')
  }
}

/** File/URI ownership belongs to the provider. Releasing a reader never deletes a download. */
export class ReaderAsset {
  uri: string
  private released: boolean = false
  private releaseResource: () => void

  constructor(uri: string, releaseResource: () => void = () => {}) {
    this.uri = uri
    this.releaseResource = releaseResource
  }

  release(): void {
    if (this.released) return
    this.released = true
    this.releaseResource()
  }
}

export interface ReaderCatalog {
  open(key: ReaderUnitKey, cancellation: ReaderCancellation): Promise<ReaderUnit>
  page(unit: ReaderUnit, index: number, cancellation: ReaderCancellation): Promise<ReaderPage>
  adjacent(unit: ReaderUnit, direction: 'next' | 'previous'): ReaderUnitKey | null
}

export interface ReaderAssetProvider {
  /** D1 exposes existing service limits instead of claiming detached requests were aborted. */
  cancellationMode: 'consumer-only' | 'transport'
  load(page: ReaderPage, kind: ReaderAssetKind, cancellation: ReaderCancellation, forceReload: boolean): Promise<ReaderAsset>
}

export class ReaderSnapshot {
  phase: ReaderPhase = 'idle'
  unit: ReaderUnit | null = null
  page: ReaderPage | null = null
  sourceIndex: number = 0
  kind: ReaderAssetKind = 'original'
  uri: string = ''
  requestId: number = 0
  error: string = ''
  canPreviousUnit: boolean = false
  canNextUnit: boolean = false

  copy(): ReaderSnapshot {
    const value = new ReaderSnapshot()
    value.phase = this.phase
    value.unit = this.unit === null ? null : this.unit.copy()
    value.page = this.page === null ? null : this.page.copy()
    value.sourceIndex = this.sourceIndex
    value.kind = this.kind
    value.uri = this.uri
    value.requestId = this.requestId
    value.error = this.error
    value.canPreviousUnit = this.canPreviousUnit
    value.canNextUnit = this.canNextUnit
    return value
  }
}

/**
 * D1 read-only session: deliberately has no settings/progress/tracker persistence port.
 * Commands select content; only a matching native-image callback marks it displayed.
 */
export class ReaderSession {
  private readonly catalog: ReaderCatalog
  private readonly assets: ReaderAssetProvider
  private state: ReaderSnapshot = new ReaderSnapshot()
  private listener: ((snapshot: ReaderSnapshot) => void) | null = null
  private cancellation: ReaderCancellation = new ReaderCancellation()
  private asset: ReaderAsset | null = null
  private epoch: number = 0
  private disposed: boolean = false
  private pendingUnit: ReaderUnitKey | null = null
  private pendingIndex: number = 0

  constructor(catalog: ReaderCatalog, assets: ReaderAssetProvider) {
    this.catalog = catalog
    this.assets = assets
  }

  subscribe(listener: (snapshot: ReaderSnapshot) => void): void {
    this.listener = listener
    listener(this.state.copy())
  }

  snapshot(): ReaderSnapshot { return this.state.copy() }
  cancellationMode(): string { return this.assets.cancellationMode }

  private emit(): void {
    if (this.listener !== null) this.listener(this.state.copy())
  }

  private begin(): number {
    this.cancellation.cancel()
    this.cancellation = new ReaderCancellation()
    this.epoch += 1
    this.state.requestId = this.epoch
    this.state.error = ''
    return this.epoch
  }

  private current(epoch: number): boolean {
    return !this.disposed && epoch === this.epoch
  }

  async open(key: ReaderUnitKey, index: number = 0): Promise<void> {
    if (this.disposed) return
    const epoch = this.begin()
    const cancellation = this.cancellation
    const requestedKey = key.copy()
    this.pendingUnit = requestedKey
    this.pendingIndex = index
    this.state.phase = 'catalog'
    this.emit()
    try {
      const unit = (await this.catalog.open(requestedKey.copy(), cancellation)).copy()
      if (!this.current(epoch)) return
      if (!unit.key.equals(requestedKey) || !Number.isInteger(unit.pageCount) || unit.pageCount < 1) {
        throw new Error('reader_catalog_unavailable')
      }
      this.state.unit = unit
      this.pendingUnit = null
      this.state.canPreviousUnit = this.catalog.adjacent(unit, 'previous') !== null
      this.state.canNextUnit = this.catalog.adjacent(unit, 'next') !== null
      await this.load(unit, this.boundedIndex(index, unit), 'original', epoch, cancellation)
    } catch (_error) {
      this.fail(epoch, 'reader_catalog_failed')
    }
  }

  async show(index: number, kind: ReaderAssetKind = 'original', forceReload: boolean = false): Promise<void> {
    if (this.disposed || this.state.unit === null) return
    const unit = this.state.unit
    this.pendingUnit = null
    const epoch = this.begin()
    await this.load(unit, this.boundedIndex(index, unit), kind, epoch, this.cancellation, forceReload)
  }

  async switchUnit(direction: 'next' | 'previous'): Promise<void> {
    if (this.disposed || this.state.unit === null) return
    const target = this.catalog.adjacent(this.state.unit, direction)
    if (target !== null) await this.open(target)
  }

  async retry(): Promise<void> {
    if (this.pendingUnit !== null) {
      await this.open(this.pendingUnit, this.pendingIndex)
    } else {
      await this.show(this.state.sourceIndex, this.state.kind, true)
    }
  }

  private boundedIndex(index: number, unit: ReaderUnit): number {
    const safe = Number.isFinite(index) ? Math.floor(index) : 0
    return Math.max(0, Math.min(unit.pageCount - 1, safe))
  }

  private async load(
    unit: ReaderUnit, index: number, kind: ReaderAssetKind,
    epoch: number, cancellation: ReaderCancellation, forceReload: boolean = false,
  ): Promise<void> {
    this.state.phase = 'asset'
    this.state.sourceIndex = index
    this.state.kind = kind
    this.state.page = null
    this.state.uri = ''
    this.releaseAsset()
    this.emit()
    try {
      const page = (await this.catalog.page(unit.copy(), index, cancellation)).copy()
      if (!this.current(epoch)) return
      if (!page.unit.equals(unit.key) || page.sourceIndex !== index || page.key.length === 0) {
        throw new Error('reader_page_identity_mismatch')
      }
      this.state.page = page
      this.emit()
      const asset = await this.assets.load(page.copy(), kind, cancellation, forceReload)
      if (!this.current(epoch)) {
        asset.release()
        return
      }
      if (asset.uri.length === 0) {
        asset.release()
        throw new Error('reader_empty_asset')
      }
      this.asset = asset
      this.state.uri = asset.uri
      this.state.phase = 'decoding'
      this.emit()
    } catch (_error) {
      this.fail(epoch, 'reader_asset_failed')
    }
  }

  reportPresentation(requestId: number, success: boolean): void {
    if (!this.current(requestId) || this.state.phase !== 'decoding') return
    this.state.phase = success ? 'displayed' : 'failed'
    this.state.error = success ? '' : 'reader_decode_failed'
    this.emit()
  }

  private fail(epoch: number, code: string): void {
    if (!this.current(epoch)) return
    this.state.phase = 'failed'
    this.state.error = code
    this.emit()
  }

  private releaseAsset(): void {
    if (this.asset !== null) this.asset.release()
    this.asset = null
  }

  close(): void {
    if (this.disposed) return
    this.disposed = true
    this.cancellation.cancel()
    this.epoch += 1
    this.releaseAsset()
    this.state.phase = 'closed'
    this.state.uri = ''
    this.emit()
    this.listener = null
  }
}
