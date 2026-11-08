/**
 * Google Gemini adapter - native Generate Content REST (SSE streaming).
 * Endpoint: {base}/v1beta/models/{model}:streamGenerateContent?alt=sse
 *
 * Every Part returned by the server - text, thought summary and function
 * calls - is stored verbatim including its thoughtSignature, preserving the
 * original order and per-part signatures so the protocol context survives
 * restarts and multi-step tool calls.
 */
import { ProviderAdapter, RequestSpec, TurnHandler, TurnSink, trimSlash } from './Adapter';
import { Block, Msg, Session, BLOCK_TOOL, BLOCK_TEXT } from './Types';
import { asArr, asRecord, getArr, getBool, getObj, getStr, hasKey, hasObj, parseObj } from '../common/JsonUtil';
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

class PartAcc {
  isFn: boolean = false;
  thought: boolean = false;
  text: string = '';
  sig: string = '';
  fnName: string = '';
  fnArgs: string = '';
  callId: string = '';
}

function pushContent(list: Object[], role: string, parts: Object[]): void {
  if (parts.length === 0) {
    return;
  }
  if (list.length > 0) {
    const last: Record<string, Object> = asRecord(list[list.length - 1]);
    if (getStr(last, 'role') === role) {
      const merged: Object[] = asArr(last['parts'] as Object).concat(parts);
      last['parts'] = merged;
      return;
    }
  }
  const rec: Record<string, Object> = {
    'role': role,
    'parts': parts
  };
  list.push(rec as Object);
}

/** Rebuild model parts from display blocks when no raw payload is available.
 *  Thought summaries are display-only and are not synthesized. */
function synthesizeParts(msg: Msg): Object[] {
  const out: Object[] = [];
  for (let i = 0; i < msg.blocks.length; i++) {
    const b: Block = msg.blocks[i];
    if (b.kind === BLOCK_TEXT && b.text.length > 0) {
      const rec: Record<string, Object> = { 'text': b.text };
      out.push(rec as Object);
    } else if (b.kind === BLOCK_TOOL) {
      const fn: Record<string, Object> = {
        'name': b.toolName,
        'args': parseObj(b.toolArgs)
      };
      const rec: Record<string, Object> = { 'functionCall': fn };
      out.push(rec as Object);
    }
  }
  return out;
}

export class GeminiAdapter implements ProviderAdapter {
  buildRequest(session: Session, messages: Msg[], toolsEnabled: boolean,
    apiKey: string, baseUrl: string): RequestSpec {
    const spec: RequestSpec = new RequestSpec();
    spec.url = trimSlash(baseUrl) + '/v1beta/models/' + session.modelId + ':streamGenerateContent?alt=sse';
    spec.headers = {
      'Content-Type': 'application/json',
      'x-goog-api-key': apiKey.trim()
    };

    const contents: Object[] = [];
    for (let i = 0; i < messages.length; i++) {
      const m: Msg = messages[i];
      if (m.role === 'user') {
        const text: string = m.firstText();
        if (text.length > 0) {
          const part: Record<string, Object> = { 'text': text };
          const parts: Object[] = [];
          parts.push(part as Object);
          pushContent(contents, 'user', parts);
        }
        continue;
      }
      let parts: Object[] = m.protoProvider === session.providerId ? parseJsonArray(m.proto) : [];
      if (parts.length === 0) {
        parts = synthesizeParts(m);
      }
      pushContent(contents, 'model', parts);

      const respParts: Object[] = [];
      for (let k = 0; k < m.blocks.length; k++) {
        const b: Block = m.blocks[k];
        if (b.kind !== BLOCK_TOOL) {
          continue;
        }
        let payload: string = b.toolResult;
        if (!b.toolFinished || payload.length === 0) {
          payload = JSON.stringify({ 'error': '工具未能执行完成' });
        }
        const response: Record<string, Object> = parseObj(payload);
        const fn: Record<string, Object> = {
          'name': b.toolName,
          'response': response
        };
        const part: Record<string, Object> = { 'functionResponse': fn };
        respParts.push(part as Object);
      }
      pushContent(contents, 'user', respParts);
    }

    const thinking: Record<string, Object> = {
      'includeThoughts': true,
      'thinkingLevel': session.options.thinkingLevel
    };
    const gen: Record<string, Object> = { 'thinkingConfig': thinking };
    const body: Record<string, Object> = {
      'contents': contents,
      'generationConfig': gen
    };
    if (toolsEnabled) {
      body['tools'] = parseJsonArray(ToolRunner.geminiToolsJson());
    }
    spec.bodyJson = JSON.stringify(body);
    return spec;
  }

