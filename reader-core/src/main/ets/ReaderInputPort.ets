export type ReaderMoveIntent = 'previous' | 'next'

/** Synchronous host input. Never queues an event for a later route or reading unit. */
export class ReaderInputPort {
  private serial: number = 0
  private listener: ((intent: ReaderMoveIntent) => boolean) | null = null

  connect(listener: (intent: ReaderMoveIntent) => boolean): number {
    this.listener = listener
    return ++this.serial
  }
  disconnect(connection: number): void {
    if (connection === this.serial) this.listener = null
  }
  move(intent: ReaderMoveIntent): boolean {
    return this.listener !== null && this.listener(intent)
  }
}
