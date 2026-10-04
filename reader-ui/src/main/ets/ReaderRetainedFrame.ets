import { ReaderPagedFrame } from '@reader-kit/core'

/** Presentation-only projection of the prior asset already retained by Core. */
export function readerRetainedFrame(frame: ReaderPagedFrame, previous: ReaderPagedFrame | null): ReaderPagedFrame | null {
  const retainedUri = frame.asset.retainedUri
  const retainedRequest = frame.asset.retainedAssetRequestId
  // Equal URI strings still represent different presentation epochs on reload.
  // The separate candidate image site owns completion of the new request.
  if (retainedUri.length === 0 || retainedRequest <= 0) return null
  if (previous?.asset.uri === retainedUri && previous.asset.assetRequestId === retainedRequest) return previous
  const asset = frame.asset.copy()
  asset.phase = 'displayed'
  asset.uri = retainedUri
  asset.requestId = retainedRequest
  asset.assetRequestId = retainedRequest
  asset.retainedUri = ''
  asset.retainedAssetRequestId = 0
  const retained = new ReaderPagedFrame(frame.slotId, frame.part, asset, frame.crop)
  retained.cropPending = frame.cropPending
  return retained
}
