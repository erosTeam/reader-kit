/** Source identifiers are opaque to the reader. Never put credentials in scope. */
export class ReaderUnitKey {
  scope: string
  work: string
  unit: string

  constructor(scope: string, work: string, unit: string) {
    this.scope = scope
    this.work = work
    this.unit = unit
  }

  equals(other: ReaderUnitKey): boolean {
    return this.scope === other.scope && this.work === other.work && this.unit === other.unit
  }

  copy(): ReaderUnitKey { return new ReaderUnitKey(this.scope, this.work, this.unit) }
}

export class ReaderUnit {
  key: ReaderUnitKey
  title: string
  pageCount: number

  constructor(key: ReaderUnitKey, title: string, pageCount: number) {
    this.key = key
    this.title = title
    this.pageCount = pageCount
  }

  copy(): ReaderUnit { return new ReaderUnit(this.key.copy(), this.title, this.pageCount) }
}

export class ReaderThumbnail {
  available: boolean = true
  kind: 'image' | 'sprite' | 'derived' = 'image'
  width: number = 0
  height: number = 0
  spriteWidth: number = 0
  spriteHeight: number = 0
  offsetX: number = 0
  offsetY: number = 0

  copy(): ReaderThumbnail {
    const value = new ReaderThumbnail()
    value.available = this.available
    value.kind = this.kind
    value.width = this.width
    value.height = this.height
    value.spriteWidth = this.spriteWidth
    value.spriteHeight = this.spriteHeight
    value.offsetX = this.offsetX
    value.offsetY = this.offsetY
    return value
  }
}

export class ReaderPage {
  unit: ReaderUnitKey
  key: string
  sourceIndex: number
  width: number = 0
  height: number = 0
  thumbnail: ReaderThumbnail = new ReaderThumbnail()
  /**
   * Host-confirmed body-source state for automatic reading. It is deliberately
   * independent from thumbnail availability: a preview can exist before the
   * host has resolved a usable body image.
   */
  bodySourceReady: boolean = false
  /** A failed target stays paused until a host publishes a fresh source state. */
  bodySourceFailed: boolean = false

  constructor(unit: ReaderUnitKey, key: string, sourceIndex: number) {
    this.unit = unit
    this.key = key
    this.sourceIndex = sourceIndex
  }

  copy(): ReaderPage {
    const value = new ReaderPage(this.unit.copy(), this.key, this.sourceIndex)
    value.width = this.width
    value.height = this.height
    value.thumbnail = this.thumbnail.copy()
    value.bodySourceReady = this.bodySourceReady
    value.bodySourceFailed = this.bodySourceFailed
    return value
  }
}
