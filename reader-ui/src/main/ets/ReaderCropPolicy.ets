/** Host-owned border-crop presentation policy; detector and persistence stay outside reader-kit. */
export class ReaderCropPolicy {
  readonly enabled: boolean
  readonly available: boolean
  readonly sourceRevision: string

  constructor(enabled: boolean = false, available: boolean = false, sourceRevision: string = '') {
    this.enabled = enabled
    this.available = available
    this.sourceRevision = sourceRevision
  }
}
