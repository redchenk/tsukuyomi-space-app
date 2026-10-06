import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
const root=path.resolve(process.argv[2] || '../tsukuyomi-space');
const ref=execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim();
const {packRoomContext,selectRecentRoomConversation}=await import(pathToFileURL(path.join(root,'src/frontend/services/room/roomContext.mjs')));
const expand=v=>Array.isArray(v)?v.map(expand):v&&typeof v==='object'?v.$segments?v.$segments.map(([s,n])=>s.repeat(n)).join(''):Object.fromEntries(Object.entries(v).map(([k,x])=>[k,expand(x)])):v;
for(const kind of ['context','conversation']) {
 const path=`test/fixtures/room_${kind}_web.json`,data=JSON.parse(fs.readFileSync(path,'utf8'));
 data.source=`tsukuyomi-space@${ref}/src/frontend/services/room/roomContext.mjs#${kind==='context'?'packRoomContext':'selectRecentRoomConversation'}`;
 for(const c of data.cases) {
  if(kind==='context') c.expected=packRoomContext(expand(c.sections),c.options);
  else c.expected=selectRecentRoomConversation(c.history.map(m=>({...m,content:m.contentSegments.map(([s,n])=>s.repeat(n)).join('')})),c.options).map(m=>({role:m.role,turnId:m.turnId,contentSegments:[[m.content,1]]}));
 }
 fs.writeFileSync(path,JSON.stringify(data,null,2)+'\n');
}
