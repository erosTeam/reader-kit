/** Existing host chrome geometry, not a user setting or a reading policy.
 * Defaults retain the shared layout; a host restores its previously confirmed
 * layout explicitly instead of changing every application's toolbar.
 */
export interface ReaderChromeAppearance {
  bottomHeight: number
  sliderHeight: number
  controlsHeight: number
  controlsPadding: number
  columnSpacing: number
  topActionSpacing: number
  fixedCounterSides: boolean
  mediaActionsInMenu: boolean
  spreadControlsLeading: boolean
}

export const DEFAULT_READER_CHROME_APPEARANCE: ReaderChromeAppearance = {
  bottomHeight: 112, sliderHeight: 0, controlsHeight: 0, controlsPadding: 0,
  columnSpacing: 4, topActionSpacing: 0, fixedCounterSides: false, mediaActionsInMenu: false,
  spreadControlsLeading: false,
}
