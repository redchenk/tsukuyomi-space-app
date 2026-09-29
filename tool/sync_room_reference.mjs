// Synchronize data-only Room defaults from the companion website repository.
// Run: node tool/sync_room_reference.mjs ../tsukuyomi-space
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
const root = path.resolve(process.argv[2] || '../tsukuyomi-space');
const read = p => fs.readFileSync(path.join(root, 'src/frontend', p), 'utf8');
const ctx = vm.createContext({});
function moduleData(file) {
  vm.runInContext(read(file).replace(/import[\s\S]*?from\s+['"][^'"]+['"];?/g, '').replace(/export\s+(?=(?:const|function))/g, ''), ctx);
}
moduleData('constants/room/behaviorActionRegistry.js');
// Materialize before other modules declare their own parameter() helper.
vm.runInContext('const exportedBehaviorActions = BEHAVIOR_ACTION_DEFINITIONS.map(a=>({id:a.id,bodyPose:a.bodyPose,defaultDurationMs:a.defaultDurationMs,parameters:a.parameters?a.parameters({intensity:1,durationMs:a.defaultDurationMs,delayMs:0,side:a.defaultSide}):[]}))',ctx);
moduleData('constants/room/yachiyoExpressionPresetRegistry.js');
moduleData('constants/room/live2dManifest.js');
moduleData('constants/room/knowledgeEntries.js');
moduleData('constants/room/musicTracks.js');
moduleData('constants/room/yachiyoModelParameterRegistry.js');
moduleData('services/room/live2dTrackingFrameMapper.js');
const page = read('pages/RoomSettingsPage.vue');
vm.runInContext(page.slice(page.indexOf('const LLM_PRESETS'), page.indexOf('const BEGINNER_LLM_PROVIDERS')), ctx);
const chat = read('composables/room/useRoomChat.js');
vm.runInContext(chat.slice(chat.indexOf('function fallbackRoomPersona()'),chat.indexOf('function applyRoomAct(')),ctx);
const result = vm.runInContext('JSON.stringify({chatPersona:fallbackRoomPersona(),chatProtocol:roomProtocolPrompt(),llmPresets:LLM_PRESETS,aliyunPresets:ALIYUN_LLM_PRESETS,mimoPresets:MIMO_LLM_PRESETS,ttsPresets:TTS_PRESETS,knowledge:DEFAULT_ROOM_KNOWLEDGE_ENTRIES,music:MUSIC_TRACKS,live2d:roomLive2DManifest,expressions:YACHIYO_EXPRESSION_PRESETS.map(p=>({...p,cubism:mapTrackingFrameToYachiyoCubismParameters(p.vts)})),actions:exportedBehaviorActions})', ctx);
fs.writeFileSync('lib/core/room_reference_data.dart', "// Generated from the website. Run tool/sync_room_reference.mjs to update.\nconst roomReferenceJson = r'''" + result + "''';\n");
console.log('Room presets, knowledge, music and Live2D manifests synchronized.');
