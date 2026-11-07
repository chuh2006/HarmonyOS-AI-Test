// Device integration fixture only. Never imported by the application.
const http=require('node:http');
const fs=require('node:fs');
const log=process.env.MINICHAT_TEST_LOG||'/tmp/minichat-device-requests.jsonl';
const wait=ms=>new Promise(r=>setTimeout(r,ms));
const server=http.createServer(async(req,res)=>{
  let source='';for await(const b of req) source+=b;
  let body;try{body=JSON.parse(source);}catch{res.writeHead(400);return res.end('{}');}
  const authorized=[req.headers['x-api-key'],req.headers['authorization'],req.headers['x-goog-api-key']].some(x=>x==='minichat-test-key'||x==='Bearer minichat-test-key');
  const history=body.messages||body.input||body.contents||[];
  fs.appendFileSync(log,JSON.stringify({time:Date.now(),path:req.url,authorized,model:body.model,history,body})+'\n');
  if(!authorized){res.writeHead(401,{'content-type':'application/json'});return res.end('{"error":{"message":"Test credential missing after reload"}}');}
  if(req.url.includes('/tools/')){
    await wait(600);res.writeHead(200,{'content-type':'application/json'});
    return res.end(req.url.endsWith('/search')?JSON.stringify({results:[{title:'联调测试来源',url:'https://example.org',summary:'This complete summary is for the model only.',content:'Fixture reference text.'}]}):JSON.stringify({title:'联调网页',content:'Fixture page content.'}));
  }
  const lastUser=[...history].reverse().find(x=>x.role==='user'&&(typeof x.content==='string'||x.parts?.some(p=>p.text)));
  const text=typeof lastUser?.content==='string'?lastUser.content:lastUser?.parts?.map(p=>p.text||'').join('')||'';
  if(text.includes('error')) {res.writeHead(429,{'content-type':'application/json'});return res.end('{"error":{"message":"Integration rate limit fixture"}}');}
  res.writeHead(200,{'content-type':'text/event-stream','cache-control':'no-cache'});
  const send=async obj=>{if(res.destroyed)return;const buf=Buffer.from('data: '+JSON.stringify(obj)+'\r\n\r\n');const cut=Math.min(27,buf.length);res.write(buf.subarray(0,cut));await wait(10);res.write(buf.subarray(cut));await wait(text.includes('stop')?1800:320);};
  const hasTool=JSON.stringify(history).includes('functionResponse')||history.some(x=>x.type==='function_call_output'||x.role==='tool'||Array.isArray(x.content)&&x.content.some(c=>c.type==='tool_result'));
  const wantsTools=Boolean(body.tools)&&!hasTool;
  try {
    if(req.url.includes('/messages')){
      await send({type:'message_start',message:{usage:{input_tokens:5}}});
      await send({type:'content_block_start',index:0,content_block:{type:'thinking',thinking:'',signature:''}});
      await send({type:'content_block_delta',index:0,delta:{type:'thinking_delta',thinking:'先检查资料，再给出简洁回答。'}});
      await send({type:'content_block_delta',index:0,delta:{type:'signature_delta',signature:'device-deepseek-signature'}});
      await send({type:'content_block_stop',index:0});
      if(wantsTools){
        await send({type:'content_block_start',index:1,content_block:{type:'tool_use',id:'device-search',name:'search',input:{}}});
        await send({type:'content_block_delta',index:1,delta:{type:'input_json_delta',partial_json:'{"query":"Harmony'}});
        await send({type:'content_block_delta',index:1,delta:{type:'input_json_delta',partial_json:'OS"}'}});
        await send({type:'content_block_stop',index:1});
      }else{
        await send({type:'content_block_start',index:1,content_block:{type:'text',text:''}});
        for(const part of ['你好，','这是一条设备联调响应。\n','流式输出与历史恢复工作正常。']) await send({type:'content_block_delta',index:1,delta:{type:'text_delta',text:part}});
        await send({type:'content_block_stop',index:1});
      }
      await send({type:'message_delta',delta:{stop_reason:wantsTools?'tool_use':'end_turn'},usage:{output_tokens:28}});await send({type:'message_stop'});
    }else if(req.url.includes('/responses')){
      const reason={id:'r-device',type:'reasoning',summary:[{type:'summary_text',text:'检查上下文并继续。'}],encrypted_content:'device-encrypted-content'};
      await send({type:'response.output_item.added',output_index:0,item:{...reason,summary:[]}});
      await send({type:'response.reasoning_summary_text.delta',output_index:0,summary_index:0,delta:'检查上下文并继续。'});
      await send({type:'response.output_item.done',output_index:0,item:reason});
      const output=wantsTools?[reason,{type:'function_call',id:'f-device',call_id:'o-search',name:'search',arguments:'{"query":"OpenAI"}'}]:[reason,{type:'message',id:'m-device',role:'assistant',phase:'final_answer',status:'completed',content:[{type:'output_text',text:'OpenAI 设备流式联调完成。',annotations:[]}]}];
      if(!wantsTools){await send({type:'response.output_item.added',output_index:1,item:{...output[1],content:[]}});await send({type:'response.output_text.delta',output_index:1,content_index:0,delta:'OpenAI 设备'});await send({type:'response.output_text.delta',output_index:1,content_index:0,delta:'流式联调完成。'});}
      await send({type:'response.completed',response:{output,usage:{total_tokens:22}}});
    }else if(req.url.includes('/chat/completions')){
      if(wantsTools) await send({choices:[{index:0,delta:{tool_calls:[{index:0,id:'m-search',type:'function',function:{name:'search',arguments:'{"query":"Mercury"}'}}]},finish_reason:'tool_calls'}]});
      else{
        for(const content of body.diffusing?['这是未修订的草稿，正在生成……','短句重新成形。','扩散输出已完成。']:['普通','流式','输出已完成。']) await send({choices:[{index:0,delta:{content}}]});
        await send({choices:[{index:0,delta:{content:null},finish_reason:'stop'}]});
      }res.write('data: [DONE]\n\n');
    }else{
      await send({candidates:[{index:0,content:{role:'model',parts:[{text:'保留每个 Part 的签名。',thought:true}]}}]});
      if(wantsTools) await send({candidates:[{index:0,content:{role:'model',parts:[{functionCall:{id:'g-search',name:'search',args:{query:'Gemini'}},thoughtSignature:'device-function-signature'}]},finishReason:'STOP'}]});
      else{
        await send({candidates:[{index:0,content:{role:'model',parts:[{text:'Gemini 流式',thoughtSignature:'device-text-signature'}]}}]});
        await send({candidates:[{index:0,content:{role:'model',parts:[{text:'联调完成。'},{text:'',thoughtSignature:'device-empty-signature'}]},finishReason:'STOP'}]});
      }
    }
    res.end();
  }catch(error){res.destroy();}
});
server.listen(18765,'127.0.0.1',()=>console.log('MiniChat fixture listening on 127.0.0.1:18765'));
