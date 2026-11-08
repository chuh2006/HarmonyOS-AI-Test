/**
 * DeepSeek adapter - Anthropic Messages API (streaming).
 * Base URL: https://api.deepseek.com/anthropic -> POST {base}/v1/messages
 * Thinking content (reasoning_content) and answers stream separately and the
 * full assistant content array (thinking + tool_use) is replayed verbatim on
 * follow-up requests as the protocol requires.
 */
import { ProviderAdapter, RequestSpec, TurnHandler, TurnSink, trimSlash } from './Adapter';
import { Block, Msg, Session, BLOCK_TOOL, BLOCK_TEXT } from './Types';
import { asArr, asRecord, getObj, getStr, hasKey, parseObj } from '../common/JsonUtil';
import { anthropicToolsJson } from './ToolSchemas';
class DsBlock {
  index: number = 0;
  type: string = '';
  text: string = '';
  thinking: string = '';
  signature: string = '';
  id: string = '';
  name: string = '';
  args: string = '';
}

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

function textContent(text: string): Object {
  const rec: Record<string, Object> = { 'type': 'text', 'text': text };
  return rec as Object;
}

/** Rebuild the assistant content array from display blocks when no raw payload is stored.
 *  Thinking blocks are display-only and are never synthesized into protocol content. */
function synthesizeBlocks(msg: Msg): Object[] {
  const out: Object[] = [];
  for (let i = 0; i < msg.blocks.length; i++) {
    const b: Block = msg.blocks[i];
    if (b.kind === BLOCK_TEXT && b.text.length > 0) {
      out.push(textContent(b.text));
    } else if (b.kind === BLOCK_TOOL) {
      const rec: Record<string, Object> = {
        'type': 'tool_use',
        'id': b.toolId,
        'name': b.toolName,
        'input': parseObj(b.toolArgs)
      };
      out.push(rec as Object);
    }
  }
  return out;
}

function pushMessage(list: Object[], role: string, content: Object[]): void {
  if (content.length === 0) {
    return;
  }
  if (list.length > 0) {
    const last: Record<string, Object> = asRecord(list[list.length - 1]);
    if (getStr(last, 'role') === role) {
      const merged: Object[] = asArr(last['content'] as Object).concat(content);
      last['content'] = merged;
      return;
    }
  }
  const msg: Record<string, Object> = {
    'role': role,
    'content': content
  };
  list.push(msg as Object);
}

export class DeepSeekAdapter implements ProviderAdapter {
  buildRequest(session: Session, messages: Msg[], toolsEnabled: boolean,
    apiKey: string, baseUrl: string): RequestSpec {
    const spec: RequestSpec = new RequestSpec();
    spec.url = trimSlash(baseUrl) + '/v1/messages';
    spec.headers = {
      'Content-Type': 'application/json',
      'x-api-key': apiKey.trim(),
      'Authorization': 'Bearer ' + apiKey.trim(),
      'anthropic-version': '2023-06-01'
    };

    const thinkingOn: boolean = session.options.thinkingOn;
    const out: Object[] = [];
    for (let i = 0; i < messages.length; i++) {
      const m: Msg = messages[i];
      if (m.role === 'user') {
        const text: string = m.firstText();
        if (text.length > 0) {
          const c: Object[] = [];
          c.push(textContent(text));
          pushMessage(out, 'user', c);
        }
        continue;
      }
      // assistant message: replay the raw content blocks
      let blocks: Object[] = m.protoProvider === session.providerId ? parseJsonArray(m.proto) : [];
      if (blocks.length === 0) {
        blocks = synthesizeBlocks(m);
      }
      const content: Object[] = [];
      for (let k = 0; k < blocks.length; k++) {
        const b: Record<string, Object> = asRecord(blocks[k]);
        const t: string = getStr(b, 'type');
        if (t === 'thinking') {
          if (thinkingOn) {
            const rec: Record<string, Object> = { 'type': 'thinking', 'thinking': getStr(b, 'thinking') };
            const sig: string = getStr(b, 'signature');
            if (sig.length > 0) {
              rec['signature'] = sig;
            }
            content.push(rec as Object);
          }
        } else if (t === 'text') {
          const txt: string = getStr(b, 'text');
          if (txt.length > 0) {
            content.push(textContent(txt));
          }
        } else if (t === 'tool_use') {
          content.push(b as Object);
        }
      }
      pushMessage(out, 'assistant', content);

      // tool results must sit in the immediately following user message
      const results: Object[] = [];
      for (let k = 0; k < m.blocks.length; k++) {
        const blk: Block = m.blocks[k];
        if (blk.kind !== BLOCK_TOOL) {
          continue;
        }
        let payload: string = blk.toolResult;
        if (!blk.toolFinished || payload.length === 0) {
          payload = JSON.stringify({ 'error': '工具未能执行完成' });
        }
        const rec: Record<string, Object> = {
          'type': 'tool_result',
          'tool_use_id': blk.toolId,
          'content': payload
        };
        results.push(rec as Object);
      }
      pushMessage(out, 'user', results);
    }

    const body: Record<string, Object> = {
      'model': session.modelId,
      'messages': out,
      'stream': true
    };
    if (thinkingOn) {
      const think: Record<string, Object> = { 'type': 'enabled' };
      body['thinking'] = think;
      const cfg: Record<string, Object> = { 'effort': session.options.thinkingLevel };
      body['output_config'] = cfg;
    } else {
      const think: Record<string, Object> = { 'type': 'disabled' };
      body['thinking'] = think;
    }
    if (toolsEnabled) {
      body['tools'] = parseJsonArray(anthropicToolsJson());
      const choice: Record<string, Object> = { 'type': 'auto' };
      body['tool_choice'] = choice;
    }
    spec.bodyJson = JSON.stringify(body);
    return spec;
  }

