/**
 * Inception Mercury adapter - Chat Completions API (streaming + diffusion).
 * Endpoint: {base}/v1/chat/completions
 *
 * In diffusion mode every frame carries the full current draft of the active
 * generation phase, so frames replace the text of the block being generated
 * instead of appending. Plain streaming frames append. Tool calls bracket the
 * generation phases so later drafts never overwrite earlier phases.
 */
import { ProviderAdapter, RequestSpec, TurnHandler, TurnSink, trimSlash } from './Adapter';
import { Block, Msg, Session, BLOCK_TOOL, BLOCK_TEXT } from './Types';
import { asArr, asRecord, getArr, getBool, getObj, getStr, hasBool, hasKey, parseObj } from '../common/JsonUtil';
import { ToolRunner } from './Tools';

function parseJsonArray(text: string): Object[] {
  if (text.length === 0) {
    return [];
  }
  try {
    const v: Object | null = JSON.parse(text);
    if (v === null) {
      return [];
    }
    return asArr(v);
  } catch (e) {
    return [];
  }
}

function endpointOf(baseUrl: string): string {
  const b: string = trimSlash(baseUrl);
  if (b.endsWith('/chat/completions')) {
    return b;
  }
  return b + '/v1/chat/completions';
}

class McToolAcc {
  index: number = 0;
  callId: string = '';
  name: string = '';
  args: string = '';
  ended: boolean = false;
}

function synthesizeAssistant(msg: Msg): Object {
  let text: string = '';
  for (let i = 0; i < msg.blocks.length; i++) {
    const b: Block = msg.blocks[i];
    if (b.kind === BLOCK_TEXT) {
      text += b.text;
    }
  }
  const rec: Record<string, Object> = { 'role': 'assistant' };
  const calls: Object[] = [];
  for (let i = 0; i < msg.blocks.length; i++) {
    const b: Block = msg.blocks[i];
    if (b.kind === BLOCK_TOOL) {
      const fn: Record<string, Object> = { 'name': b.toolName, 'arguments': b.toolArgs };
      const call: Record<string, Object> = {
        'id': b.toolId,
        'type': 'function',
        'function': fn
      };
      calls.push(call as Object);
    }
  }
  if (text.length > 0) {
    rec['content'] = text;
  }
  if (calls.length > 0) {
    rec['tool_calls'] = calls;
  }
  return rec as Object;
}

export class MercuryAdapter implements ProviderAdapter {
  buildRequest(session: Session, messages: Msg[], toolsEnabled: boolean,
    apiKey: string, baseUrl: string): RequestSpec {
    const spec: RequestSpec = new RequestSpec();
    spec.url = endpointOf(baseUrl);
    spec.headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + apiKey.trim()
    };

    const out: Object[] = [];
    for (let i = 0; i < messages.length; i++) {
      const m: Msg = messages[i];
      if (m.role === 'user') {
        const text: string = m.firstText();
        if (text.length > 0) {
          const rec: Record<string, Object> = { 'role': 'user', 'content': text };
          out.push(rec as Object);
        }
        continue;
      }
      let proto: Object[] = m.protoProvider === session.providerId ? parseJsonArray(m.proto) : [];
      if (proto.length > 0 && hasKey(asRecord(proto[0]), 'role')) {
        out.push(proto[0]);
      } else {
        out.push(synthesizeAssistant(m));
      }
      for (let k = 0; k < m.blocks.length; k++) {
        const b: Block = m.blocks[k];
        if (b.kind !== BLOCK_TOOL) {
          continue;
        }
        let payload: string = b.toolResult;
        if (!b.toolFinished || payload.length === 0) {
          payload = JSON.stringify({ 'error': '工具未能执行完成' });
        }
        const rec: Record<string, Object> = {
          'role': 'tool',
          'tool_call_id': b.toolId,
          'content': payload
        };
        out.push(rec as Object);
      }
    }

    const opts: Record<string, Object> = { 'include_usage': true };
    const body: Record<string, Object> = {
      'model': session.modelId,
      'messages': out,
      'stream': true,
      'diffusing': session.options.diffusing,
      'reasoning_effort': session.options.thinkingLevel,
      'reasoning_summary': true,
      'stream_options': opts
    };
    if (toolsEnabled) {
      body['tools'] = parseJsonArray(ToolRunner.openaiToolsJson());
    }
    spec.bodyJson = JSON.stringify(body);
    return spec;
  }

  createTurn(sink: TurnSink, session: Session): TurnHandler {
    return new MercuryTurn(sink, session.options.diffusing);
  }
}

class MercuryTurn implements TurnHandler {
  private sink: TurnSink;
  private diffusing: boolean;
  private tools: McToolAcc[] = [];
  private phases: string[] = [];
  private curPhase: string = '';
  private finishReason: string = '';
  private ended: boolean = false;
  private sawContent: boolean = false;
  private summaryText: string = '';

  constructor(sink: TurnSink, diffusing: boolean) {
    this.sink = sink;
    this.diffusing = diffusing;
  }

