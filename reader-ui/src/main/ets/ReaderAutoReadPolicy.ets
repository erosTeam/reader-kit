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
