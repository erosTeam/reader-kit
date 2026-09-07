import { ReaderUnit } from './ReaderContent'
import { ReaderCancellation } from './ReaderSession'
import { ReaderPagedSnapshot } from './ReaderPagedSession'

/** The original page named by the chrome, independent of visual spread order. */
export class ReaderImageShareTarget {
  unit: ReaderUnit
  sourceIndex: number
  navigation: number

  constructor(unit: ReaderUnit, sourceIndex: number, navigation: number) {
    this.unit = unit.copy()
    this.sourceIndex = sourceIndex
    this.navigation = navigation
  }

  static from(snapshot: ReaderPagedSnapshot): ReaderImageShareTarget | null {
    const unit = snapshot.unit
    const anchor = snapshot.anchor
    if (snapshot.phase !== 'ready' || unit === null || anchor === null ||
      !anchor.unit.equals(unit.key) || anchor.sourceIndexHint < 0 ||
      anchor.sourceIndexHint >= unit.pageCount) return null
    return new ReaderImageShareTarget(unit, anchor.sourceIndexHint, snapshot.navigationRevision)
  }

  copy(): ReaderImageShareTarget {
    return new ReaderImageShareTarget(this.unit, this.sourceIndex, this.navigation)
  }

  equals(other: ReaderImageShareTarget): boolean {
    return this.unit.key.equals(other.unit.key) && this.sourceIndex === other.sourceIndex &&
      this.navigation === other.navigation
  }
}

export interface ReaderImageSharePresentation {
  /** Resolves when the host presentation closes, not when it merely appears. */
  present(): Promise<void>
  release(): void
}

export interface ReaderImageShareHost {
  prepare(target: ReaderImageShareTarget, cancellation: ReaderCancellation): Promise<ReaderImageSharePresentation>
}

export type ReaderImageShareOutcome = 'dismissed' | 'cancelled' | 'failed' | 'ignored'

class ReaderImageShareOperation {
  target: ReaderImageShareTarget
  cancellation: ReaderCancellation = new ReaderCancellation()
  presenting: boolean = false
  constructor(target: ReaderImageShareTarget) { this.target = target.copy() }
}

/** Route-local async arbitration; no platform records, URLs or file ownership. */
export class ReaderImageShareController {
  private target: ReaderImageShareTarget | null = null
  private operation: ReaderImageShareOperation | null = null
  private active: boolean = false
  private closed: boolean = false
  private listener: ((busy: boolean) => void) | null = null

  subscribe(listener: (busy: boolean) => void): void {
    this.listener = listener
    listener(this.busy())
  }

  busy(): boolean { return this.operation !== null }

  update(target: ReaderImageShareTarget | null, active: boolean): void {
    this.target = target?.copy() ?? null
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
    this.update(null, false)
    // An already presented host sheet owns its resources until dismissal.
    this.listener = null
  }

  private current(operation: ReaderImageShareOperation): boolean {
    return !this.closed && this.active && !operation.cancellation.isCancelled() &&
      this.target !== null && operation.target.equals(this.target)
  }

  async share(host: ReaderImageShareHost): Promise<ReaderImageShareOutcome> {
    if (!this.active || this.closed || this.target === null || this.busy()) return 'ignored'
    const operation = new ReaderImageShareOperation(this.target)
    this.operation = operation
    this.listener?.(true)
    let presentation: ReaderImageSharePresentation | null = null
    try {
      presentation = await host.prepare(operation.target.copy(), operation.cancellation)
      if (!this.current(operation)) return 'cancelled'
      operation.presenting = true
      await presentation.present()
      return 'dismissed'
    } catch (_) {
      return this.current(operation) ? 'failed' : 'cancelled'
    } finally {
      try { presentation?.release() } finally {
        if (this.operation === operation) {
          this.operation = null
          this.listener?.(false)
        }
      }
    }
  }
}
