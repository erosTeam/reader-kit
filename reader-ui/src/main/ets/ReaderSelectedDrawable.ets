import { ReaderPagedSnapshot, ReaderUnitKey } from '@reader-kit/core'

/** A selected paged composite whose original parts have completed native decode.
 * This is drawable readiness, not proof that the root overlay has revealed it. */
export class ReaderSelectedDrawable {
  readonly unit: ReaderUnitKey
  readonly topologyRevision: number
  readonly navigationRevision: number
  readonly selectionId: number
  readonly displayIndex: number
  readonly displayKey: string
  private readonly parts: string[]

  private constructor(snapshot: ReaderPagedSnapshot, unit: ReaderUnitKey, parts: string[]) {
    this.unit = unit.copy()
    this.topologyRevision = snapshot.topologyRevision
    this.navigationRevision = snapshot.navigationRevision
    this.selectionId = snapshot.selectionId
    this.displayIndex = snapshot.displayIndex
    this.displayKey = snapshot.displayKeys[snapshot.displayIndex]
    this.parts = parts
  }

  static from(snapshot: ReaderPagedSnapshot): ReaderSelectedDrawable | null {
    if (snapshot.phase !== 'ready' || snapshot.unit === null || snapshot.kind !== 'original' ||
      snapshot.policy.layout === 'continuous' || snapshot.displayIndex < 0 ||
      snapshot.displayIndex >= snapshot.displayCount || snapshot.frames.length === 0 ||
      snapshot.displayKeys[snapshot.displayIndex] === undefined) return null
    const parts: string[] = []
    for (const frame of snapshot.frames) {
      const asset = frame.asset
      if (asset.kind !== 'original' || asset.phase !== 'displayed' || asset.uri.length === 0 ||
        asset.assetRequestId <= 0) return null
      parts.push(`${frame.part.sourceIndex}:${frame.part.fragment}:${frame.slotId}:` +
        `${asset.assetRequestId}:${asset.visualRevision}`)
    }
    return new ReaderSelectedDrawable(snapshot, snapshot.unit.key, parts)
  }

  key(): string {
    return JSON.stringify([this.unit.scope, this.unit.work, this.unit.unit, this.topologyRevision,
      this.navigationRevision, this.selectionId, this.displayIndex, this.displayKey, this.parts])
  }

  partCount(): number { return this.parts.length }

  current(snapshot: ReaderPagedSnapshot): boolean {
    return ReaderSelectedDrawable.from(snapshot)?.key() === this.key()
  }
}
