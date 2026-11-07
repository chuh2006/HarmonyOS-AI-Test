const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { load, setNetwork, assets, fileIo } = require('./arkts.cjs');
const { J } = load('core/Json.ets');
const { SseParser, SseEvent } = load('core/Sse.ets');
const { Options, Turn, Session, Archive, Segment, MODELS, normalizeOptions, defaultProviders } = load('core/Models.ets');
const { ProviderRound, buildRequest, toolReplies, ToolCall } = load('core/Protocols.ets');
const { Cancellation, RequestSpec, HttpTransport } = load('services/Network.ets');
const { WebTools } = load('services/WebTools.ets');
const { ChatEngine } = load('services/ChatEngine.ets');
const { Store, Vault } = load('services/Store.ets');
const event = data => new SseEvent('', typeof data === 'string' ? data : JSON.stringify(data));
function makeRound(model, diffusing = true) {
  const options = new Options(); options.model = model; options.diffusing = diffusing;
  const turn = new Turn(); const round = new ProviderRound(options, turn, () => {});
  return { round, turn, emit: data => round.event(event(data)) };
}
const textOf = turn => turn.segments.filter(s => s.kind === 'text').map(s => s.text).join('|');
function ds(emit, text='你好', tools=[]) {
  emit({type:'message_start',message:{usage:{input_tokens:3}}});
  emit({type:'content_block_start',index:0,content_block:{type:'thinking',thinking:'',signature:''}});
  emit({type:'content_block_delta',index:0,delta:{type:'thinking_delta',thinking:'先查证'}});
  emit({type:'content_block_delta',index:0,delta:{type:'signature_delta',signature:'opaque-signature'}});
  emit({type:'content_block_stop',index:0});
  emit({type:'content_block_start',index:1,content_block:{type:'text',text:''}});
  emit({type:'content_block_delta',index:1,delta:{type:'text_delta',text}});
  emit({type:'content_block_stop',index:1});
  tools.forEach((t,i) => {
    emit({type:'content_block_start',index:i+2,content_block:{type:'tool_use',id:t.id,name:t.name,input:{}}});
    const args=JSON.stringify(t.args); const n=Math.floor(args.length/2);
    emit({type:'content_block_delta',index:i+2,delta:{type:'input_json_delta',partial_json:args.slice(0,n)}});
    emit({type:'content_block_delta',index:i+2,delta:{type:'input_json_delta',partial_json:args.slice(n)}});
    emit({type:'content_block_stop',index:i+2});
  });
  emit({type:'message_delta',delta:{stop_reason:tools.length?'tool_use':'end_turn'},usage:{output_tokens:12}});
  emit({type:'message_stop'});
}
function fakeConnection(chunks, status=200, reverse=false, delay=0) {
  const handlers={}; let dead=false;
  return { on(name,fn) { handlers[name]=fn; }, destroy() { dead=true; }, get dead(){return dead;},
    requestInStream() { return new Promise(resolve => {
      if (reverse) resolve(status);
      let i=0;
      const next=()=>{
        if(dead) return;
        if(i<chunks.length) { const b=Buffer.from(chunks[i++]); handlers.dataReceive(b.buffer.slice(b.byteOffset,b.byteOffset+b.length)); setTimeout(next,delay); }
        else { handlers.dataEnd(); if(!reverse) resolve(status); }
      }; setTimeout(next,0);
    }); }
  };
}
const request = () => new RequestSpec('https://example.test', {'Authorization':'Bearer TEST_SECRET'}, '{}');

