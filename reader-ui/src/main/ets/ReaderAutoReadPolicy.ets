/** Host-owned automatic-reading preference; timing and navigation remain reader-kit responsibilities. */
export class ReaderAutoReadPolicy {
  readonly available: boolean
  readonly seconds: number

  constructor(available: boolean = false, seconds: number = 3) {
    this.available = available
    this.seconds = seconds
  }
}
