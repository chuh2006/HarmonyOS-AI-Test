import { Conversation, Role, MsgStatus } from '../model/Types';
import { streamPost, StreamHandle, SseEvent, ChatError } from '../net/HttpClient';
import { ProviderAdapter, PhaseResult, StreamSink, ToolCallInfo, toolResultFor, trimBaseUrl } from './Base';
import { TOOL_DEFS, ToolSchema } from '../tools/ToolService';

interface GemFunctionCall {
  name?: string;
  args?: Record<string, Object>;
  id?: string;
}

interface GemFunctionResponse {
  name: string;
  response: Record<string, Object>;
  id?: string;
}

interface GemPart {
  text?: string;
  thought?: boolean;
  thoughtSignature?: string;
  functionCall?: GemFunctionCall;
  functionResponse?: GemFunctionResponse;
}

interface GemContent {
  role: string;
  parts: GemPart[];
}

interface GemFuncDecl {
  name: string;
  description: string;
  parameters: ToolSchema;
}

interface GemTool {
  functionDeclarations: GemFuncDecl[];
}

interface GemThinkingConfig {
  includeThoughts: boolean;
  thinkingLevel: string;
}

interface GemGenerationConfig {
  thinkingConfig: GemThinkingConfig;
}

interface GemRequest {
  contents: GemContent[];
  tools: GemTool[];
  generationConfig: GemGenerationConfig;
}

interface GemCandidate {
  content?: GemContent;
  finishReason?: string;
}

interface GemUsage {
  promptTokenCount?: number;
  candidatesTokenCount?: number;
  thoughtsTokenCount?: number;
}

interface GemError {
  message?: string;
  status?: string;
}

interface GemFeedback {
  blockReason?: string;
}

interface GemChunk {
  candidates?: GemCandidate[];
  usageMetadata?: GemUsage;
  error?: GemError;
  promptFeedback?: GemFeedback;
}

export class GeminiAdapter implements ProviderAdapter {
  async streamPhase(conv: Conversation, apiKey: string, baseUrl: string, sink: StreamSink,
    handle: StreamHandle): Promise<PhaseResult> {
    const contents = this.buildContents(conv);
    const decls: GemFuncDecl[] = [];
    for (const t of TOOL_DEFS) {
      decls.push({ name: t.name, description: t.description, parameters: t.schema });
    }
    const body: GemRequest = {
      contents: contents,
      tools: [{ functionDeclarations: decls }],
      generationConfig: {
        thinkingConfig: { includeThoughts: true, thinkingLevel: conv.options.gemLevel.toUpperCase() }
      }
    };

    const payloadParts: GemPart[] = [];
    const toolCalls: ToolCallInfo[] = [];
    let done = false;
    let stopReason = '';
    let callSeq = 0;
    let usageText = '';
    const assistant = conv.lastAssistant();
    const phaseIdx = assistant !== null ? assistant.phases.length : 0;

    const onEvent = (e: SseEvent): void => {
      if (e.data.length === 0 || e.data === '[DONE]') {
        return;
      }
      let chunk: GemChunk;
      try {
        chunk = JSON.parse(e.data) as GemChunk;
      } catch (parseErr) {
        throw new ChatError('Gemini 响应解析失败');
      }
      if (chunk.error !== undefined) {
        throw new ChatError(chunk.error.message ?? 'Gemini 服务返回错误');
      }
      if (chunk.promptFeedback?.blockReason !== undefined) {
        throw new ChatError('提问被安全策略拦截，请换一种表述');
      }
      if (chunk.usageMetadata !== undefined) {
        const u = chunk.usageMetadata;
        usageText = `输入 ${u.promptTokenCount ?? 0} · 输出 ${u.candidatesTokenCount ?? 0} tokens`;
      }
      const candidates = chunk.candidates ?? [];
      if (candidates.length === 0) {
        return;
      }
      const cand = candidates[0];
      const parts = cand.content?.parts ?? [];
      for (const part of parts) {
        payloadParts.push(part);
        if (part.functionCall !== undefined) {
          const fc = part.functionCall;
          const id = (fc.id !== undefined && fc.id.length > 0) ? fc.id : `g${phaseIdx}_${callSeq}`;
          callSeq++;
          const argsJson = JSON.stringify(fc.args ?? {});
          sink.status(MsgStatus.ANSWERING);
          sink.toolStart(id, fc.name ?? '');
          sink.toolReady(id, argsJson);
          toolCalls.push(new ToolCallInfo(id, fc.name ?? '', argsJson));
        } else if (part.thought === true) {
          if (part.text !== undefined && part.text.length > 0) {
            sink.status(MsgStatus.THINKING);
            sink.thinkingDelta(part.text);
          }
        } else if (part.text !== undefined && part.text.length > 0) {
          sink.status(MsgStatus.ANSWERING);
          sink.textDelta(part.text);
        }
      }
      if (cand.finishReason !== undefined && cand.finishReason.length > 0) {
        stopReason = cand.finishReason;
        if (stopReason === 'STOP' || stopReason === 'MAX_TOKENS' || stopReason === 'CONTINUATION') {
          done = true;
        } else {
          throw new ChatError(`生成被终止（${stopReason}），已保留收到的内容`);
        }
      }
    };

    sink.status(MsgStatus.REQUESTING);
    const url = `${trimBaseUrl(baseUrl)}/models/${conv.model}:streamGenerateContent?alt=sse`;
    await streamPost(url, { 'x-goog-api-key': apiKey }, JSON.stringify(body), onEvent, handle);

    if (!done) {
      throw new ChatError('连接中断，响应不完整，已保留收到的内容');
    }
    if (usageText.length > 0) {
      sink.usage(usageText);
    }
    const payload: GemContent = { role: 'model', parts: payloadParts };
    const result = new PhaseResult();
    result.payload = JSON.stringify(payload);
    result.toolCalls = toolCalls;
    result.stopReason = stopReason;
    return result;
  }

  private buildContents(conv: Conversation): GemContent[] {
    const out: GemContent[] = [];
    for (const msg of conv.messages) {
      if (msg.role === Role.USER) {
        out.push({ role: 'user', parts: [{ text: msg.textContent() }] });
        continue;
      }
      let phaseIdx = 0;
      for (const phase of msg.phases) {
        let modelContent: GemContent;
        try {
          modelContent = JSON.parse(phase) as GemContent;
        } catch (e) {
          continue;
        }
        out.push(modelContent);
        const responses: GemPart[] = [];
        let callSeq = 0;
        for (const part of modelContent.parts) {
          const fc = part.functionCall;
          if (fc === undefined) {
            continue;
          }
          const lookupId = (fc.id !== undefined && fc.id.length > 0) ? fc.id : `g${phaseIdx}_${callSeq}`;
          callSeq++;
          let responseObj: Record<string, Object> = {};
          const raw = toolResultFor(msg, lookupId);
          try {
            responseObj = JSON.parse(raw) as Record<string, Object>;
          } catch (e) {
            responseObj = { 'output': raw };
          }
          const fr: GemFunctionResponse = { name: fc.name ?? '', response: responseObj };
          if (fc.id !== undefined && fc.id.length > 0) {
            fr.id = fc.id;
          }
          responses.push({ functionResponse: fr });
        }
        if (responses.length > 0) {
          out.push({ role: 'user', parts: responses });
        }
        phaseIdx++;
      }
    }
    return out;
  }
}