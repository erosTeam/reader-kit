/** One current-viewport zoom reset. It carries the same topology/navigation fences as page commands. */
export class ReaderZoomResetCommand {
  serial: number
  topologyRevision: number
  navigationRevision: number

  constructor(serial: number, topologyRevision: number, navigationRevision: number) {
    this.serial = serial
    this.topologyRevision = topologyRevision
    this.navigationRevision = navigationRevision
  }
}
