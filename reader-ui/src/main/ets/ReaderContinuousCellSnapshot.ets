import { ReaderPagedSnapshot, ReaderPagedFrame, ReaderPage, ReaderUnit, ReaderImagePixelSize } from '@reader-kit/core'

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
  return plainOriginal(frame) && asset.phase === 'displayed' &&
    asset.assetRequestId > 0 && asset.requestId === asset.assetRequestId
}

function plainOriginal(frame: ReaderPagedFrame): boolean {
  const asset = frame.asset
  return !frame.cropPending && asset.kind === 'original' && asset.retainedUri.length === 0 &&
    asset.retainedAssetRequestId === 0 && asset.failure === null && asset.notice === null && asset.error.length === 0
}

function loadingOriginal(frame: ReaderPagedFrame): boolean {
  const asset = frame.asset
  return plainOriginal(frame) && (asset.phase === 'asset' || asset.phase === 'decoding') && asset.presentedAnchor === null
}

function samePixelSize(left: ReaderImagePixelSize | null, right: ReaderImagePixelSize | null): boolean {
  if (left === null || right === null) return left === right
  return left.width === right.width && left.height === right.height
}

export function sameSettledOriginal(left: ReaderPagedFrame, right: ReaderPagedFrame): boolean {
  return settledOriginal(left) && settledOriginal(right) && sameOriginalInputs(left, right)
}

function sameContinuousOriginal(left: ReaderPagedFrame, right: ReaderPagedFrame): boolean {
  return sameSettledOriginal(left, right) ||
    (loadingOriginal(left) && loadingOriginal(right) && sameOriginalInputs(left, right))
}

function sameOriginalInputs(left: ReaderPagedFrame, right: ReaderPagedFrame): boolean {
  const a = left.asset
  const b = right.asset
  return left.slotId === right.slotId && left.part.unit.equals(right.part.unit) &&
    left.part.pageKey === right.part.pageKey && left.part.sourceIndex === right.part.sourceIndex &&
    left.part.fragment === right.part.fragment && left.crop.left === right.crop.left &&
    left.crop.top === right.crop.top && left.crop.right === right.crop.right && left.crop.bottom === right.crop.bottom &&
    a.phase === b.phase && a.sourceIndex === b.sourceIndex &&
    a.requestId === b.requestId && a.assetRequestId === b.assetRequestId && a.presentedRequestId === b.presentedRequestId &&
    samePixelSize(a.pixelSize, b.pixelSize) &&
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
      (previous.frames.length === 1 && frames.length === 1 && sameContinuousOriginal(previous.frames[0], frames[0])))) return previous
    // Keep an unchanged loading row independent of downloads in other rows.
    // A changed epoch, byte count, geometry or decoded asset gets a new input.
    // Entry handoff and retained replacements/failures still consume every receipt.
    const value = new ReaderContinuousCellSnapshot(snapshot, key, frames)
    this.values.set(key, value)
    return value
  }
}