  createTurn(sink: TurnSink, session: Session): TurnHandler {
    return new GeminiTurn(sink);
  }
}

class GeminiTurn implements TurnHandler {
  private sink: TurnSink;
  private parts: PartAcc[] = [];
  private ended: boolean = false;
  private sawFinish: boolean = false;
  private fnSeq: number = 0;

  constructor(sink: TurnSink) {
    this.sink = sink;
  }

  handleEvent(name: string, data: string): void {
    if (this.ended) {
      return;
    }
    if (data === '[DONE]') {
      this.close();
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
      this.sink.fail(msg);
      return;
    }
    const candidates: Object[] = getArr(rec, 'candidates');
    if (candidates.length > 0) {
      const cand: Record<string, Object> = asRecord(candidates[0]);
      const content: Record<string, Object> = getObj(cand, 'content');
      const parts: Object[] = getArr(content, 'parts');
      for (let i = 0; i < parts.length; i++) {
        this.handlePart(asRecord(parts[i]));
      }
      this.emitProto();
      const fr: string = getStr(cand, 'finishReason');
      if (fr.length > 0) {
        this.sawFinish = true;
      }
    }
  }

  handleEnd(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    if (this.sawFinish || this.parts.length > 0) {
      this.sink.end();
    } else {
      this.sink.fail('网络连接提前中断，回答可能不完整。');
    }
  }

  private close(): void {
    if (this.ended) {
      return;
    }
    this.ended = true;
    this.sink.end();
  }

  private handlePart(p: Record<string, Object>): void {
    const sig: string = getStr(p, 'thoughtSignature');
    if (hasObj(p, 'functionCall')) {
      const fn: Record<string, Object> = getObj(p, 'functionCall');
      const name: string = getStr(fn, 'name');
      const args: Record<string, Object> = getObj(fn, 'args');
      this.fnSeq += 1;
      const acc: PartAcc = new PartAcc();
      acc.isFn = true;
      acc.fnName = name;
      acc.fnArgs = JSON.stringify(args);
      acc.sig = sig;
      acc.callId = 'fn_' + this.fnSeq.toString();
      this.parts.push(acc);
      this.sink.toolStart(acc.callId, name);
      this.sink.toolArgs(acc.callId, acc.fnArgs);
      this.sink.toolEnd(acc.callId);
      return;
    }
    const text: string = getStr(p, 'text');
    const thought: boolean = getBool(p, 'thought');
    if (text.length === 0 && sig.length === 0) {
      // A part that carries neither content nor signature; nothing to do.
      return;
    }
    if (text.length === 0 && sig.length > 0) {
      // Streaming may deliver the signature of the last part in an empty part.
      const target: PartAcc | null = this.lastUnsigned();
      if (target !== null) {
        target.sig = sig;
      } else {
        const acc: PartAcc = new PartAcc();
        acc.thought = thought;
        acc.sig = sig;
        this.parts.push(acc);
      }
      return;
    }
    // Text content: merge into the open part of the same kind or start a new one.
    let acc: PartAcc | null = null;
    if (this.parts.length > 0) {
      const last: PartAcc = this.parts[this.parts.length - 1];
      if (!last.isFn && last.thought === thought && last.sig.length === 0) {
        acc = last;
      }
    }
    if (acc === null) {
      acc = new PartAcc();
      acc.thought = thought;
      this.parts.push(acc);
    }
    acc.text += text;
    if (sig.length > 0) {
      acc.sig = sig;
    }
    if (thought) {
      this.sink.thinking(text, false);
    } else {
      this.sink.text(text, false);
    }
  }

  private lastUnsigned(): PartAcc | null {
    for (let i = this.parts.length - 1; i >= 0; i--) {
      if (this.parts[i].sig.length === 0) {
        return this.parts[i];
      }
    }
    return null;
  }

  private emitProto(): void {
    const out: Object[] = [];
    for (let i = 0; i < this.parts.length; i++) {
      const acc: PartAcc = this.parts[i];
      const rec: Record<string, Object> = {};
      if (acc.isFn) {
        const fn: Record<string, Object> = {
          'name': acc.fnName,
          'args': parseObj(acc.fnArgs)
        };
        rec['functionCall'] = fn;
      } else {
        rec['text'] = acc.text;
        if (acc.thought) {
          rec['thought'] = true;
        }
      }
      if (acc.sig.length > 0) {
        rec['thoughtSignature'] = acc.sig;
      }
      out.push(rec as Object);
    }
    this.sink.proto(JSON.stringify(out));
  }
}