  handleEvent(name: string, data: string): void {
    if (this.ended) {
      return;
    }
    if (data === '[DONE]') {
      this.closeTurn();
      return;
    }
    const rec: Record<string, Object> = parseObj(data);
    if (hasKey(rec, 'error') || getStr(rec, 'type') === 'error') {
      const err: Record<string, Object> = getObj(rec, 'error');
      let msg: string = getStr(err, 'message');
      if (msg.length === 0) {
        msg = getStr(rec, 'message');
      }
      if (msg.length === 0) {
        msg = '服务返回了一个错误';
      }
      this.ended = true;
      this.emitProto();
      this.sink.fail(msg);
      return;
    }

    // reasoning summary (chunk level, may be cumulative or incremental)
    if (hasKey(rec, 'reasoning_summary')) {
      const sum: Record<string, Object> = getObj(rec, 'reasoning_summary');
      const content: string = getStr(sum, 'content');
      if (content.length > 0) {
        if (this.summaryText.length > 0 && content.startsWith(this.summaryText)) {
          this.sink.thinking(content, true);
          this.summaryText = content;
        } else {
          this.sink.thinking(content, false);
          this.summaryText += content;
        }
      }
    }

    const choices: Object[] = getArr(rec, 'choices');
    if (choices.length > 0) {
      const choice: Record<string, Object> = asRecord(choices[0]);
      const delta: Record<string, Object> = getObj(choice, 'delta');
      const content: Object | undefined = delta['content'];
      if (content !== undefined && content !== null && typeof content === 'string') {
        const s: string = content as string;
        this.sawContent = true;
        if (s.length > 0) {
          // diffusing frames replace the draft of the active phase
          this.curPhase = this.diffusing ? s : this.curPhase + s;
          this.sink.text(s, this.diffusing);
        }
      }
      const calls: Object[] = getArr(delta, 'tool_calls');
      for (let i = 0; i < calls.length; i++) {
        this.handleToolDelta(asRecord(calls[i]));
      }
      const fr: string = getStr(choice, 'finish_reason');
      if (fr.length > 0) {
        this.finishReason = fr;
        if (fr === 'tool_calls') {
          this.finishTools();
        }
        this.emitProto();
      }
    }
    if (hasKey(rec, 'usage')) {
      // usage bookkeeping only
    }
  }

  handleEnd(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    this.finishTools();
    this.emitProto();
    if (this.finishReason.length > 0 || this.sawContent || this.summaryText.length > 0) {
      this.sink.end();
    } else {
      this.sink.fail('网络连接提前中断，回答可能不完整。');
    }
  }

  private closeTurn(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    this.finishTools();
    this.emitProto();
    this.sink.end();
  }

  private handleToolDelta(d: Record<string, Object>): void {
    const idx: number = this.intOf(d, 'index');
    const acc: McToolAcc = this.toolOf(idx);
    const id: string = getStr(d, 'id');
    if (id.length > 0) {
      acc.callId = id;
    }
    const fn: Record<string, Object> = getObj(d, 'function');
    const name: string = getStr(fn, 'name');
    if (name.length > 0 && acc.name !== name) {
      acc.name = name;
    }
    if (acc.callId.length === 0) {
      acc.callId = 'call_' + idx.toString();
    }
    // the text produced before tool calls forms its own generation phase
    if (this.curPhase.length > 0) {
      this.phases.push(this.curPhase);
      this.curPhase = '';
    }
    this.sink.toolStart(acc.callId, acc.name);
    const args: string = getStr(fn, 'arguments');
    if (args.length > 0) {
      acc.args += args;
      this.sink.toolArgs(acc.callId, args);
    }
  }

  private finishTools(): void {
    for (let i = 0; i < this.tools.length; i++) {
      const acc: McToolAcc = this.tools[i];
      if (!acc.ended) {
        acc.ended = true;
        this.sink.toolEnd(acc.callId);
      }
    }
    if (this.curPhase.length > 0) {
      this.phases.push(this.curPhase);
      this.curPhase = '';
    }
  }

  private emitProto(): void {
    let text: string = '';
    for (let i = 0; i < this.phases.length; i++) {
      text += this.phases[i];
    }
    text += this.curPhase;
    const rec: Record<string, Object> = { 'role': 'assistant' };
    const calls: Object[] = [];
    for (let i = 0; i < this.tools.length; i++) {
      const acc: McToolAcc = this.tools[i];
      const fn: Record<string, Object> = { 'name': acc.name, 'arguments': acc.args };
      const call: Record<string, Object> = {
        'id': acc.callId,
        'type': 'function'
      };
      call['function'] = fn;
      calls.push(call as Object);
    }
    if (text.length > 0) {
      rec['content'] = text;
    }
    if (calls.length > 0) {
      rec['tool_calls'] = calls;
    }
    const out: Object[] = [];
    out.push(rec as Object);
    this.sink.proto(JSON.stringify(out));
  }

  private toolOf(index: number): McToolAcc {
    for (let i = 0; i < this.tools.length; i++) {
      if (this.tools[i].index === index) {
        return this.tools[i];
      }
    }
    const acc: McToolAcc = new McToolAcc();
    acc.index = index;
    this.tools.push(acc);
    return acc;
  }

  private intOf(o: Record<string, Object>, key: string): number {
    const v: Object | undefined = o[key];
    if (v !== undefined && v !== null && typeof v === 'number') {
      return Math.floor(v as number);
    }
    return 0;
  }
}
