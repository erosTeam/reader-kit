import { ReaderUnit } from './ReaderContent'
import { ReaderCancellation } from './ReaderSession'
import { ReaderPagedSnapshot, ReaderPagedFrame } from './ReaderPagedSession'

export type ReaderImageSaveChoice = 'current' | 'left' | 'right' | 'both'
export type ReaderImageSaveItemStatus = 'saved' | 'cancelled' | 'failed'
export type ReaderImageSaveOutcome = 'completed' | 'cancelled' | 'failed' | 'ignored'

/** A descriptor, NOT a resource lease. Hosts must pin/copy its exact reading resource. */
export class ReaderImageSaveItem {
  sourceIndex: number
  pageKey: string
  slotId: number
  assetRequestId: number
  uri: string
  constructor(sourceIndex: number, pageKey: string, slotId: number, assetRequestId: number, uri: string) {
    this.sourceIndex = sourceIndex
    this.pageKey = pageKey
    this.slotId = slotId
    this.assetRequestId = assetRequestId
    this.uri = uri
  }
  copy(): ReaderImageSaveItem {
    return new ReaderImageSaveItem(this.sourceIndex, this.pageKey, this.slotId, this.assetRequestId, this.uri)
  }
  equals(other: ReaderImageSaveItem): boolean {
    return this.sourceIndex === other.sourceIndex && this.pageKey === other.pageKey &&
      this.slotId === other.slotId && this.assetRequestId === other.assetRequestId && this.uri === other.uri
  }
}

export class ReaderImageSaveTarget {
  unit: ReaderUnit
  navigation: number
  items: ReaderImageSaveItem[]
  constructor(unit: ReaderUnit, navigation: number, items: ReaderImageSaveItem[]) {
    this.unit = unit.copy()
    this.navigation = navigation
    this.items = items.map((item: ReaderImageSaveItem) => item.copy())
  }
  static from(snapshot: ReaderPagedSnapshot, choice: ReaderImageSaveChoice): ReaderImageSaveTarget | null {
    const unit = snapshot.unit
    if (snapshot.phase !== 'ready' || snapshot.kind !== 'original' || unit === null) return null
    let frames: ReaderPagedFrame[] = snapshot.frames.slice()
    // ReaderPagedSession.framesAt already projects visual left-to-right order.
    if (choice === 'current') {
      const anchor = snapshot.anchor
      if (anchor === null || !anchor.unit.equals(unit.key)) return null
      frames = frames.filter((frame: ReaderPagedFrame) => frame.part.sourceIndex === anchor.sourceIndexHint)
    } else {
      if (frames.length !== 2 || snapshot.policy.layout !== 'spread') return null
      if (choice === 'left') frames = [frames[0]]
      else if (choice === 'right') frames = [frames[1]]
      else if (choice !== 'both') return null
    }
    if (frames.length === 0) return null
    const items: ReaderImageSaveItem[] = []
    for (const frame of frames) {
      const asset = frame.asset
      const page = asset.page
      const index = frame.part.sourceIndex
      if (!Number.isSafeInteger(index) || index < 0 || index >= unit.pageCount ||
        !frame.part.unit.equals(unit.key) || page === null || !page.unit.equals(unit.key) ||
        asset.unit === null || !asset.unit.key.equals(unit.key) || page.sourceIndex !== index ||
        asset.sourceIndex !== index || page.key !== frame.part.pageKey || page.key.length === 0 ||
        asset.kind !== 'original' || asset.phase !== 'displayed' || asset.uri.length === 0 ||
        asset.assetRequestId <= 0 || frame.slotId <= 0) return null
      if (!items.some((item: ReaderImageSaveItem) => item.sourceIndex === index)) {
        items.push(new ReaderImageSaveItem(index, page.key, frame.slotId, asset.assetRequestId, asset.uri))
      }
    }
    return new ReaderImageSaveTarget(unit, snapshot.navigationRevision, items)
  }
  copy(): ReaderImageSaveTarget { return new ReaderImageSaveTarget(this.unit, this.navigation, this.items) }
  equals(other: ReaderImageSaveTarget): boolean {
    return this.unit.key.equals(other.unit.key) && this.navigation === other.navigation &&
      this.items.length === other.items.length &&
      this.items.every((item: ReaderImageSaveItem, index: number) => item.equals(other.items[index]))
  }
}

