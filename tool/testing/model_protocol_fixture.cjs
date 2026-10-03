// Test-only provider transport for the disposable website fixture. The real
// Express chat route, request validation and shared website decoder still run.
const assert = require('node:assert/strict');
const originalFetch = global.fetch;
const opaque = 'NATIVE_PROTOCOL_OPAQUE';
const args = '{"query":"月读空间"}';
const text = '资料核对完成。';
global.fetch = async (url, options = {}) => {
  let body;
  try { body = JSON.parse(options.body || '{}'); } catch { /* Other HTTP calls. */ }
  if (!String(body?.model || '').startsWith('native-protocol-fixture-')) return originalFetch(url, options);
  // Never contact an external provider with fixture credentials.
  const protocol = body.model.replace('native-protocol-fixture-', '');
  assert(['openai', 'responses', 'anthropic'].includes(protocol));
  const endpoint = String(url);
  assert(endpoint === ({openai:'https://api.deepseek.com/chat/completions', responses:'https://api.openai.com/v1/responses', anthropic:'https://api.anthropic.com/v1/messages'})[protocol]);
  const messages = protocol === 'responses' ? body.input : body.messages;
  const result = messages.find(item => item.role === 'tool' || item.type === 'function_call_output' || (item.role === 'user' && Array.isArray(item.content) && item.content.some(p => p.type === 'tool_result')));
  if (result) {
    assert(JSON.stringify(messages).includes(opaque));
    if (protocol === 'responses') { assert.equal(body.store, false); assert.equal(result.call_id, 'site_read1'); }
    else if (protocol === 'anthropic') assert.equal(result.content.find(p => p.type === 'tool_result').tool_use_id, 'site_read1');
    else assert.equal(result.tool_call_id, 'site_read1');
    assert(JSON.stringify(result).includes('原生 MCP 参考资料'));
  } else assert(body.tools.some(t => (t.name || t.function?.name) === 'web_search'));
  const sse = value => `data: ${JSON.stringify(value)}\r\n\r\n`;
  let wire;
  if (protocol === 'responses') {
    wire = sse({type:'response.output_text.delta',delta:result ? text : '先查看资料。'}) + sse({type:'response.completed',response:{status:'completed',output:[
      {type:'message',role:'assistant',content:[{type:'output_text',text:result ? text : '先查看资料。'}]},
      ...result ? [] : [{type:'reasoning',id:'reason1',encrypted_content:opaque},{type:'function_call',call_id:'site_read1',name:'web_search',arguments:args}],
    ],usage:{input_tokens:5,output_tokens:3}}});
  } else if (protocol === 'anthropic') {
    wire = sse({type:'content_block_start',index:0,content_block:{type:'text',text:''}}) + sse({type:'content_block_delta',index:0,delta:{type:'text_delta',text:result ? text : '先查看资料。'}});
    if (!result) wire += sse({type:'content_block_start',index:1,content_block:{type:'thinking',thinking:'private',signature:opaque}}) + sse({type:'content_block_start',index:2,content_block:{type:'tool_use',id:'site_read1',name:'web_search',input:JSON.parse(args)}});
    wire += sse({type:'message_delta',delta:{stop_reason:result ? 'end_turn' : 'tool_use'},usage:{output_tokens:3}}) + sse({type:'message_stop'});
  } else {
    wire = sse({choices:[{index:0,delta:{content:result ? text : '先查看资料。',...result ? {} : {reasoning_content:opaque,tool_calls:[{index:0,id:'site_read1',type:'function',function:{name:'web_search',arguments:args}}]}},finish_reason:result ? 'stop' : 'tool_calls'}]}) + sse({choices:[],usage:{prompt_tokens:5,completion_tokens:3}}) + 'data: [DONE]\r\n\r\n';
  }
  return new Response(new ReadableStream({async start(controller) {
    for (const frame of wire.split('\r\n\r\n').filter(Boolean)) {
      const bytes = new TextEncoder().encode(frame + '\r\n\r\n');
      for (let offset = 0; offset < bytes.length; offset += 7) controller.enqueue(bytes.slice(offset, offset + 7));
      await new Promise(resolve => setTimeout(resolve, 60));
    }
    controller.close();
  }}), {headers:{'content-type':'text/event-stream; charset=utf-8'}});
};