test('SSE: every split boundary, CRLF, comments, multiline, final buffer',()=>{
  const wire='\uFEFF: keepalive\r\nevent: chunk\r\ndata: 一\r\ndata: 二\r\n\r\ndata: final';
  for(let split=0;split<=wire.length;split++) {
    const out=[]; const parser=new SseParser(e=>out.push(e)); parser.push(wire.slice(0,split)); parser.push(wire.slice(split)); parser.finish();
    assert.deepEqual(out.map(e=>[e.event,e.data]),[['chunk','一\n二'],['','final']]);
  }
});
test('HTTP: real decoder survives every byte boundary and emits before end',async()=>{
  const bytes=Buffer.from('data: {"text":"你好🌱"}\r\n\r\ndata: [DONE]');
  let connection; setNetwork(()=>connection=fakeConnection(Array.from(bytes,b=>Buffer.from([b])),200,true));
  const out=[]; await new HttpTransport().stream(request(),new Cancellation(),e=>{out.push(e.data); assert.equal(connection.dead,false);});
  assert.deepEqual(out,['{"text":"你好🌱"}','[DONE]']); assert.equal(connection.dead,true);
});
test('HTTP: status arriving after dataEnd is respected and secret is redacted',async()=>{
  setNetwork(()=>fakeConnection(['{"error":{"message":"TEST_SECRET invalid"}}'],401,false));
  await assert.rejects(new HttpTransport().stream(request(),new Cancellation(),()=>{}),e=>/401/.test(e.message)&&!e.message.includes('TEST_SECRET'));
});
test('HTTP: cancellation settles immediately and destroys a silent connection',async()=>{
  let destroyed=false; setNetwork(()=>({on(){},destroy(){destroyed=true;},requestInStream(){return new Promise(()=>{});}}));
  const token=new Cancellation(); const promise=new HttpTransport().stream(request(),token,()=>{}); token.cancel();
  await assert.rejects(promise,/已停止/); assert.equal(destroyed,true);
});
test('DeepSeek: fragmented tools preserve thinking, signatures, IDs and result order',()=>{
  const {round,turn,emit}=makeRound('deepseek-flash');
  ds(emit,'先查询',[{id:'a',name:'search',args:{query:'测试'}},{id:'b',name:'fetch',args:{url:'https://example.org'}}]);
  const calls=round.finish(); assert.equal(calls.length,2); assert.equal(JSON.parse(calls[0].arguments).query,'测试');
  const output=round.output()[0].value;
  assert.equal(output.content[0].signature,'opaque-signature'); assert.equal(output.content[0].thinking,'先查证');
  assert.equal(textOf(turn),'先查询'); assert.equal(turn.usage.length,2);
  const replies=toolReplies('deepseek',calls.map(call=>({call,output:'{"ok":true}',failed:false})));
  assert.deepEqual(replies[0].value.content.map(p=>p.tool_use_id),['a','b']);
});
test('DeepSeek: truncated stream and incomplete tool JSON fail with partial text retained',()=>{
  const {round,turn,emit}=makeRound('deepseek-flash');
  emit({type:'content_block_start',index:0,content_block:{type:'text',text:'已有内容'}});
  assert.throws(()=>round.finish(),/提前结束/); assert.equal(textOf(turn),'已有内容');
  emit({type:'content_block_start',index:1,content_block:{type:'tool_use',id:'a',name:'search',input:{}}});
  emit({type:'content_block_delta',index:1,delta:{type:'input_json_delta',partial_json:'{"query":'}});
  assert.throws(()=>emit({type:'content_block_stop',index:1}),/完整 JSON/);
});
test('OpenAI: encrypted reasoning and assistant phase survive final output and disk serialization',()=>{
  const {round,turn,emit}=makeRound('gpt-6-astra');
  emit({type:'response.output_item.added',output_index:0,item:{id:'r1',type:'reasoning',summary:[]}});
  emit({type:'response.reasoning_summary_text.delta',output_index:0,summary_index:0,delta:'先思考'});
  emit({type:'response.output_item.done',output_index:0,item:{id:'r1',type:'reasoning',summary:[{type:'summary_text',text:'先思考'}],encrypted_content:'opaque-A'}});
  emit({type:'response.output_item.added',output_index:1,item:{id:'m1',type:'message',role:'assistant',phase:'final_answer',content:[]}});
  emit({type:'response.output_text.delta',output_index:1,content_index:0,delta:'答案'});
  const output=[{id:'r1',type:'reasoning',summary:[{type:'summary_text',text:'先思考'}],encrypted_content:'opaque-A'},
    {id:'m1',type:'message',role:'assistant',phase:'final_answer',status:'completed',content:[{type:'output_text',text:'答案',annotations:[]}]}];
  emit({type:'response.completed',response:{output,usage:{output_tokens:10}}});
  assert.deepEqual(round.finish(),[]); assert.equal(textOf(turn),'答案');
  assert.deepEqual(JSON.parse(JSON.stringify(round.output().map(j=>j.value))),output);
  assert.equal(turn.segments.filter(s=>s.kind==='thought')[0].text,'先思考');
});
test('OpenAI: interleaved tool arguments are correlated by output_index',()=>{
  const {round,emit}=makeRound('gpt-6.1-sol');
  for(let i=0;i<2;i++) emit({type:'response.output_item.added',output_index:i,item:{type:'function_call',call_id:'c'+i,name:'search',arguments:''}});
  for(let i=1;i>=0;i--) emit({type:'response.function_call_arguments.delta',output_index:i,delta:'{"query":"q'+i+'"}'});
  emit({type:'response.completed',response:{}});
  const calls=round.finish(); assert.deepEqual(calls.map(c=>JSON.parse(c.arguments).query),['q0','q1']);
  assert.deepEqual(toolReplies('openai',calls.map(call=>({call,output:'{}',failed:false}))).map(j=>j.value.call_id),['c0','c1']);
});
test('OpenAI: incomplete response retains final partial output and reports reason',()=>{
  const {round,turn,emit}=makeRound('gpt-6-astra');
  emit({type:'response.incomplete',response:{output:[{type:'message',role:'assistant',content:[{type:'output_text',text:'partial'}]}],incomplete_details:{reason:'max_output_tokens'}}});
  assert.throws(()=>round.finish(),/max_output_tokens/); assert.equal(textOf(turn),'partial');
});
test('Mercury: diffusion revises prefix and length, finish-only event keeps final frame',()=>{
  const {round,turn,emit}=makeRound('mercury-3');
  for(const text of ['long wrong text','短','正确的最终文本']) emit({choices:[{index:0,delta:{content:text}}]});
  emit({choices:[{index:0,delta:{content:''},finish_reason:'stop'}]}); emit({choices:[],usage:{total_tokens:4}}); emit('[DONE]');
  assert.deepEqual(round.finish(),[]); assert.equal(textOf(turn),'正确的最终文本'); assert.equal(round.output()[0].value.content,'正确的最终文本');
});
test('Mercury: regular streaming appends instead of replacing',()=>{
  const {round,turn,emit}=makeRound('mercury-3',false);
  emit({choices:[{delta:{content:'你'}}]}); emit({choices:[{delta:{content:'好'},finish_reason:'stop'}]});
  round.finish(); assert.equal(textOf(turn),'你好');
});
test('Gemini: preserve original Parts and every signature including empty text',()=>{
  const {round,turn,emit}=makeRound('gemini-4-argon');
  const parts=[{text:'思考',thought:true},{text:'答',thoughtSignature:'sig1'},
    {functionCall:{id:'fc1',name:'search',args:{query:'A'}},thoughtSignature:'sig2'},
    {functionCall:{id:'fc2',name:'search',args:{query:'B'}}},{text:'',thoughtSignature:'sig3'}];
  for(const part of parts) emit({candidates:[{index:0,content:{role:'model',parts:[part]}}]});
  emit({candidates:[{index:0,finishReason:'STOP'}],usageMetadata:{totalTokenCount:9}});
  const calls=round.finish(); assert.equal(calls.length,2);
  assert.deepEqual(round.output()[0].value.parts,parts); assert.equal(textOf(turn),'答');
  const replies=toolReplies('gemini',calls.map(call=>({call,output:'{"results":[]}',failed:false})))[0].value;
  assert.deepEqual(replies.parts.map(p=>p.functionResponse.id),['fc1','fc2']);
});
test('Gemini: empty thought summary completes; safety block produces specific error',()=>{
  const normal=makeRound('gemini-3.8-flash'); normal.emit({candidates:[{content:{parts:[{text:'ok'}]},finishReason:'STOP'}]}); normal.round.finish();
  const blocked=makeRound('gemini-4-argon'); blocked.emit({promptFeedback:{blockReason:'SAFETY'}}); assert.throws(()=>blocked.round.finish(),/SAFETY/);
});
test('Requests: actual capabilities, stateless Responses, authentication, endpoints',()=>{
  for(const model of MODELS) {
    const options=new Options(); options.model=model.id; options.effort='none'; options.tier='ultrafast'; normalizeOptions(options);
    const config=defaultProviders().find(p=>p.id===model.provider); const req=buildRequest(options,config,'FAKE',[],true); const body=JSON.parse(req.body);
    assert.ok(model.efforts.includes(options.effort));
    if(model.provider==='openai') { assert.equal(body.store,false); assert.ok(body.include.includes('reasoning.encrypted_content')); assert.equal(body.reasoning.summary,'auto'); assert.ok(!('previous_response_id' in body)); }
    if(model.provider==='gemini') { assert.equal(body.generationConfig.thinkingConfig.includeThoughts,true); assert.equal(body.generationConfig.thinkingConfig.thinkingLevel,'medium'); assert.equal(req.headers['x-goog-api-key'],'FAKE'); }
    if(model.provider==='deepseek') { assert.ok(req.url.endsWith('/anthropic/v1/messages')); assert.equal(body.thinking.type,'disabled'); assert.ok(!body.output_config); }
    if(model.provider==='mercury') { assert.equal(body.diffusing,true); assert.equal(body.reasoning_effort,'medium'); }
  }
});
test('Tools: bounded parallel execution, stable order, once-only IDs, compact display',async()=>{
  let active=0,peak=0,total=0;
  const transport={async json(req){active++;peak=Math.max(peak,active);total++;const query=JSON.parse(req.body).query;
    await new Promise(r=>setTimeout(r,query==='slow'?20:2));active--;return J.parse(JSON.stringify({results:[{title:'source',url:'https://example.org',summary:'PRIVATE FULL SUMMARY',content:'body'}]}));}};
  const tools=new WebTools(transport,'FAKE','https://api.deepseek.com/anthropic',new Cancellation(),()=>{});
  const calls=['slow','fast','third','fourth','fifth'].map((q,i)=>new ToolCall('id'+i,'search',JSON.stringify({query:q}),new Segment()));
  const results=await tools.run(calls,0); assert.equal(peak,4); assert.equal(total,5); assert.deepEqual(results.map(r=>r.call.id),calls.map(c=>c.id));
  assert.ok(results[0].output.includes('PRIVATE FULL SUMMARY')); assert.ok(!JSON.stringify(calls[0].segment).includes('PRIVATE FULL SUMMARY'));
  await tools.run([calls[0]],1); assert.equal(total,5);
  await assert.rejects(tools.run([new ToolCall('id0','fetch','{}',new Segment())],2),/不同参数/);
});
test('Tools: invalid arguments and HTTP failures become protocol errors for the model',async()=>{
  const transport={async json(){throw new Error('HTTP 429 FAKE');}};
  const tools=new WebTools(transport,'FAKE','https://api.deepseek.com/anthropic',new Cancellation(),()=>{});
  const results=await tools.run([new ToolCall('a','search','{"query":"x"}',new Segment()),new ToolCall('b','fetch','{"url":"https://user:pass@example.org"}',new Segment())],0);
  assert.ok(results.every(r=>r.failed)); assert.ok(!results[0].output.includes('FAKE'));
  assert.equal(toolReplies('deepseek',results)[0].value.content[0].is_error,true);
});
for(const model of ['deepseek-flash','gpt-6-astra','mercury-3','gemini-4-argon']) {
  test(`Engine: ${model} multi-round parallel tools and history replay`,async()=>{
    const archive=new Archive(),session=new Session(); session.options.model=model; archive.sessions=[session]; archive.active=session.id;
    let n=0; const requests=[];
    const transport={async stream(req,token,onEvent) {
      requests.push(JSON.parse(req.body)); const emit=d=>onEvent(event(d)); const step=n++;
      const tool=step<2; const id='call'+step;
      if(model==='deepseek-flash') ds(emit,tool?'查询中':'最终回答',tool?[{id,name:'search',args:{query:'q'+step}}]:[]);
      else if(model==='gpt-6-astra') emit({type:'response.completed',response:{output:tool?
        [{type:'reasoning',encrypted_content:'enc'+step,summary:[]},{type:'function_call',id:'item'+step,call_id:id,name:'search',arguments:JSON.stringify({query:'q'+step})}]:
        [{type:'message',role:'assistant',phase:'final_answer',content:[{type:'output_text',text:'最终回答'}]}]}});
      else if(model==='mercury-3') {
        emit({choices:[{delta:{content:tool?'阶段'+step:'最终回答',...(tool?{tool_calls:[{index:0,id,type:'function',function:{name:'search',arguments:JSON.stringify({query:'q'+step})}}]}:{})},finish_reason:tool?'tool_calls':'stop'}]});
      } else emit({candidates:[{content:{role:'model',parts:tool?[{functionCall:{id,name:'search',args:{query:'q'+step}},thoughtSignature:'sig'+step}]:[{text:'最终回答',thoughtSignature:'final'}]},finishReason:'STOP'}]});
    },async json(){return J.parse('{"results":[]}');}};
    const engine=new ChatEngine(()=>{},()=>{},transport,{async read(){return 'FAKE';}});
    await engine.send(archive,session,'查一下');
    assert.equal(session.turns[0].status,'completed'); assert.equal(n,3); assert.ok(textOf(session.turns[0]).endsWith('最终回答'));
    assert.equal(session.turns[0].segments.filter(s=>s.kind==='tool').length,2);
    assert.ok(session.turns[0].segments.filter(s=>s.kind==='tool').every(s=>s.state==='completed'));
    const restored=JSON.parse(JSON.stringify(archive)); await engine.send(restored,restored.sessions[0],'继续');
    const history=requests[3].messages||requests[3].input||requests[3].contents;
    assert.ok(JSON.stringify(history).includes('最终回答'));
    if(model==='gpt-6-astra') assert.ok(JSON.stringify(history).includes('enc1'));
    if(model==='gemini-4-argon') assert.ok(JSON.stringify(history).includes('sig1'));
  });
}
test('Engine: no DeepSeek key disables definitions without blocking another provider',async()=>{
  const archive=new Archive(), session=new Session(); session.options.model='gpt-6-luna'; archive.sessions=[session];
  const transport={async stream(req,token,emit){assert.equal(JSON.parse(req.body).tools,undefined);emit(event({type:'response.completed',response:{output:[{type:'message',role:'assistant',content:[{type:'output_text',text:'hi'}]}]}}));}};
  await new ChatEngine(()=>{},()=>{},transport,{async read(p){return p==='deepseek'?'':'FAKE';}}).send(archive,session,'hi');
  assert.equal(session.turns[0].status,'completed');assert.equal(session.turns[0].segments[0].kind,'notice');
});
test('Engine: stopping during a tool aborts subsequent requests, late callbacks never cross sessions',async()=>{
  const archive=new Archive(),a=new Session(),b=new Session();archive.sessions=[a,b]; archive.active=a.id;
  let started;const ready=new Promise(r=>started=r);let requests=0;
  const transport={async stream(req,token,emit){requests++;ds(d=>emit(event(d)),'partial',[{id:'x',name:'search',args:{query:'test'}}]);},
    async json(req,token){started();await new Promise((resolve,reject)=>token.add(()=>reject(new Error('cancel'))));}};
  const engine=new ChatEngine(()=>{},()=>{},transport,{async read(){return 'FAKE';}});
  const pending=engine.send(archive,a,'a');await ready;archive.active=b.id;engine.stop(a);await pending;
  assert.equal(a.turns[0].status,'stopped'); assert.equal(b.turns.length,0); assert.equal(requests,1);assert.equal(engine.busy(a),false);
});
test('Engine: loop limit bounds tool executions and retains completed exchanges',async()=>{
  const archive=new Archive(),s=new Session();archive.sessions=[s];let requests=0,tools=0;
  const transport={async stream(req,token,emit){ds(d=>emit(event(d)),'',[{id:'x'+requests++,name:'search',args:{query:'x'}}]);},async json(){tools++;return J.parse('{"results":[]}');}};
  await new ChatEngine(()=>{},()=>{},transport,{async read(){return 'FAKE';}}).send(archive,s,'loop');
  assert.equal(requests,9);assert.equal(tools,8);assert.equal(s.turns[0].status,'failed');assert.match(s.turns[0].error,/上限/);
});
test('Store: oversized Unicode history, protocol signatures, process reload and interrupted state',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'minichat-test-'));
  try{
    const archive=new Archive(),s=new Session(),t=new Turn();t.user='长消息'.repeat(10000);t.replay=['{"encrypted_content":"opaque","parts":[{"thoughtSignature":"sig"}]}'];s.turns=[t];archive.sessions=[s];archive.active=s.id;
    new Store(dir).save(archive);const restored=new Store(dir).load();assert.equal(restored.sessions[0].turns[0].user,t.user);assert.equal(restored.sessions[0].turns[0].status,'stopped');assert.deepEqual(restored.sessions[0].turns[0].replay,t.replay);
    const before=fs.readFileSync(path.join(dir,'conversations.json'));const write=fileIo.writeSync;fileIo.writeSync=()=>{throw new Error('disk full');};
    try{assert.throws(()=>new Store(dir).save(archive),/disk full/);}finally{fileIo.writeSync=write;}
    assert.deepEqual(fs.readFileSync(path.join(dir,'conversations.json')),before);
  }finally{fs.rmSync(dir,{recursive:true,force:true});}
});
test('Vault: first save, overwrite, fresh instance lookup and removal',async()=>{
  assets.clear();const v=new Vault();assert.equal(await v.read('openai'),'');await v.write('openai','FAKE-A');assert.equal(await new Vault().read('openai'),'FAKE-A');
  await v.write('openai','FAKE-B');assert.equal(await v.read('openai'),'FAKE-B');await v.write('openai','');assert.equal(await v.read('openai'),'');
});
test('Store: damaged primary recovers backup and accepts the next atomic save',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'minichat-recovery-'));
  try{
    const a=new Archive(),s=new Session();a.sessions=[s];a.active=s.id;const store=new Store(dir);store.save(a);s.title='second';store.save(a);
    fs.writeFileSync(path.join(dir,'conversations.json'),'{bad');const recovered=new Store(dir);const data=recovered.load();
    assert.match(recovered.recoveryNotice,/备份/);assert.equal(data.sessions[0].title,'新对话');
    recovered.save(data);assert.equal(new Store(dir).load().sessions[0].id,s.id);assert.ok(fs.readdirSync(dir).some(f=>f.includes('.damaged-')));
  }finally{fs.rmSync(dir,{recursive:true,force:true});}
});
test('Engine: retry reuses the user turn and replaces failed protocol output',async()=>{
  const archive=new Archive(),s=new Session();archive.sessions=[s];let fail=true;
  const transport={async stream(req,token,emit){if(fail)throw new Error('test outage');ds(d=>emit(event(d)),'recovered');},async json(){return J.parse('{}');}};
  const engine=new ChatEngine(()=>{},()=>{},transport,{async read(){return 'FAKE';}});
  await engine.send(archive,s,'original');assert.equal(s.turns[0].status,'failed');fail=false;await engine.send(archive,s,'',true);
  assert.equal(s.turns.length,1);assert.equal(s.turns[0].status,'completed');assert.equal(textOf(s.turns[0]),'recovered');assert.equal(s.turns[0].error,'');
});
test('Gemini: interleaved thought, answer and call display order matches Part order',()=>{
  const {round,turn,emit}=makeRound('gemini-4-argon');
  for(const part of [{text:'first',thought:true},{text:'answer1'},{text:'second',thought:true},{functionCall:{name:'search',args:{query:'q'}},thoughtSignature:'s'},{text:'answer2'}])
    emit({candidates:[{content:{parts:[part]}}]});
  emit({candidates:[{finishReason:'STOP'}]});round.finish();
  assert.deepEqual(turn.segments.map(s=>s.kind),['thought','text','thought','tool','text']);
  assert.equal(turn.segments[4].text,'answer2');
});
test('Mercury: an explicit empty intermediate frame can revise text to zero length',()=>{
  const {round,turn,emit}=makeRound('mercury-3');
  emit({choices:[{delta:{content:'draft'}}]});emit({choices:[{delta:{content:''}}]});assert.equal(textOf(turn),'');
  emit({choices:[{delta:{content:'final'}}]});emit({choices:[{delta:{},finish_reason:'stop'}]});round.finish();assert.equal(textOf(turn),'final');
});
test('Fetch: successful Markdown is returned to the model and compact source metadata to the UI',async()=>{
  let sent;const transport={async json(req){sent=req;return J.parse(JSON.stringify({title:'Article',content:'x'.repeat(65000)}));}};
  const tools=new WebTools(transport,'FAKE','https://example.org/anthropic/v1/messages',new Cancellation(),()=>{});
  const call=new ToolCall('fetch-1','fetch','{"url":"https://example.net/article"}',new Segment());const [result]=await tools.run([call],0);
  assert.equal(sent.url,'https://example.org/v1/tools/fetch');assert.deepEqual(JSON.parse(sent.body),{url:'https://example.net/article'});
  assert.equal(JSON.parse(result.output).content.length,64000);assert.equal(JSON.parse(result.output).content_truncated,true);
  assert.equal(call.segment.detail,'Article');assert.deepEqual(call.segment.links,['https://example.net/article']);assert.equal(call.segment.state,'completed');
});
