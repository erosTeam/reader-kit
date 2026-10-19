import { ReaderUnit, ReaderPage } from './ReaderContent'
import { ReaderAsset, ReaderAssetProvider, ReaderCancellation, ReaderCatalog, ReaderPreloadHost,
  ReaderVariantPreference, ReaderVariantAssetPlan, ReaderProcessedAssetVariant } from './ReaderSession'
import { ReaderImageCropBounds, ReaderImageCropSource } from './ReaderImageCrop'

export type ReaderProcessingPriority = 'current' | 'prefetch'
export type ReaderProcessingPhase = 'preparing' | 'ready' | 'unavailable'
export type ReaderProcessingResult = 'changed' | 'unchanged' | 'unavailable' | 'stale'

/** A task's priority can advance without cancelling or duplicating its processing request. */
export class ReaderProcessingCancellation extends ReaderCancellation {
  priority: ReaderProcessingPriority
  private promotions: Array<() => void> = []
  constructor(priority: ReaderProcessingPriority) { super(); this.priority = priority }
  promote(): void {
    if (this.priority === 'current' || this.isCancelled()) return
    this.priority = 'current'
    this.promotions.forEach((listener: () => void): void => listener())
  }
  onPromotion(listener: () => void): () => void {
    if (this.priority === 'current') listener()
    this.promotions.push(listener)
    return (): void => {
      const index = this.promotions.indexOf(listener)
      if (index >= 0) this.promotions.splice(index, 1)
    }
  }
}

/** Configuration and user choices only. Demand, cancellation and adoption are session-owned. */
export class ReaderProcessingPolicy {
  readonly revision: string
  readonly automaticNext: boolean
  private resolve: (page: ReaderPage, automatic: boolean) => ReaderVariantPreference
  private complete: (sourceIndex: number, preference: ReaderVariantPreference, result: ReaderProcessingResult) => void
  constructor(revision: string, automaticNext: boolean,
    resolve: (page: ReaderPage, automatic: boolean) => ReaderVariantPreference,
    complete: (sourceIndex: number, preference: ReaderVariantPreference, result: ReaderProcessingResult) => void =
      (): void => {}) {
    this.revision = revision
    this.automaticNext = automaticNext
    this.resolve = resolve
    this.complete = complete
  }
  preference(page: ReaderPage, automatic: boolean): ReaderVariantPreference {
    const value = this.resolve(page.copy(), automatic)
    return new ReaderVariantPreference(value.variant, value.identity)
  }
  completed(index: number, preference: ReaderVariantPreference, result: ReaderProcessingResult): void {
    this.complete(index, new ReaderVariantPreference(preference.variant, preference.identity), result)
  }
}

export class ReaderProcessingState {
  sourceIndex: number
  preference: ReaderVariantPreference
  phase: ReaderProcessingPhase
  constructor(index: number, preference: ReaderVariantPreference, phase: ReaderProcessingPhase) {
    this.sourceIndex = index
    this.preference = new ReaderVariantPreference(preference.variant, preference.identity)
    this.phase = phase
  }
}

class ReaderPreparedCrop implements ReaderImageCropSource {
  private bounds: ReaderImageCropBounds
  constructor(bounds: ReaderImageCropBounds) { this.bounds = bounds.copy() }
  async read(): Promise<ReaderImageCropBounds> { return this.bounds.copy() }
}

/** One retained file, independent leases for its prepared recipe and each native image slot. */
class ReaderPreparedVariantPlan implements ReaderVariantAssetPlan {
  page: ReaderPage
  variant: ReaderProcessedAssetVariant
  identity: string
  private asset: ReaderAsset
  private references: number = 1
  private retired: boolean = false
  constructor(plan: ReaderVariantAssetPlan, asset: ReaderAsset) {
    this.page = plan.page.copy(); this.variant = plan.variant; this.identity = plan.identity; this.asset = asset
  }
  async load(cancellation: ReaderCancellation, _forceReload: boolean): Promise<ReaderAsset> {
    cancellation.check()
    if (this.retired) throw new Error('reader_prepared_variant_retired')
    this.references += 1
    const lease = new ReaderAsset(this.asset.uri, (): void => this.releaseReference(), this.asset.information,
      (): void => this.asset.present())
    lease.saveUri = this.asset.saveUri
    lease.crop = this.asset.crop
    lease.originalAvailable = this.asset.originalAvailable
    return lease
  }
  release(): void {
    if (this.retired) return
    this.retired = true
    this.releaseReference()
  }
  private releaseReference(): void {
    this.references -= 1
    if (this.references === 0) this.asset.release()
  }
}

