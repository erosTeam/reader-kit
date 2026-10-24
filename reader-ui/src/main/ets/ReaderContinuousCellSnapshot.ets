import { ReaderPagedSnapshot, ReaderPagedFrame, ReaderPage, ReaderUnit } from '@reader-kit/core'

/** Render-only cell input. Selection, observations and resource leases stay in Core. */
export class ReaderContinuousCellSnapshot {
  readonly displayIndex: number
  readonly navigationRevision: number
  readonly topologyRevision: number
  readonly frames: ReaderPagedFrame[]

  constructor(snapshot: ReaderPagedSnapshot, key: string, frames: ReaderPagedFrame[]) {
    this.displayIndex = snapshot.displayKeys.indexOf(key)
    this.navigationRevision = snapshot.navigationRevision
    this.topologyRevision = snapshot.topologyRevision
    this.frames = frames
  }
}

function sameUnit(left: ReaderUnit | null, right: ReaderUnit | null): boolean {
  if (left === null || right === null) return left === right
  return left.key.equals(right.key) && left.title === right.title && left.pageCount === right.pageCount
}

function samePage(left: ReaderPage | null, right: ReaderPage | null): boolean {
  if (left === null || right === null) return left === right
  const a = left.thumbnail
  const b = right.thumbnail
  return left.unit.equals(right.unit) && left.key === right.key && left.sourceIndex === right.sourceIndex &&
    left.width === right.width && left.height === right.height && left.previewWidth === right.previewWidth &&
    left.previewHeight === right.previewHeight && left.previewCoversWholePage === right.previewCoversWholePage &&
    left.bodySourceReady === right.bodySourceReady && left.bodySourceFailed === right.bodySourceFailed &&
    a.available === b.available && a.kind === b.kind && a.width === b.width && a.height === b.height &&
    a.spriteWidth === b.spriteWidth && a.spriteHeight === b.spriteHeight && a.offsetX === b.offsetX && a.offsetY === b.offsetY
}

function settledOriginal(frame: ReaderPagedFrame): boolean {
  const asset = frame.asset
  return !frame.cropPending && asset.phase === 'displayed' && asset.kind === 'original' &&
    asset.assetRequestId > 0 && asset.requestId === asset.assetRequestId && asset.retainedUri.length === 0 &&
    asset.retainedAssetRequestId === 0 && asset.failure === null && asset.notice === null && asset.error.length === 0
}

function sameSettledOriginal(left: ReaderPagedFrame, right: ReaderPagedFrame): boolean {
  if (!settledOriginal(left) || !settledOriginal(right)) return false
  const a = left.asset
  const b = right.asset
  return left.slotId === right.slotId && left.part.unit.equals(right.part.unit) &&
    left.part.pageKey === right.part.pageKey && left.part.sourceIndex === right.part.sourceIndex &&
    left.part.fragment === right.part.fragment && left.crop.left === right.crop.left &&
    left.crop.top === right.crop.top && left.crop.right === right.crop.right && left.crop.bottom === right.crop.bottom &&
    a.sourceIndex === b.sourceIndex && a.requestId === b.requestId && a.assetRequestId === b.assetRequestId &&
    a.uri === b.uri && a.saveUri === b.saveUri && a.variant === b.variant && a.variantIdentity === b.variantIdentity &&
    a.visualRevision === b.visualRevision && a.originalAvailable === b.originalAvailable &&
    a.informationAvailable === b.informationAvailable && a.loadProgressLoaded === b.loadProgressLoaded &&
    a.loadProgressTotal === b.loadProgressTotal && a.canPreviousUnit === b.canPreviousUnit &&
    a.canNextUnit === b.canNextUnit && sameUnit(a.unit, b.unit) && samePage(a.page, b.page)
}

/** Keep unchanged decoded cells independent of another page's selection/progress. */
export class ReaderContinuousCellSnapshots {
  private snapshot: ReaderPagedSnapshot | null = null
  private values: Map<string, ReaderContinuousCellSnapshot> = new Map()

  forItem(snapshot: ReaderPagedSnapshot, key: string, allowReuse: boolean = true): ReaderContinuousCellSnapshot {
    if (this.snapshot !== snapshot) {
      // No retained asset demand: drop projections when Core drops their window.
      this.values.forEach((_value: ReaderContinuousCellSnapshot, key: string): void => {
        if (!snapshot.window.some((item): boolean => item.key === key)) this.values.delete(key)
      })
      this.snapshot = snapshot
    }
    const frames = snapshot.window.find((item): boolean => item.key === key)?.frames ?? []
    const previous = this.values.get(key)
    if (allowReuse && previous !== undefined && previous.topologyRevision === snapshot.topologyRevision &&
      previous.navigationRevision === snapshot.navigationRevision && previous.displayIndex === snapshot.displayKeys.indexOf(key) &&
      ((previous.frames.length === 0 && frames.length === 0) ||
      (previous.frames.length === 1 && frames.length === 1 && sameSettledOriginal(previous.frames[0], frames[0])))) return previous
    // Pending entry/loading/replacement/failure inputs always keep their current
    // snapshot. Reuse cannot retire feedback or revive an earlier request.
    const value = new ReaderContinuousCellSnapshot(snapshot, key, frames)
    this.values.set(key, value)
    return value
  }
}
