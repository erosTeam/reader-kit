import { ReaderUnit, ReaderPage } from './ReaderContent'
import { ReaderSession, ReaderSnapshot, ReaderCatalog, ReaderAssetProvider, ReaderAsset,
  ReaderAssetKind, ReaderCancellation, ReaderAssetFailureClassifier } from './ReaderSession'

/** Unsupported previews never fall back to decoding a full original. */
class ThumbnailAssets implements ReaderAssetProvider {
  cancellationMode: 'consumer-only' | 'transport'
  private provider: ReaderAssetProvider
  constructor(provider: ReaderAssetProvider) {
    this.provider = provider
    this.cancellationMode = provider.cancellationMode
  }
  async load(page: ReaderPage, kind: ReaderAssetKind, cancellation: ReaderCancellation,
    forceReload: boolean): Promise<ReaderAsset> {
    if (kind !== 'thumbnail' || !page.thumbnail.available) throw new Error('reader_thumbnail_unavailable')
    return this.provider.load(page, kind, cancellation, forceReload)
  }
}

export class ReaderThumbnailFrame {
  index: number
  slotId: number
  asset: ReaderSnapshot
  constructor(index: number, slotId: number, asset: ReaderSnapshot) {
    this.index = index
    this.slotId = slotId
    this.asset = asset.copy()
  }
}

class ThumbnailSlot {
  index: number
  id: number
  session: ReaderSession
  width: number = 0
  height: number = 0
  constructor(index: number, id: number, session: ReaderSession) {
    this.index = index; this.id = id; this.session = session
  }
}

/**
 * Auxiliary visible-range leases over an already prepared unit. No catalog.open,
 * display-map, page selection, original observation or host chapter ownership.
 */
export class ReaderThumbnailWindow {
  private catalog: ReaderCatalog
  private assets: ReaderAssetProvider
  private failures: ReaderAssetFailureClassifier | null
  private unit: ReaderUnit | null = null
  private slots: ThumbnailSlot[] = []
  private serial: number = 0
  private closed: boolean = false
  private listener: ((frames: ReaderThumbnailFrame[]) => void) | null = null

  constructor(catalog: ReaderCatalog, assets: ReaderAssetProvider,
    failures: ReaderAssetFailureClassifier | null = null) {
    this.catalog = catalog; this.assets = new ThumbnailAssets(assets); this.failures = failures
  }

  subscribe(listener: (frames: ReaderThumbnailFrame[]) => void): void {
    this.listener = listener; this.emit()
  }
  snapshot(): ReaderThumbnailFrame[] {
    return this.slots.map((slot: ThumbnailSlot): ReaderThumbnailFrame => {
      const asset = slot.session.snapshot()
      if (asset.page !== null && asset.page.thumbnail.kind !== 'sprite' && slot.width > 0 && slot.height > 0) {
        asset.page.thumbnail.width = slot.width; asset.page.thumbnail.height = slot.height
      }
      return new ReaderThumbnailFrame(slot.index, slot.id, asset)
    })
  }
  private emit(): void { if (this.listener !== null) this.listener(this.snapshot()) }

  setRange(unit: ReaderUnit, start: number, end: number): void {
    if (this.closed || !Number.isSafeInteger(unit.pageCount) || unit.pageCount < 1 ||
      !Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || end >= unit.pageCount) return
    if (this.unit === null || !this.unit.key.equals(unit.key) || this.unit.pageCount !== unit.pageCount) {
      this.release(); this.unit = unit.copy()
    }
    const first = Math.max(0, start - 1)
    const last = Math.min(unit.pageCount - 1, end + 1)
    const retired = this.slots.filter((slot: ThumbnailSlot) => slot.index < first || slot.index > last)
    this.slots = this.slots.filter((slot: ThumbnailSlot) => slot.index >= first && slot.index <= last)
    retired.forEach((slot: ThumbnailSlot): void => { slot.session.close() })
    const added: ThumbnailSlot[] = []
    for (let index = first; index <= last; index++) {
      if (this.slots.some((slot: ThumbnailSlot) => slot.index === index)) continue
      const slot = new ThumbnailSlot(index, ++this.serial, new ReaderSession(this.catalog, this.assets, this.failures))
      this.slots.push(slot); added.push(slot)
    }
    this.slots.sort((a: ThumbnailSlot, b: ThumbnailSlot) => a.index - b.index)
    added.forEach((slot: ThumbnailSlot): void => {
      slot.session.subscribe((): void => {
        if (!this.closed && this.slots.includes(slot)) this.emit()
      })
      void slot.session.openPrepared(unit, slot.index, 'thumbnail')
    })
    this.emit()
  }

  reportPresentation(slotId: number, request: number, success: boolean, width: number = 0, height: number = 0): void {
    const slot = this.slots.find((item: ThumbnailSlot) => item.id === slotId)
    if (this.closed || slot === undefined) return
    const asset = slot.session.snapshot()
    if (asset.assetRequestId !== request || (asset.phase !== 'decoding' && asset.phase !== 'displayed')) return
    if (success) {
      if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
        slot.width = width; slot.height = height
      }
      slot.session.reportPresentation(request, true)
      this.emit()
    } else slot.session.reportRenderFailure(request)
  }

  async retry(slotId: number, request: number): Promise<boolean> {
    const slot = this.slots.find((item: ThumbnailSlot) => item.id === slotId)
    if (this.closed || slot === undefined) return false
    const asset = slot.session.snapshot()
    if (asset.phase !== 'failed' || asset.requestId !== request || asset.page?.thumbnail.available === false) return false
    await slot.session.retry()
    return true
  }

  private release(): void {
    const retired = this.slots; this.slots = []
    retired.forEach((slot: ThumbnailSlot): void => { slot.session.close() })
  }
  close(): void {
    if (this.closed) return
    this.closed = true; this.release(); this.unit = null; this.emit(); this.listener = null
  }
}
