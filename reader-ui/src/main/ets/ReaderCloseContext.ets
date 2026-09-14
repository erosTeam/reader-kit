import { ReaderDisplayPart, ReaderFragment, ReaderPagedFrame, ReaderPagedItemSnapshot, ReaderPagedSnapshot,
  ReaderUnitKey, readerPagedFrameAspectRatio } from '@reader-kit/core'

/**
 * Immutable identity for an actually presented reading frame at close time.
 * The host owns target remeasurement, system bars, route removal and animation.
 */
export class ReaderCloseContext {
  unit: ReaderUnitKey
  part: ReaderDisplayPart
  displayedSourceIndexes: number[]
  displayIndex: number
  topologyRevision: number
  navigationRevision: number
  selectionId: number
  slotId: number
  requestId: number
  assetRequestId: number
  captureComponentId: string
  contentAspectRatio: number

  constructor(snapshot: ReaderPagedSnapshot, frame: ReaderPagedFrame, captureComponentId: string,
    displayedSourceIndexes: number[]) {
    this.unit = frame.part.unit.copy()
    this.part = frame.part.copy()
    this.displayedSourceIndexes = displayedSourceIndexes.slice()
    this.displayIndex = snapshot.displayIndex
    this.topologyRevision = snapshot.topologyRevision
    this.navigationRevision = snapshot.navigationRevision
    this.selectionId = snapshot.selectionId
    this.slotId = frame.slotId
    this.requestId = frame.asset.requestId
    this.assetRequestId = frame.asset.assetRequestId
    this.captureComponentId = captureComponentId
    this.contentAspectRatio = readerPagedFrameAspectRatio(frame, snapshot.policy)
  }

  static from(snapshot: ReaderPagedSnapshot): ReaderCloseContext | null {
    const observed = snapshot.observedPosition()
    if (observed === null || snapshot.unit === null) return null
    if (snapshot.policy.layout === 'continuous') {
      const item = ReaderCloseContext.continuousItem(snapshot, observed.anchor.sourceIndexHint)
      if (item === null) return null
      const frame = ReaderCloseContext.presentedFrame(item.frames, observed.anchor.sourceIndexHint,
        observed.anchor.fragment)
      if (frame === null) return null
      return new ReaderCloseContext(snapshot, frame, `rkit-continuous-page-${item.index}`,
        observed.displayedSourceIndexes)
    }
    const frame = ReaderCloseContext.presentedFrame(snapshot.frames, observed.anchor.sourceIndexHint,
      observed.anchor.fragment)
    if (frame === null) return null
    return new ReaderCloseContext(snapshot, frame,
      `rkit-part-${frame.part.sourceIndex}-${frame.part.fragment}`, observed.displayedSourceIndexes)
  }

  matches(snapshot: ReaderPagedSnapshot): boolean {
    const current = ReaderCloseContext.from(snapshot)
    return current !== null && current.unit.equals(this.unit) &&
      current.part.pageKey === this.part.pageKey && current.part.sourceIndex === this.part.sourceIndex &&
      current.part.fragment === this.part.fragment && current.topologyRevision === this.topologyRevision &&
      current.navigationRevision === this.navigationRevision && current.selectionId === this.selectionId &&
      current.displayIndex === this.displayIndex &&
      current.slotId === this.slotId && current.requestId === this.requestId &&
      current.assetRequestId === this.assetRequestId && current.captureComponentId === this.captureComponentId &&
      current.contentAspectRatio === this.contentAspectRatio &&
      current.displayedSourceIndexes.length === this.displayedSourceIndexes.length &&
      current.displayedSourceIndexes.every((sourceIndex: number, index: number): boolean =>
        sourceIndex === this.displayedSourceIndexes[index])
  }

  private static continuousItem(snapshot: ReaderPagedSnapshot, sourceIndex: number): ReaderPagedItemSnapshot | null {
    return snapshot.window.find((item: ReaderPagedItemSnapshot): boolean =>
      item.index >= snapshot.visibleDisplayStart && item.index <= snapshot.visibleDisplayEnd &&
      item.frames.some((frame: ReaderPagedFrame): boolean => frame.part.sourceIndex === sourceIndex)) ?? null
  }

  private static presentedFrame(frames: ReaderPagedFrame[], sourceIndex: number,
    fragment: ReaderFragment): ReaderPagedFrame | null {
    return frames.find((frame: ReaderPagedFrame): boolean => frame.part.sourceIndex === sourceIndex &&
      frame.part.fragment === fragment &&
      frame.asset.kind === 'original' && frame.asset.phase === 'displayed' && frame.asset.assetRequestId > 0 &&
      frame.asset.page !== null && frame.asset.page.unit.equals(frame.part.unit) &&
      frame.asset.page.key === frame.part.pageKey) ?? null
  }
}