export class ReaderImageSaveItemResult {
  sourceIndex: number
  status: ReaderImageSaveItemStatus
  constructor(sourceIndex: number, status: ReaderImageSaveItemStatus) {
    this.sourceIndex = sourceIndex
    this.status = status
  }
}
export class ReaderImageSaveResult {
  outcome: ReaderImageSaveOutcome
  items: ReaderImageSaveItemResult[]
  constructor(outcome: ReaderImageSaveOutcome, items: ReaderImageSaveItemResult[] = []) {
    this.outcome = outcome
    this.items = items.map((item: ReaderImageSaveItemResult) => new ReaderImageSaveItemResult(item.sourceIndex, item.status))
  }
}
export interface ReaderImageSavePresentation {
  /** Resolves after dialog dismissal AND file copies; includes every requested source. */
  present(): Promise<ReaderImageSaveItemResult[]>
  release(): void
}
export interface ReaderImageSaveHost {
  /** No dialogs or album writes here. Own resources until release, including on cancellation. */
  prepare(target: ReaderImageSaveTarget, cancellation: ReaderCancellation): Promise<ReaderImageSavePresentation>
}
class ReaderImageSaveOperation {
  target: ReaderImageSaveTarget
  choice: ReaderImageSaveChoice
  cancellation: ReaderCancellation = new ReaderCancellation()
  presenting: boolean = false
  constructor(target: ReaderImageSaveTarget, choice: ReaderImageSaveChoice) {
    this.target = target.copy()
    this.choice = choice
  }
}
export class ReaderImageSaveController {
  private snapshot: ReaderPagedSnapshot = new ReaderPagedSnapshot()
  private operation: ReaderImageSaveOperation | null = null
  private active: boolean = false
  private closed: boolean = false
  private listener: ((busy: boolean) => void) | null = null
  subscribe(listener: (busy: boolean) => void): void { this.listener = listener; listener(this.busy()) }
  busy(): boolean { return this.operation !== null }
  update(snapshot: ReaderPagedSnapshot, active: boolean): void {
    const captured = new ReaderPagedSnapshot()
    captured.unit = snapshot.unit?.copy() ?? null
    captured.phase = snapshot.phase
    captured.kind = snapshot.kind
    captured.policy = snapshot.policy.copy()
    captured.anchor = snapshot.anchor?.copy() ?? null
    captured.navigationRevision = snapshot.navigationRevision
    captured.frames = snapshot.frames.map((frame: ReaderPagedFrame) =>
      new ReaderPagedFrame(frame.slotId, frame.part, frame.asset))
    this.snapshot = captured
    this.active = active && !this.closed
    const operation = this.operation
    if (operation !== null && !operation.presenting && !this.current(operation)) {
      operation.cancellation.cancel()
      this.operation = null
      this.listener?.(false)
    }
  }
  close(): void {
    this.closed = true
    this.listener = null
    this.update(new ReaderPagedSnapshot(), false)
  }
  private current(operation: ReaderImageSaveOperation): boolean {
    const target = ReaderImageSaveTarget.from(this.snapshot, operation.choice)
    return !this.closed && this.active && !operation.cancellation.isCancelled() &&
      target !== null && operation.target.equals(target)
  }
  async save(host: ReaderImageSaveHost, choice: ReaderImageSaveChoice): Promise<ReaderImageSaveResult> {
    const target = ReaderImageSaveTarget.from(this.snapshot, choice)
    if (!this.active || this.closed || target === null || this.busy()) return new ReaderImageSaveResult('ignored')
    const operation = new ReaderImageSaveOperation(target, choice)
    this.operation = operation
    this.listener?.(true)
    let presentation: ReaderImageSavePresentation | null = null
    try {
      presentation = await host.prepare(target.copy(), operation.cancellation)
      if (!this.current(operation)) return new ReaderImageSaveResult('cancelled')
      operation.presenting = true
      return new ReaderImageSaveResult('completed', await presentation.present())
    } catch (_) {
      return new ReaderImageSaveResult(operation.presenting || this.current(operation) ? 'failed' : 'cancelled')
    } finally {
      try { presentation?.release() } catch (_) { /* Cleanup cannot rewrite completed album writes. */ }
      if (this.operation === operation) {
        this.operation = null
        this.listener?.(false)
      }
    }
  }
}
