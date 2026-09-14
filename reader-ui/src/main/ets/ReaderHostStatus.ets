/** Passive host feedback rendered over the reader without taking input. */
export class ReaderHostStatus {
  readonly text: string
  readonly busy: boolean

  constructor(text: string, busy: boolean = false) {
    this.text = text
    this.busy = busy
  }
}
