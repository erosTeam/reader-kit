/** Host-owned automatic-reading preference; timing and navigation remain reader-kit responsibilities. */
export class ReaderAutoReadPolicy {
  readonly available: boolean
  readonly seconds: number
  /** The common controller owns timing; the host declares its legacy next-item rule. */
  readonly targetReadiness: 'current' | 'source'

  constructor(available: boolean = false, seconds: number = 3,
    targetReadiness: 'current' | 'source' = 'current') {
    this.available = available
    this.seconds = seconds
    this.targetReadiness = targetReadiness
  }
}

/** Optional host control at the existing clock position; the Kit still owns the timer. */
export class ReaderAutoReadControlParams {
  active: boolean = false
  ready: boolean = false
  available: boolean = false
  enabled: boolean = false
  onSetEnabled: (enabled: boolean) => void = () => {}
  onMenuVisible: (visible: boolean) => void = () => {}
}
