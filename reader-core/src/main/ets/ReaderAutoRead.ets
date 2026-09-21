import { ReaderPagedSnapshot } from './ReaderPagedSession'
import { ReaderDisplayMap } from './ReaderDisplayMap'

export interface ReaderAutoReadClock {
  set(callback: () => void, delayMs: number): number
  clear(id: number): void
}

/** Host semantics for whether the next display item may receive an automatic turn. */
export type ReaderAutoReadTargetReadiness = 'current' | 'source'

class AutoReadClock implements ReaderAutoReadClock {
  set(callback: () => void, delayMs: number): number { return setTimeout(callback, delayMs) }
  clear(id: number): void { clearTimeout(id) }
}

/** A one-shot next request per fully displayed item; never owns navigation or preferences. */
export class ReaderAutoReadController {
  private clock: ReaderAutoReadClock
  private next: () => boolean
  private listener: ((enabled: boolean) => void) | null = null
  private enabled: boolean = false
  private closed: boolean = false
  private foreground: boolean = false
  private blocked: boolean = false
  private ready: boolean = false
  private last: boolean = false
  private targetReady: boolean = true
  private waitingForTarget: boolean = false
  private interval: number = 3
  private boundary: string = ''
  private identity: string = ''
  private fired: string = ''
  private timer: number = -1
  private generation: number = 0
  /** Invoked once after the dwell interval when a source-target needs host preparation. */
  private targetPending: (() => void) | null

  constructor(onNext: () => boolean, clock: ReaderAutoReadClock = new AutoReadClock(),
    onTargetPending: (() => void) | null = null) {
    this.next = onNext
    this.clock = clock
    this.targetPending = onTargetPending
  }
  subscribe(listener: ((enabled: boolean) => void) | null): void {
    this.listener = listener
    this.listener?.(this.enabled)
  }
  isEnabled(): boolean { return this.enabled }
  setEnabled(enabled: boolean): void {
    if (this.closed || enabled === this.enabled) return
    this.enabled = enabled
    this.fired = ''
    if (!enabled) this.waitingForTarget = false
    this.cancelTimer()
    this.listener?.(enabled)
    this.schedule()
  }
  stop(): void { this.setEnabled(false) }
  close(): void {
    this.stop()
    this.closed = true
    this.cancelTimer()
    this.listener = null
  }
  update(snapshot: ReaderPagedSnapshot, foreground: boolean, blocked: boolean, intervalSeconds: number = 3,
    targetReadiness: ReaderAutoReadTargetReadiness = 'current'): void {
    if (this.closed) return
    const boundary = snapshot.unit === null ? '' : JSON.stringify([snapshot.unit.key, snapshot.policy.layout])
    if (this.boundary !== '' && boundary !== this.boundary) this.stop()
    this.boundary = boundary
    const interval = Number.isFinite(intervalSeconds) ? Math.max(1, Math.min(60, Math.round(intervalSeconds))) : 3
    let ready = false
    let last = false
    let targetReady = true
    let identity = ''
    if (snapshot.unit !== null && snapshot.phase === 'ready' && snapshot.kind === 'original') {
      const map = new ReaderDisplayMap(snapshot.unit, snapshot.pageMetadata, snapshot.policy)
      const item = map.item(snapshot.displayIndex)
      if (item !== null && item.parts.length > 0 && snapshot.frames.length === item.parts.length &&
        snapshot.displayCount === map.count()) {
        ready = item.parts.every(part => {
          const matches = snapshot.frames.filter(frame => frame.part.sourceIndex === part.sourceIndex &&
            frame.part.fragment === part.fragment)
          if (matches.length !== 1 || part.pageKey === null) return false
          const frame = matches[0]
          const asset = frame.asset
          return frame.part.unit.equals(part.unit) && frame.part.pageKey === part.pageKey &&
            asset.unit !== null && asset.unit.key.equals(part.unit) && asset.page !== null &&
            asset.page.unit.equals(part.unit) && asset.page.key === part.pageKey &&
            asset.page.sourceIndex === part.sourceIndex && asset.sourceIndex === part.sourceIndex &&
            asset.kind === 'original' && asset.phase === 'displayed' && asset.uri.length > 0
        })
        last = map.isLastDisplayItem(snapshot.displayIndex)
        if (ready && !last && targetReadiness !== 'current') {
          targetReady = this.targetSourceReady(snapshot, map)
        }
      }
      identity = JSON.stringify([boundary, snapshot.policy, snapshot.topologyRevision, snapshot.navigationRevision,
        snapshot.displayIndex, snapshot.selectionId, snapshot.frames.map(frame =>
          [frame.slotId, frame.part.sourceIndex, frame.part.fragment, frame.part.pageKey,
            frame.asset.assetRequestId, frame.asset.uri])])
    }
    if (identity !== this.identity || !ready || foreground !== this.foreground || blocked !== this.blocked ||
      interval !== this.interval) this.cancelTimer()
    if (identity !== this.identity) {
      this.fired = ''
      this.waitingForTarget = false
    }
    this.identity = identity
    this.ready = ready
    this.last = last
    this.targetReady = targetReady
    this.foreground = foreground
    this.blocked = blocked
    this.interval = interval
    if (this.waitingForTarget && targetReady && ready && identity.length > 0) {
      this.waitingForTarget = false
      this.fired = ''
    }
    this.schedule()
  }

  private targetSourceReady(snapshot: ReaderPagedSnapshot, map: ReaderDisplayMap): boolean {
    const targetIndex = snapshot.displayIndex + 1
    const target = map.item(targetIndex)
    if (target === null) return false
    return target.parts.every(part => {
      if (part.pageKey === null) return false
      const page = snapshot.pageMetadata.find(candidate => candidate.sourceIndex === part.sourceIndex &&
        candidate.key === part.pageKey && candidate.unit.equals(part.unit))
      if (page === undefined || !page.bodySourceReady || page.bodySourceFailed) return false
      const item = snapshot.window.find(candidate => candidate.index === targetIndex)
      if (item === undefined) return true
      const matches = item.frames.filter(frame => frame.part.sourceIndex === part.sourceIndex &&
        frame.part.fragment === part.fragment)
      return matches.length <= 1 && (matches.length === 0 || matches[0].asset.phase !== 'failed')
    })
  }
  private cancelTimer(): void {
    this.generation++
    if (this.timer !== -1) this.clock.clear(this.timer)
    this.timer = -1
  }
  private schedule(): void {
    if (this.closed || !this.enabled || !this.foreground || this.blocked || !this.ready || this.waitingForTarget ||
      this.timer !== -1 || this.identity === this.fired) return
    const generation = this.generation
    const identity = this.identity
    this.timer = this.clock.set((): void => {
      if (generation !== this.generation || identity !== this.identity || this.closed || !this.enabled ||
        !this.foreground || this.blocked || !this.ready) return
      this.timer = -1
      this.generation++
      if (this.last) this.stop()
      else {
        if (!this.targetReady) {
          this.waitingForTarget = true
          this.targetPending?.()
          return
        }
        this.fired = identity
        const accepted = this.next()
        // next may synchronously update to a new selection and arm its timer.
        if (!accepted && this.identity === identity && this.fired === identity) {
          this.fired = ''
          this.schedule()
        }
      }
    }, this.interval * 1000)
  }
}
