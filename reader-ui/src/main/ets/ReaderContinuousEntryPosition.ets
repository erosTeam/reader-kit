import { ReaderPagedSnapshot, ReaderPagedFrame } from '@reader-kit/core'
import { ReaderEntryTransition } from './ReaderEntryTransition'

/** A single completed List positioning epoch, not a second scroll or progress owner. */
export class ReaderContinuousEntryPosition {
  readonly epoch: number
  readonly key: string
  readonly selection: number
  readonly topology: number
  readonly navigation: number
  readonly slot: number
  readonly load: number
  readonly asset: number
  readonly width: number
  readonly height: number
  readonly entry: ReaderEntryTransition
  private current: () => boolean

  constructor(epoch: number, snapshot: ReaderPagedSnapshot, frame: ReaderPagedFrame,
    width: number, height: number, entry: ReaderEntryTransition, current: () => boolean) {
    this.epoch = epoch; this.key = snapshot.displayKeys[snapshot.displayIndex]
    this.selection = snapshot.selectionId; this.topology = snapshot.topologyRevision
    this.navigation = snapshot.navigationRevision; this.slot = frame.slotId
    this.load = frame.asset.requestId; this.asset = frame.asset.assetRequestId
    this.width = width; this.height = height; this.entry = entry; this.current = current
  }

  matches(snapshot: ReaderPagedSnapshot): boolean {
    const frame = snapshot.forItem(this.key).frames[0]
    return snapshot.displayKeys[snapshot.displayIndex] === this.key &&
      snapshot.selectionId === this.selection && snapshot.topologyRevision === this.topology &&
      snapshot.navigationRevision === this.navigation && frame !== undefined && this.entry.matches(frame.part) &&
      frame.slotId === this.slot && frame.asset.requestId === this.load && frame.asset.assetRequestId === this.asset
  }

  isCurrent(): boolean { return this.entry.pending() && this.current() }
}
