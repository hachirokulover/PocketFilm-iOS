#!/usr/bin/env node
// Bake Fotufilm's published Legacy WebAssembly render into a scene-linear 3D LUT.
// The browser inputs are read locally. Only the resulting data is shipped in the app.
import { createHash } from 'node:crypto'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const [input, output] = process.argv.slice(2).map(arg => resolve(arg))
if (!input || !output) throw new Error('Usage: node bake-fotufilm.mjs INPUT_DIR OUTPUT_DIR')
const revision = '6426fb2e46a35bd1e553'
const dimension = 33
const width = dimension * dimension
const height = dimension
const pixels = width * height
const sourceFiles = {
  'bridge.js': '67cc127e4f39251ea05d1982bcce5a56190094f581497d9177391e1593a3ae23',
  'assets/rolldown-runtime-hePW80VL.js': '580ad8c58061a4dde99bde0a56905e382f0568516ee2f5b84dbfb52085709021',
  'fotufilm.mjs': '5d36ad5fb605b191c3ed8621d3d5c808e0694f32e50dd2a6ae2de8d431d667da',
  'fotufilm.wasm': '2d0d40740782ae52d6ab468b61440641b81c7037f90fbbc5083e4b8e6fb69ee7',
  'index.json': 'e640d82ae005508b2202d7aeab55c3bd0cd432f19d091e58f77d5e423289981f',
}
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
async function readPinned(name) {
  const bytes = await readFile(join(input, name))
  if (sha256(bytes) !== sourceFiles[name]) throw new Error('Unexpected Fotufilm asset: ' + name)
  return bytes
}

const expected = JSON.parse(await readPinned('index.json'))
const bridge = await readPinned('bridge.js')
await readPinned('assets/rolldown-runtime-hePW80VL.js')
await readPinned('fotufilm.mjs')
const wasm = await readPinned('fotufilm.wasm')

// Expose the three internals of this specific, hash-checked browser build for offline baking.
const bridgePath = join(input, 'bridge-bake.mjs')
await writeFile(bridgePath, bridge.toString() + '\nexport { ct as parsePack, At as SimdDeveloper, s as CONFIG };\n')
const { parsePack, SimdDeveloper, CONFIG } = await import(pathToFileURL(bridgePath))
const { default: makeRuntime } = await import(pathToFileURL(join(input, 'fotufilm.mjs')))
globalThis.window = {}
globalThis.fetch = async () => new Response(wasm, { headers: { 'Content-Type': 'application/wasm' } })
const runtime = await makeRuntime()

function withoutSpatialEffects(developer) {
  developer.applyControls({ grain: 0, ev: 0 })
  const config = developer.configPtr / 4
  const fields = {
    HALATION: 3, HALATION_MATRIX: 9, HALATION_RADIUS: 3, HALATION_RING_RADIUS: 3,
    MTF_RADIUS: 3, MTF_SECONDARY_RADIUS: 3, MTF_LUMA_RADIUS: 1, PRINT_MTF_RADIUS: 1,
    COUPLER_RADIUS: 1, ADJACENCY_RADIUS: 1, ADJACENCY_SECONDARY_RADIUS: 1,
    ADJACENCY_STRENGTH: 1, CHROMATIC_FRINGE_AMOUNT: 1, CHROMATIC_FRINGE_RADIUS: 1,
  }
  for (const [name, count] of Object.entries(fields)) {
    if (CONFIG[name] === undefined) throw new Error('Missing configuration field ' + name)
    const start = config + CONFIG[name]
    runtime.HEAPF32.fill(0, start, start + count)
  }
  // A zero radius alone can still choose a decimated grid on donor-layer stocks.
  // Keep the same-pixel coupler response by forcing the Gaussian's finest stride.
  runtime.HEAPF32[config + CONFIG.COUPLER_SIGMA] = 0.151
}

function render(developer, source) {
  const region = { x: 0, y: 0, width, height }
  runtime.HEAPF32.set(source, developer.inputPtr / 4)
  if (developer.run(region) !== 0) throw new Error('Fotufilm failed to render the chart')
  return developer.regionOutput(region).slice(0, pixels * 3)
}

function chart() {
  const samples = Array.from({ length: dimension }, (_, index) =>
    Math.expm1(Math.log1p(32 * 8) * index / (dimension - 1)) / 32)
  const source = new Float32Array(pixels * 3)
  for (let i = 0; i < pixels; ++i) {
    source[i] = samples[i % dimension]
    source[pixels + i] = samples[Math.floor(i / dimension) % dimension]
    source[2 * pixels + i] = samples[Math.floor(i / (dimension * dimension))]
  }
  return source
}

function packRGBA(planes) {
  const bytes = new DataView(new ArrayBuffer(pixels * 8))
  for (let i = 0; i < pixels; ++i) {
    for (let c = 0; c < 3; ++c) {
      const value = planes[c * pixels + i]
      if (!Number.isFinite(value) || Math.abs(value) > 65504) throw new Error('Invalid output sample')
      bytes.setFloat16(i * 8 + c * 2, value, true)
    }
    bytes.setFloat16(i * 8 + 6, 1, true)
  }
  return new Uint8Array(bytes.buffer)
}

const source = chart()
const permutedSource = new Float32Array(source.length)
// 997 is coprime to 33³. Rearrange neighbours as well as absolute positions.
const positions = Array.from({ length: pixels }, (_, i) => (997 * i + 41) % pixels)
for (let c = 0; c < 3; c++) {
  for (let i = 0; i < pixels; i++) {
    permutedSource[c * pixels + positions[i]] = source[c * pixels + i]
  }
}

await mkdir(output, { recursive: true })
const stocks = []
for (const { id, name } of expected) {
  if (!/^[a-z0-9]+$/.test(id)) throw new Error('Unexpected stock identifier ' + id)
  const bytes = await readFile(join(input, 'packs', id + '.pack'))
  const pack = parsePack(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength))
  const developer = new SimdDeveloper(runtime, pack)
  let forward
  try {
    developer.tileBudget = Infinity
    developer.setFrame(width, height)
    withoutSpatialEffects(developer)
    forward = render(developer, source)
    const permuted = render(developer, permutedSource)
    for (let c = 0; c < 3; ++c) {
      for (let i = 0; i < pixels; ++i) {
        if (Math.abs(forward[c * pixels + i] - permuted[c * pixels + positions[i]]) > 1e-5) {
          throw new Error(id + ' still depends on pixel position or neighbouring colours')
        }
      }
    }
  } finally {
    developer.dispose()
  }
  const lut = packRGBA(forward)
  await writeFile(join(output, id + '.rgba16f'), lut)
  stocks.push({ id, name, sourceSHA256: sha256(bytes), lutSHA256: sha256(lut) })
  console.log(stocks.length + '/' + expected.length + ' ' + id)
}
await writeFile(join(output, 'catalogue.json'), JSON.stringify({ revision, dimension, stocks }, null, 2) + '\n')
