const test = require('node:test')
const assert = require('node:assert/strict')
const { ReaderInputPort } = require('./load-core.cjs')('ReaderInputPort')

test('host input is synchronous, preserves logical direction and does not queue disconnected events', () => {
  const port = new ReaderInputPort()
  assert.equal(port.move('next'), false)
  const calls = []
  const connection = port.connect(intent => { calls.push(intent); return intent === 'next' })
  assert.equal(port.move('next'), true)
  assert.equal(port.move('previous'), false)
  assert.deepEqual(calls, ['next', 'previous'])
  port.disconnect(connection)
  assert.equal(port.move('next'), false)
  assert.deepEqual(calls, ['next', 'previous'])
})

test('retired surface cannot disconnect a new route input owner', () => {
  const port = new ReaderInputPort()
  let oldCalls = 0
  let newCalls = 0
  const retired = port.connect(() => { oldCalls++; return true })
  const current = port.connect(() => { newCalls++; return true })
  port.disconnect(retired)
  assert.equal(port.move('next'), true)
  assert.equal(oldCalls, 0)
  assert.equal(newCalls, 1)
  port.disconnect(current)
  assert.equal(port.move('next'), false)
})
