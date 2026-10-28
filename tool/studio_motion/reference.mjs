// Reference frames use native ESM from the unchanged Studio sources, not our bundle.
// node --experimental-vm-modules tool/studio_motion/reference.mjs [--check]
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const context = vm.createContext({console});
const modules = new Map();
function sourceModule(file) {
  if (modules.has(file)) return modules.get(file);
  const module = new vm.SourceTextModule(fs.readFileSync(file, 'utf8'), {context, identifier: file});
  modules.set(file, module);
  return module;
}
const entry = sourceModule(path.join(root, 'tool/studio_motion/entry.js'));
await entry.link((specifier, module) => {
  let file = path.resolve(path.dirname(module.identifier), specifier);
  if (!path.extname(file)) file += '.js';
  return sourceModule(file);
});
await entry.evaluate();
const bundled = vm.createContext({console});
vm.runInContext(fs.readFileSync(path.join(root, 'assets/live2d/studio-motion.js'), 'utf8'), bundled);
const fixture = [];
const clone = value => JSON.parse(JSON.stringify(value));
function command(input, capture = true) {
  const expected = clone(context.__studioInvoke(clone(input)));
  assert.deepEqual(clone(bundled.__studioInvoke(clone(input))), expected, 'bundle differs from original Studio ESM');
  fixture.push({input, ...(capture ? {expected} : {})});
}
command({kind: 'reset', seed: 919, now: 1000});
for (let frame = 0; frame < 900; frame++) {
  const now = 1000 + frame * (1000/60);
  if (frame === 60) command({kind: 'state', now, value: {mode: 'thinking'}});
  if (frame === 150) command({kind: 'state', now, value: {mode: 'idle'}});
  if (frame === 180 || frame === 260) command({kind: 'act', now, value: {
    expression: 'happy', source: 'streaming-speech', durationMs: 1800,
    behaviorActions: [{type: frame === 180 ? 'nod' : 'sway', durationMs: 1600, intensity: .7}],
  }});
  if (frame === 420) command({kind: 'act', now, value: {
    expression: 'thinking', durationMs: 1300, priority: 80,
    behaviorActions: [{type: 'head_tilt', durationMs: 1300, intensity: .8}],
    interruptPolicy: {mode: 'protect', minHoldMs: 900},
  }});
  if (frame === 430 || frame === 450) command({kind: 'act', now, value: {
    expression: 'surprised', durationMs: 1600, priority: 10,
    behaviorActions: [{type: 'bounce', durationMs: 1500, intensity: .9}],
    interruptPolicy: {mode: frame === 430 ? 'blend' : 'replace'},
  }});
  if (frame === 560) command({kind: 'act', now, value: {
    expression: 'wink', durationMs: 1000,
    parameters: [{id: 'ParamAngle_HeadX', value: -15, weight: .8, durationMs: 800}],
  }});
  if (frame === 660) command({kind: 'reset', now, seed: 919});
  command({kind: 'frame', now, mouth: frame >= 180 && frame < 380 ? Math.max(0, Math.sin(frame * .8)) * .7 : 0},
    frame % 30 === 0 || [179,181,259,261,379,421,431,451,561,659,661,899].includes(frame));
}
const output = path.join(root, 'test/fixtures/studio_motion_reference.json');
const text = JSON.stringify({sourceCommit: '7cfc08a328be332d3b876a4257e74f8411f08d5f', frames: fixture}) + '\n';
if (process.argv.includes('--check')) assert.equal(fs.readFileSync(output, 'utf8'), text, 'reference fixture is stale');
else fs.writeFileSync(output, text);
console.log(`Studio reference: ${fixture.length} commands; original ESM and bundled frames match exactly`);
