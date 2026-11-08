/**
 * OpenAI adapter - Responses API (streaming, stateless).
 * Endpoint: {base}/v1/responses
 * The request is stateless (store:false) and replays every output item of
 * earlier turns, including reasoning.encrypted_content and function calls, so
 * conversations keep working across restarts and custom base URLs.
 */
import { ProviderAdapter, RequestSpec, TurnHandler, TurnSink, trimSlash } from './Adapter';
import { Block, Msg, Session, BLOCK_TOOL, BLOCK_TEXT } from './Types';
import { asArr, asRecord, getArr, getBool, getObj, getStr, hasKey, parseObj } from '../common/JsonUtil';
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

class ItemAcc {
  itemId: string = '';
  type: string = '';
  callId: string = '';
  name: string = '';
  arguments: string = '';
  text: string = '';
  summaryText: string = '';
  encrypted: string = '';
  rawDone: string = '';
}

function endpointOf(baseUrl: string): string {
  const b: string = trimSlash(baseUrl);
  if (b.endsWith('/responses')) {
    return b;
  }
  return b + '/v1/responses';
}

/** Fallback output items built from the display blocks when nothing raw was stored. */
function synthesizeItems(msg: Msg): Object[] {
  const out: Object[] = [];
  let text: string = '';
  for (let i = 0; i < msg.blocks.length; i++) {
    const b: Block = msg.blocks[i];
    if (b.kind === BLOCK_TEXT) {
      text += b.text;
    }
  }
  if (text.length > 0) {
    const contentPart: Record<string, Object> = { 'type': 'output_text', 'text': text };
    const annotations: Object[] = [];
    contentPart['annotations'] = annotations;
    const contentArr: Object[] = [];
    contentArr.push(contentPart as Object);
    const message: Record<string, Object> = {
      'type': 'message',
      'role': 'assistant',
      'status': 'completed'
    };
    message['content'] = contentArr;
    out.push(message as Object);
  }
  for (let i = 0; i < msg.blocks.length; i++) {
    const b: Block = msg.blocks[i];
    if (b.kind === BLOCK_TOOL) {
      const fc: Record<string, Object> = {
        'type': 'function_call',
        'call_id': b.toolId,
        'name': b.toolName,
        'arguments': b.toolArgs,
        'status': 'completed'
      };
      out.push(fc as Object);
    }
  }
  return out;
}

export class OpenAIAdapter implements ProviderAdapter {
  buildRequest(session: Session, messages: Msg[], toolsEnabled: boolean,
    apiKey: string, baseUrl: string): RequestSpec {
    const spec: RequestSpec = new RequestSpec();
    spec.url = endpointOf(baseUrl);
    spec.headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + apiKey.trim()
    };

    const input: Object[] = [];
    for (let i = 0; i < messages.length; i++) {
      const m: Msg = messages[i];
      if (m.role === 'user') {
        const text: string = m.firstText();
        if (text.length > 0) {
          const um: Record<string, Object> = { 'role': 'user', 'content': text };
          input.push(um as Object);
        }
        continue;
      }
      let items: Object[] = m.protoProvider === session.providerId ? parseJsonArray(m.proto) : [];
      if (items.length === 0) {
        items = synthesizeItems(m);
      }
      for (let k = 0; k < items.length; k++) {
        input.push(items[k]);
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
        const out: Record<string, Object> = {
          'type': 'function_call_output',
          'call_id': b.toolId,
          'output': payload
        };
        input.push(out as Object);
      }
    }

    const reasoning: Record<string, Object> = {};
    if (session.options.thinkingOn) {
      reasoning['effort'] = session.options.thinkingLevel;
      reasoning['mode'] = session.options.reasoningMode;
      reasoning['summary'] = 'auto';
    } else {
      reasoning['effort'] = 'none';
    }

    const body: Record<string, Object> = {
      'model': session.modelId,
      'input': input,
      'stream': true,
      'store': false,
      'reasoning': reasoning
    };
    const include: Object[] = [];
    include.push('reasoning.encrypted_content' as Object);
    body['include'] = include;
    if (session.options.speedTier === 'fast') {
      body['service_tier'] = 'fast';
    } else if (session.options.speedTier === 'ultrafast') {
      body['service_tier'] = 'ultrafast';
    }
    if (toolsEnabled) {
      body['tools'] = parseJsonArray(ToolRunner.openaiToolsJson());
    }
    spec.bodyJson = JSON.stringify(body);
    return spec;
  }

  createTurn(sink: TurnSink, session: Session): TurnHandler {
    return new OpenAITurn(sink);
  }
}

