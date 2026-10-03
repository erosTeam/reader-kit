import { ReaderDisplayPolicy } from '@reader-kit/core'

/** A host may reuse its mode button without owning a second reader policy. */
export class ReaderModeControlParams {
  policy: ReaderDisplayPolicy = new ReaderDisplayPolicy()
  enabled: boolean = false
  onChange: (policy: ReaderDisplayPolicy) => void = () => {}
  onMenuVisible: (visible: boolean) => void = () => {}
}