  createTurn(sink: TurnSink, session: Session): TurnHandler {
    return new DeepSeekTurn(sink);
  }
}

class DeepSeekTurn implements TurnHandler {
  private sink: TurnSink;
  private blocks: DsBlock[] = [];
  private stopReason: string = '';
  private ended: boolean = false;
  private sawStop: boolean = false;

  constructor(sink: TurnSink) {
    this.sink = sink;
  }

  handleEvent(name: string, data: string): void {
    if (this.ended) {
      return;
    }
    const rec: Record<string, Object> = parseObj(data);
    let kind: string = getStr(rec, 'type');
    if (kind.length === 0) {
      kind = name;
    }
    if (hasKey(rec, 'error') || kind === 'error') {
      const err: Record<string, Object> = getObj(rec, 'error');
      let msg: string = getStr(err, 'message');
      if (msg.length === 0) {
        msg = getStr(rec, 'message');
      }
      if (msg.length === 0) {
        msg = '服务返回了一个错误';
      }
      this.ended = true;
      this.sink.fail(msg);
      return;
    }
    if (kind === 'ping') {
      return;
    }
    if (kind === 'message_start') {
      this.emitProto();
      return;
    }
    if (kind === 'content_block_start') {
      const idx: number = this.intOf(rec, 'index');
      const cb: Record<string, Object> = getObj(rec, 'content_block');
      const b: DsBlock = new DsBlock();
      b.index = idx;
      b.type = getStr(cb, 'type');
      b.id = getStr(cb, 'id');
      b.name = getStr(cb, 'name');
      this.blocks.push(b);
      if (b.type === 'tool_use') {
        this.sink.toolStart(b.id, b.name);
      }
      return;
    }
    if (kind === 'content_block_delta') {
      const idx: number = this.intOf(rec, 'index');
      const delta: Record<string, Object> = getObj(rec, 'delta');
      const dtype: string = getStr(delta, 'type');
      const b: DsBlock | null = this.find(idx);
      if (b === null) {
        return;
      }
      if (dtype === 'thinking_delta') {
        const t: string = getStr(delta, 'thinking');
        b.thinking += t;
        if (t.length > 0) {
          this.sink.thinking(t, false);
        }
      } else if (dtype === 'text_delta') {
        const t: string = getStr(delta, 'text');
        b.text += t;
        if (t.length > 0) {
          this.sink.text(t, false);
        }
      } else if (dtype === 'input_json_delta') {
        const p: string = getStr(delta, 'partial_json');
        b.args += p;
        if (p.length > 0) {
          this.sink.toolArgs(b.id, p);
        }
      } else if (dtype === 'signature_delta') {
        b.signature += getStr(delta, 'signature');
      }
      return;
    }
    if (kind === 'content_block_stop') {
      const idx: number = this.intOf(rec, 'index');
      const b: DsBlock | null = this.find(idx);
      if (b !== null && b.type === 'tool_use') {
        this.sink.toolEnd(b.id);
      }
      this.emitProto();
      return;
    }
    if (kind === 'message_delta') {
      const delta: Record<string, Object> = getObj(rec, 'delta');
      const sr: string = getStr(delta, 'stop_reason');
      if (sr.length > 0) {
        this.stopReason = sr;
      }
      this.emitProto();
      return;
    }
    if (kind === 'message_stop') {
      this.sawStop = true;
      this.emitProto();
      this.ended = true;
      this.sink.end();
      return;
    }
    // Unknown event types are ignored but keep the payload fresh.
    this.emitProto();
  }

  handleEnd(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    if (this.sawStop || this.stopReason.length > 0) {
      this.sink.end();
    } else {
      this.sink.fail('网络连接提前中断，回答可能不完整。');
    }
  }

  private intOf(o: Record<string, Object>, key: string): number {
    const v: Object | undefined = o[key];
    if (v !== undefined && v !== null && typeof v === 'number') {
      return Math.floor(v as number);
    }
    return 0;
  }

  private find(idx: number): DsBlock | null {
    for (let i = 0; i < this.blocks.length; i++) {
      if (this.blocks[i].index === idx) {
        return this.blocks[i];
      }
    }
    return null;
  }

  private emitProto(): void {
    const out: Object[] = [];
    for (let i = 0; i < this.blocks.length; i++) {
      const b: DsBlock = this.blocks[i];
      if (b.type === 'thinking') {
        const rec: Record<string, Object> = { 'type': 'thinking', 'thinking': b.thinking };
        if (b.signature.length > 0) {
          rec['signature'] = b.signature;
        }
        out.push(rec as Object);
      } else if (b.type === 'text') {
        out.push(textContent(b.text));
      } else if (b.type === 'tool_use') {
        const rec: Record<string, Object> = {
          'type': 'tool_use',
          'id': b.id,
          'name': b.name,
          'input': parseObj(b.args)
        };
        out.push(rec as Object);
      }
    }
    this.sink.proto(JSON.stringify(out));
  }
}