class OpenAITurn implements TurnHandler {
  private sink: TurnSink;
  private items: ItemAcc[] = [];
  private ended: boolean = false;
  private lastSummaryIndex: number = -1;

  constructor(sink: TurnSink) {
    this.sink = sink;
  }

  handleEvent(name: string, data: string): void {
    if (this.ended) {
      return;
    }
    if (data === '[DONE]') {
      this.finish('done');
      return;
    }
    const rec: Record<string, Object> = parseObj(data);
    let kind: string = getStr(rec, 'type');
    if (kind.length === 0) {
      kind = name;
    }
    if (kind === 'error' || hasKey(rec, 'error')) {
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
    if (kind === 'response.output_item.added') {
      const item: Record<string, Object> = getObj(rec, 'item');
      const acc: ItemAcc = this.accOf(getStr(item, 'id'));
      acc.type = getStr(item, 'type');
      acc.name = getStr(item, 'name');
      acc.callId = getStr(item, 'call_id');
      if (acc.callId.length === 0) {
        acc.callId = acc.itemId;
      }
      if (acc.type === 'function_call') {
        this.sink.toolStart(acc.callId, acc.name);
      }
      return;
    }
    if (kind === 'response.output_text.delta') {
      const acc: ItemAcc = this.accOf(getStr(rec, 'item_id'));
      acc.type = 'message';
      const d: string = getStr(rec, 'delta');
      acc.text += d;
      if (d.length > 0) {
        this.sink.text(d, false);
      }
      return;
    }
    if (kind === 'response.output_text.done') {
      const acc: ItemAcc = this.accOf(getStr(rec, 'item_id'));
      const t: string = getStr(rec, 'text');
      if (t.length > acc.text.length) {
        acc.text = t;
      }
      this.emitProto();
      return;
    }
    if (kind === 'response.reasoning_summary_part.added') {
      const idx: number = this.intOf(rec, 'summary_index');
      if (this.lastSummaryIndex >= 0 && idx > this.lastSummaryIndex) {
        this.sink.thinking('\n\n', false);
      }
      this.lastSummaryIndex = idx;
      return;
    }
    if (kind === 'response.reasoning_summary_text.delta') {
      const acc: ItemAcc = this.accOf(getStr(rec, 'item_id'));
      acc.type = 'reasoning';
      const idx: number = this.intOf(rec, 'summary_index');
      if (this.lastSummaryIndex >= 0 && idx > this.lastSummaryIndex) {
        this.sink.thinking('\n\n', false);
      }
      this.lastSummaryIndex = idx;
      const d: string = getStr(rec, 'delta');
      acc.summaryText += d;
      if (d.length > 0) {
        this.sink.thinking(d, false);
      }
      return;
    }
    if (kind === 'response.reasoning_summary_text.done') {
      const acc: ItemAcc = this.accOf(getStr(rec, 'item_id'));
      acc.type = 'reasoning';
      const t: string = getStr(rec, 'text');
      if (t.length > acc.summaryText.length) {
        acc.summaryText = t;
      }
      this.emitProto();
      return;
    }
    if (kind === 'response.function_call_arguments.delta') {
      const acc: ItemAcc = this.accOf(getStr(rec, 'item_id'));
      acc.type = 'function_call';
      const d: string = getStr(rec, 'delta');
      acc.arguments += d;
      if (d.length > 0) {
        this.sink.toolArgs(acc.callId, d);
      }
      return;
    }
    if (kind === 'response.function_call_arguments.done') {
      const acc: ItemAcc = this.accOf(getStr(rec, 'item_id'));
      const a: string = getStr(rec, 'arguments');
      if (a.length > 0) {
        acc.arguments = a;
      }
      return;
    }
    if (kind === 'response.output_item.done') {
      const item: Record<string, Object> = getObj(rec, 'item');
      const acc: ItemAcc = this.accOf(getStr(item, 'id'));
      acc.type = getStr(item, 'type');
      if (acc.type === 'function_call') {
        const cid: string = getStr(item, 'call_id');
        if (cid.length > 0) {
          acc.callId = cid;
        }
        acc.name = getStr(item, 'name');
        const a: string = getStr(item, 'arguments');
        if (a.length > 0) {
          acc.arguments = a;
        }
        this.sink.toolEnd(acc.callId);
      } else if (acc.type === 'reasoning') {
        acc.encrypted = getStr(item, 'encrypted_content');
        const summary: Object[] = getArr(item, 'summary');
        if (summary.length > 0) {
          let joined: string = '';
          for (let i = 0; i < summary.length; i++) {
            const s: Record<string, Object> = asRecord(summary[i]);
            if (i > 0) {
              joined += '\n\n';
            }
            joined += getStr(s, 'text');
          }
          if (joined.length > acc.summaryText.length) {
            acc.summaryText = joined;
          }
        }
      } else if (acc.type === 'message') {
        const parts: Object[] = getArr(item, 'content');
        let joined: string = '';
        for (let i = 0; i < parts.length; i++) {
          const p: Record<string, Object> = asRecord(parts[i]);
          joined += getStr(p, 'text');
        }
        if (joined.length > acc.text.length) {
          acc.text = joined;
        }
      }
      this.emitProto();
      return;
    }
    if (kind === 'response.completed') {
      const response: Record<string, Object> = getObj(rec, 'response');
      const output: Object[] = getArr(response, 'output');
      if (output.length > 0) {
        this.sink.proto(JSON.stringify(output));
      } else {
        this.emitProto();
      }
      this.finish('done');
      return;
    }
    if (kind === 'response.incomplete') {
      const response: Record<string, Object> = getObj(rec, 'response');
      const details: Record<string, Object> = getObj(response, 'incomplete_details');
      let reason: string = getStr(details, 'reason');
      if (reason === 'max_output_tokens') {
        reason = '已达到输出长度上限';
      }
      this.emitProto();
      this.ended = true;
      this.sink.fail('回答未能完整生成（' + reason + '），已保留收到的内容。');
      return;
    }
    if (kind === 'response.failed') {
      const response: Record<string, Object> = getObj(rec, 'response');
      const err: Record<string, Object> = getObj(response, 'error');
      let msg: string = getStr(err, 'message');
      if (msg.length === 0) {
        msg = '模型生成失败';
      }
      this.ended = true;
      this.sink.fail(msg);
      return;
    }
    // response.created / response.in_progress and other bookkeeping events
  }

  handleEnd(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    this.emitProto();
    this.sink.fail('网络连接提前中断，回答可能不完整。');
  }

  private finish(mode: string): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    this.emitProto();
    this.sink.end();
  }

