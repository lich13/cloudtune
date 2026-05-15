import assert from 'node:assert/strict'
import test from 'node:test'

import { isNativeDecodePlaybackError } from '../src/playbackErrors.ts'

test('detects native decoder failures from backend command errors', () => {
  const error = new Error(
    'failed to decode audio file C:\\Users\\Administrator\\AppData\\Local\\CloudTune\\data\\cache\\423511241687918944-0012851980.320.m4a',
  )

  assert.equal(isNativeDecodePlaybackError(error), true)
})

test('does not treat unrelated playback failures as native decoder failures', () => {
  assert.equal(isNativeDecodePlaybackError(new Error('stream request returned 502')), false)
})
