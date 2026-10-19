/** Native viewport identity survives source pages being regrouped into spreads. */
export class ReaderPagerItemIdentity {
  key: string
  nativeKey: string
  constructor(key: string, nativeKey: string) { this.key = key; this.nativeKey = nativeKey }
}

export class ReaderPagerIdentityMap {
  private items: ReaderPagerItemIdentity[] = []
  private selected: number = -1
  private topology: number = -1
  private unit: string = ''
  private serial: number = 0

  update(keys: string[], selected: number, topology: number, unit: string): ReaderPagerItemIdentity[] {
    if (unit === this.unit && topology === this.topology) {
      this.selected = selected
      return this.items
    }
    const previous = unit === this.unit ? this.items : []
    const selectedBefore = previous[this.selected]
    const used: Set<string> = new Set<string>()
    const assigned: Map<string, string> = new Map<string, string>()
    const nextSelected = keys[selected]
    // The visible viewport wins over an offscreen exact-key match. This matters
    // when the selected second page joins its preceding page in a spread.
    if (selectedBefore !== undefined && nextSelected !== undefined &&
      this.overlaps(selectedBefore.key, nextSelected)) {
      assigned.set(nextSelected, selectedBefore.nativeKey)
      used.add(selectedBefore.nativeKey)
    }
    const exact: Map<string, ReaderPagerItemIdentity> = new Map<string, ReaderPagerItemIdentity>()
    previous.forEach((item: ReaderPagerItemIdentity): void => { exact.set(item.key, item) })
    keys.forEach((key: string): void => {
      const item = exact.get(key)
      if (!assigned.has(key) && item !== undefined && !used.has(item.nativeKey)) {
        assigned.set(key, item.nativeKey)
        used.add(item.nativeKey)
      }
    })
    const byPart: Map<string, ReaderPagerItemIdentity> = new Map<string, ReaderPagerItemIdentity>()
    previous.forEach((item: ReaderPagerItemIdentity): void => {
      item.key.split('+').forEach((part: string): void => { byPart.set(part, item) })
    })
    this.items = keys.map((key: string): ReaderPagerItemIdentity => {
      let nativeKey = assigned.get(key)
      if (nativeKey === undefined) {
        const candidate = key.split('+').map((part: string): ReaderPagerItemIdentity | undefined =>
          byPart.get(part)).find((item: ReaderPagerItemIdentity | undefined): boolean =>
            item !== undefined && !used.has(item.nativeKey))
        nativeKey = candidate?.nativeKey ?? `viewport_${++this.serial}`
        used.add(nativeKey)
      }
      return new ReaderPagerItemIdentity(key, nativeKey)
    })
    this.selected = selected
    this.topology = topology
    this.unit = unit
    return this.items
  }

  private overlaps(left: string, right: string): boolean {
    const parts = left.split('+')
    return right.split('+').some((part: string): boolean => parts.includes(part))
  }
}