  private accOf(itemId: string): ItemAcc {
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].itemId === itemId) {
        return this.items[i];
      }
    }
    const acc: ItemAcc = new ItemAcc();
    acc.itemId = itemId;
    acc.callId = itemId;
    this.items.push(acc);
    return acc;
  }

  private intOf(o: Record<string, Object>, key: string): number {
    const v: Object | undefined = o[key];
    if (v !== undefined && v !== null && typeof v === 'number') {
      return Math.floor(v as number);
    }
    return -1;
  }

  private emitProto(): void {
    const out: Object[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const acc: ItemAcc = this.items[i];
      if (acc.type === 'reasoning') {
        const rec: Record<string, Object> = { 'type': 'reasoning' };
        if (acc.itemId.length > 0) {
          rec['id'] = acc.itemId;
        }
        const summary: Object[] = [];
        if (acc.summaryText.length > 0) {
          const s: Record<string, Object> = { 'type': 'summary_text', 'text': acc.summaryText };
          summary.push(s as Object);
        }
        rec['summary'] = summary;
        if (acc.encrypted.length > 0) {
          rec['encrypted_content'] = acc.encrypted;
        }
        out.push(rec as Object);
      } else if (acc.type === 'message') {
        if (acc.text.length === 0) {
          continue;
        }
        const part: Record<string, Object> = { 'type': 'output_text', 'text': acc.text };
        const annotations: Object[] = [];
        part['annotations'] = annotations;
        const contentArr: Object[] = [];
        contentArr.push(part as Object);
        const rec: Record<string, Object> = {
          'type': 'message',
          'role': 'assistant',
          'status': 'completed'
        };
        rec['content'] = contentArr;
        if (acc.itemId.length > 0) {
          rec['id'] = acc.itemId;
        }
        out.push(rec as Object);
      } else if (acc.type === 'function_call') {
        const rec: Record<string, Object> = {
          'type': 'function_call',
          'call_id': acc.callId,
          'name': acc.name,
          'arguments': acc.arguments,
          'status': 'completed'
        };
        if (acc.itemId.length > 0) {
          rec['id'] = acc.itemId;
        }
        out.push(rec as Object);
      }
    }
    this.sink.proto(JSON.stringify(out));
  }
}
