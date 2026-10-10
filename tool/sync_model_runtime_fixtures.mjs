import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import {createRequire} from 'node:module';
import {execFileSync} from 'node:child_process';
const root=path.resolve(process.argv[2] || '../tsukuyomi-space');
const require=createRequire(import.meta.url), runtime=require(path.join(root,'shared/model-runtime.cjs')), catalog=require(path.join(root,'shared/model-catalog.cjs'));
const source=execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim();
const cases=[];
for(const [apiUrl,model] of [['https://api.deepseek.com/chat/completions','deepseek-chat'],['https://api.openai.com/v1/responses','gpt-5'],['https://api.anthropic.com/v1/messages','claude-sonnet'],['http://localhost:11434/api/chat','qwen3'],['https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions','qwen3']]) {
 for(const override of [false,true]) {
  const settings={apiUrl,model};const ids=runtime.scopes(settings);
  settings.runtimeConfig={version:1,providers:{[ids.provider]:{parameters:{temperature:.7,maxOutputTokens:2048}}},models:override?{[ids.model]:{parameters:{temperature:.2,maxOutputTokens:1024},capabilities:{streaming:false}}}:{}};
  const payload={model,stream:true,temperature:1,top_p:.9,max_tokens:8192,max_output_tokens:8192,options:{temperature:1,num_predict:8192}};
  cases.push({settings,payload,expected:runtime.applyParameters(payload,settings).payload,capabilities:runtime.resolveCapabilities(settings)});
 }
}
const plans=[];
for(const [provider,spec] of Object.entries(catalog.PROVIDERS)) {
 for(const host of spec.hosts) {
  const input={apiUrl:`https://${host}/v1/chat/completions`,apiKey:'fixture-key',workspaceId:'workspace-test'};
  try {plans.push({input,expected:catalog.catalogPlan(input)})} catch(e) {plans.push({input,error:e.code})}
 }
}
const catalogCases=[];
for(const provider of ['openai','openrouter','mistral','together','gemini','aliyun']) {
 const rows=[{id:'chat-model',name:'models/gemini-example',type:'chat',supportedGenerationMethods:['generateContent'],capabilities:{vision:true,function_calling:false,streaming:true}}, {id:'text-embedding-small',name:'models/text-embedding-small',supportedGenerationMethods:['embedContent']},{id:'image-generation',name:'models/image-generation',supportedGenerationMethods:['generateContent'],output_modalities:['image']},{id:'second-model',name:'models/gemini-second',type:'chat',supportedGenerationMethods:['generateContent'],architecture:{input_modalities:['text','image']},supported_parameters:['tools']}, {id:'chat-model',name:'models/gemini-example',type:'chat'}];
 const payload=provider==='gemini'?{models:rows,nextPageToken:'next'}:provider==='aliyun'?{output:{models:rows,total:200}}:{data:rows};
 const expected=catalog.normalizePage(payload,{provider},'');
 catalogCases.push({provider,payload,expected});
}
fs.writeFileSync('test/fixtures/model_runtime_web.json',JSON.stringify({source,cases,plans,catalogCases},null,2)+'\n');
const ctx=vm.createContext({});
for(const file of ['constants/room/knowledgeEntries.js','services/room/roomKnowledge.js']) {
 const code=fs.readFileSync(path.join(root,'src/frontend',file),'utf8').replace(/import[\s\S]*?from\s+['"][^'"]+['"];?/g,'').replace(/export\s+(?=(?:const|function))/g,'');
 vm.runInContext(code,ctx);
}
const knowledge=vm.runInContext(`JSON.stringify(['你好','今天工作好累','八千代喜欢吃什么','电影中的 Remember 是谁写的','小说中的八千代与辉夜是什么关系，我已看完','别剧透，电影中的不死是谁','八千代说话的口吻示例','那她后来怎么样','ヤチヨと彩葉','电影中５２小时是什么'].map(message=>{const recentMessages=[{role:'user',content:'小说中八千代经历了什么'}]; const selected=selectRoomKnowledgeEntries(message,{},10,{recentMessages});return {message,history:recentMessages,ids:selected.map(v=>v.id),persona:shouldRetrieveRoomPersona(roomKnowledgeQuery(message,recentMessages),selected)}}))`,ctx);
const migrations=vm.runInContext(`JSON.stringify([LEGACY_ROOM_KNOWLEDGE_ENTRIES,[],DEFAULT_ROOM_KNOWLEDGE_ENTRIES.slice(0,2),LEGACY_ROOM_KNOWLEDGE_ENTRIES.map((v,i)=>i===0?{...v,content:'我自定义的身份'}:v)].map(entries=>({entries,expected:normalizeRoomKnowledge({entries}).entries})))`,ctx);
fs.writeFileSync('test/fixtures/room_knowledge_web.json',JSON.stringify({source,cases:JSON.parse(knowledge),migrations:JSON.parse(migrations)},null,2)+'\n');
