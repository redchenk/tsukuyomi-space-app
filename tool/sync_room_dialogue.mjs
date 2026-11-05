// Policy and behavioural cases have one source; Dart must match every JS plan.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
const root = path.resolve(process.argv[2] || '../tsukuyomi-space');
const require = createRequire(import.meta.url);
const engine = require(path.join(root, 'shared/room-dialogue.cjs'));
const source = path.join(root, 'tests/fixtures/room-dialogue-cases.json');
const suite = JSON.parse(fs.readFileSync(fs.existsSync(source) ? source : 'test/fixtures/room_dialogue_web.json', 'utf8'));
for (const [id, message] of [['repair-request','你误会我的意思了'],['recall-request','还记得我们上次聊的吗'],['affection-request','想你了'],['praise-request','你说得真好']]) {
  if (!suite.cases.some(item => item.id === id)) suite.cases.push({id, input:{message}});
}
fs.writeFileSync('test/fixtures/room_dialogue_web.json', JSON.stringify({
  version: engine.policy.version, now: suite.now,
  cases: suite.cases.map(item => ({ ...item, expect: item.expect || {}, expected: engine.plan({ ...item.input, now: suite.now }) }))
}, null, 2) + '\n');
console.log(`${suite.cases.length} dialogue contracts synchronized.`);
