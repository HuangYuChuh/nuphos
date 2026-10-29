import assert from 'node:assert/strict'
import { test } from 'node:test'
import { piMcpConfiguration } from '../image/pi-session.mjs'

test('Pi preserves literal MCP environment and header values', () => {
  const configuration = piMcpConfiguration([
    {
      name: 'tools',
      command: 'node',
      args: ['server.mjs'],
      env: [{ name: 'VALUE', value: '${HOME}' }],
    },
    {
      name: 'remote',
      type: 'http',
      url: 'https://example.com/mcp',
      headers: [{ name: 'X-Value', value: '!command' }],
    },
  ])
  assert.equal(configuration.mcpServers.tools.env.VALUE, '$${HOME}')
  assert.equal(configuration.mcpServers.remote.headers['X-Value'], '$!command')
  assert.equal(configuration.mcpServers.tools.exposure, 'direct')
})

test('Pi rejects unsupported transports and colliding tool namespaces', () => {
  assert.throws(() => piMcpConfiguration([{ name: 'legacy', type: 'sse' }]), /Unsupported/)
  assert.throws(() => piMcpConfiguration([{ name: '../outside' }]), /names/)
  assert.throws(
    () =>
      piMcpConfiguration([
        { name: 'team-tools', command: 'node', args: [] },
        { name: 'team_tools', command: 'node', args: [] },
      ]),
    /Duplicate/,
  )
  assert.throws(
    () => piMcpConfiguration([{ name: 'tools', command: 'node', args: [1] }]),
    /arguments/,
  )
})

test('Pi does not inherit MCP servers from another session', () => {
  const configuration = piMcpConfiguration([])
  assert.equal(Object.keys(configuration.mcpServers).length, 0)
})
