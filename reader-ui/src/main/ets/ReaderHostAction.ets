/**
 * A host-supplied overflow action. reader-kit renders and stale-guards it but
 * does not know which app service, account, cache or preference it controls.
 */
export class ReaderHostAction {
  id: string
  label: string
  enabled: boolean
  checked: boolean
  busy: boolean

  constructor(id: string, label: string, enabled: boolean = true,
    checked: boolean = false, busy: boolean = false) {
    this.id = id
    this.label = label
    this.enabled = enabled
    this.checked = checked
    this.busy = busy
  }
}