class ReaderProcessingEntry {
  index: number
  page: ReaderPage | null = null
  preference: ReaderVariantPreference = new ReaderVariantPreference()
  signature: string = ''
  phase: ReaderProcessingPhase = 'preparing'
  cancellation: ReaderProcessingCancellation
  plan: ReaderPreparedVariantPlan | null = null
  constructor(index: number, priority: ReaderProcessingPriority) {
    this.index = index; this.cancellation = new ReaderProcessingCancellation(priority)
  }
  release(): void { this.cancellation.cancel(); this.plan?.release(); this.plan = null }
}

/**
 * Bounded preparation ownership for one reading unit. This never mounts a future
 * image or advances progress. Identical future/current demands share one task;
 * obsolete configuration and out-of-window consumers lose only their own leases.
 */
export class ReaderProcessingCoordinator {
  private catalog: ReaderCatalog
  private assets: ReaderAssetProvider
  private preload: ReaderPreloadHost | null
  private changed: () => void
  private entries: Map<number, ReaderProcessingEntry> = new Map()
  private unit: ReaderUnit | null = null
  private policy: ReaderProcessingPolicy | null = null
  private indexes: number[] = []
  private current: number[] = []
  private automaticIndex: number = -1
  private cropEnabled: boolean = false
  private cropRevision: string = ''
  private active: boolean = false
  constructor(catalog: ReaderCatalog, assets: ReaderAssetProvider, preload: ReaderPreloadHost | null,
    changed: () => void) {
    this.catalog = catalog; this.assets = assets; this.preload = preload; this.changed = changed
  }
  update(unit: ReaderUnit, indexes: number[], current: number[], automaticIndex: number,
    policy: ReaderProcessingPolicy, active: boolean, cropEnabled: boolean, cropRevision: string): void {
    if (this.unit !== null && !this.unit.key.equals(unit.key)) this.clear()
    this.unit = unit.copy(); this.policy = policy; this.indexes = indexes.slice(); this.current = current.slice()
    this.automaticIndex = policy.automaticNext ? automaticIndex : -1
    this.cropEnabled = cropEnabled; this.cropRevision = cropRevision; this.active = active
    this.entries.forEach((entry: ReaderProcessingEntry, index: number): void => {
      if (!indexes.includes(index) || (!active && entry.phase === 'preparing')) {
        this.entries.delete(index); entry.release()
      }
    })
    if (!active) return
    const ordered = current.filter((index: number): boolean => indexes.includes(index))
      .concat(indexes.filter((index: number): boolean => !current.includes(index)))
    ordered.forEach((index: number): void => {
      const priority: ReaderProcessingPriority = current.includes(index) ? 'current' : 'prefetch'
      const existing = this.entries.get(index)
      if (existing !== undefined) {
        if (priority === 'current') existing.cancellation.promote()
        if (existing.page === null) return
        const preference = this.preference(existing.page)
        if (existing.signature === this.signature(existing.page, preference)) return
        this.entries.delete(index); existing.release()
      }
      const entry = new ReaderProcessingEntry(index, priority)
      this.entries.set(index, entry)
      void this.prepare(entry, unit.copy())
    })
  }
  plan(index: number): ReaderVariantAssetPlan | null { return this.entries.get(index)?.plan ?? null }
  states(): ReaderProcessingState[] {
    const result: ReaderProcessingState[] = []
    this.entries.forEach((entry: ReaderProcessingEntry): void => {
      if (entry.preference.variant !== 'default') result.push(new ReaderProcessingState(entry.index,
        entry.preference, entry.phase))
    })
    return result
  }
  invalidate(index: number): void {
    const entry = this.entries.get(index)
    this.entries.delete(index); entry?.release()
  }
  clear(): void {
    this.entries.forEach((entry: ReaderProcessingEntry): void => entry.release())
    this.entries.clear(); this.unit = null
  }
  private currentEntry(entry: ReaderProcessingEntry, unit: ReaderUnit): boolean {
    return this.active && !entry.cancellation.isCancelled() && this.entries.get(entry.index) === entry &&
      this.unit?.key.equals(unit.key) === true && this.indexes.includes(entry.index)
  }
  private preference(page: ReaderPage): ReaderVariantPreference {
    return this.policy?.preference(page, this.current.includes(page.sourceIndex) ||
      page.sourceIndex === this.automaticIndex) ?? new ReaderVariantPreference()
  }
  private signature(page: ReaderPage, preference: ReaderVariantPreference): string {
    return JSON.stringify([page.unit.scope, page.unit.work, page.unit.unit, page.key, page.sourceIndex,
      preference.variant, preference.identity, this.cropEnabled, this.cropRevision])
  }
  private async prepare(entry: ReaderProcessingEntry, unit: ReaderUnit): Promise<void> {
    let asset: ReaderAsset | null = null
    let recipe: ReaderVariantAssetPlan | null = null
    try {
      const page = await this.catalog.page(unit.copy(), entry.index, entry.cancellation)
      if (!this.currentEntry(entry, unit) || !page.unit.equals(unit.key) || page.sourceIndex !== entry.index) return
      entry.page = page.copy(); entry.preference = this.preference(page)
      entry.signature = this.signature(page, entry.preference)
      if (entry.preference.variant === 'default') {
        if (!this.current.includes(entry.index)) await this.preload?.preload(page.copy(), entry.cancellation)
        entry.phase = 'ready'
        return
      }
      this.changed()
      if (entry.preference.identity.length === 0 || this.assets.prepareVariant === undefined) {
        throw new Error('reader_processing_unavailable')
      }
      recipe = await this.assets.prepareVariant(page.copy(), entry.preference.variant,
        entry.preference.identity, entry.cancellation)
      entry.cancellation.check()
      if (!recipe.page.unit.equals(page.unit) || recipe.page.key !== page.key ||
        recipe.page.sourceIndex !== page.sourceIndex || recipe.variant !== entry.preference.variant ||
        recipe.identity !== entry.preference.identity) throw new Error('reader_processing_identity_mismatch')
      asset = await recipe.load(entry.cancellation, false)
      entry.cancellation.check()
      if (asset.uri.length === 0 || asset.notice !== null) throw new Error('reader_processing_asset_unavailable')
      if (asset.information !== null) {
        const information = await asset.information.read()
        entry.cancellation.check()
        if (recipe.page.width <= 0) recipe.page.width = information.width
        if (recipe.page.height <= 0) recipe.page.height = information.height
      }
      if (this.cropEnabled && asset.crop !== null) {
        const bounds = await asset.crop.read()
        entry.cancellation.check()
        asset.crop = new ReaderPreparedCrop(bounds)
      }
      if (!this.currentEntry(entry, unit) || entry.signature !== this.signature(page, this.preference(page))) return
      entry.plan = new ReaderPreparedVariantPlan(recipe, asset)
      asset = null; recipe = null; entry.phase = 'ready'
      console.info(`[ReaderProcessing] ready source=${entry.index} variant=${entry.preference.variant}`)
      this.changed()
      this.policy?.completed(entry.index, entry.preference, 'changed')
    } catch (_error) {
      if (this.currentEntry(entry, unit)) {
        entry.phase = 'unavailable'
        this.changed()
        this.policy?.completed(entry.index, entry.preference, 'unavailable')
      }
    } finally {
      asset?.release()
      if (recipe !== null) recipe.release?.()
    }
  }
}
