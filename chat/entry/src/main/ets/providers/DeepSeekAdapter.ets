import { Conversation, Role, MsgStatus } from '../model/Types';
import { streamPost, StreamHandle, SseEvent, ChatError } from '../net/HttpClient';
import { ProviderAdapter, PhaseResult, StreamSink, ToolCallInfo, toolResultFor, trimBaseUrl } from './Base';
import { TOOL_DEFS, ToolSchema } from '../tools/ToolService';

interface DsTool {
  name: string;
  description: string;
  input_schema: ToolSchema;
}

interface DsToolChoice {
  type: string;
}

interface DsThinking {
  type: string;
}

interface DsOutputConfig {
  effort: string;
}

interface DsMessage {
  role: string;
  content: Object;
  usage?: DsUsage;
}

interface DsRequest {
  model: string;
  messages: DsMessage[];
  stream: boolean;
  thinking: DsThinking;
  output_config?: DsOutputConfig;
  tools: DsTool[];
  tool_choice: DsToolChoice;
}

interface DsBlock {
  type: string;
  text?: string;
  thinking?: string;
  signature?: string;
  id?: string;
  name?: string;
  input?: Record<string, Object>;
  tool_use_id?: string;
  content?: string;
}

interface DsDelta {
  type?: string;
  text?: string;
  thinking?: string;
  signature?: string;
  partial_json?: string;
  stop_reason?: string;
}

interface DsUsage {
  input_tokens?: number;
  output_tokens?: number;
  cache_read_input_tokens?: number;
}

interface DsEvent {
  type?: string;
  index?: number;
  content_block?: DsBlock;
  delta?: DsDelta;
  message?: DsMessage;
  usage?: DsUsage;
  error?: DsError;
}

interface DsError {
  message?: string;
}

class DsStreamBlock {
  type: string = '';
  text: string = '';
  thinking: string = '';
  signature: string = '';
  id: string = '';
  name: string = '';
  argsJson: string = '';
}

export class DeepSeekAdapter implements ProviderAdapter {
  async streamPhase(conv: Conversation, apiKey: string, baseUrl: string, sink: StreamSink,
    handle: StreamHandle): Promise<PhaseResult> {
    const messages = this.buildMessages(conv);
    const tools: DsTool[] = [];
    for (const t of TOOL_DEFS) {
      tools.push({ name: t.name, description: t.description, input_schema: t.schema });
    }
    const body: DsRequest = {
      model: conv.model,
      messages: messages,
      stream: true,
      thinking: { type: conv.options.dsThinking ? 'enabled' : 'disabled' },
      tools: tools,
      tool_choice: { type: 'auto' }
    };
    if (conv.options.dsThinking) {
      body.output_config = { effort: conv.options.dsEffort };
    }

    const blocks: DsBlock[] = [];
    const active: Map<number, DsStreamBlock> = new Map();
    const toolCalls: ToolCallInfo[] = [];
    let done = false;
    let stopReason = '';
    let inputTokens = 0;
    let outputTokens = 0;

    const onEvent = (e: SseEvent): void => {
      if (e.data.length === 0 || e.data === '[DONE]') {
        return;
      }
      let ev: DsEvent;
      try {
        ev = JSON.parse(e.data) as DsEvent;
      } catch (parseErr) {
        throw new ChatError('DeepSeek 响应解析失败');
      }
      const type = ev.type ?? e.event;
      if (ev.error !== undefined && (type === '' || type === 'error')) {
        throw new ChatError(ev.error.message ?? 'DeepSeek 服务返回错误');
      }
      switch (type) {
        case 'message_start': {
          if (ev.message !== undefined && ev.message.usage !== undefined) {
            inputTokens = (ev.message.usage.input_tokens ?? 0) + (ev.message.usage.cache_read_input_tokens ?? 0);
          }
          break;
        }
        case 'content_block_start': {
          const cb = ev.content_block;
          if (cb === undefined || ev.index === undefined) {
            break;
          }
          const sb = new DsStreamBlock();
          sb.type = cb.type ?? '';
          sb.id = cb.id ?? '';
          sb.name = cb.name ?? '';
          sb.text = cb.text ?? '';
          sb.thinking = cb.thinking ?? '';
          active.set(ev.index, sb);
          if (sb.type === 'thinking') {
            sink.status(MsgStatus.THINKING);
          } else if (sb.type === 'tool_use') {
            sink.status(MsgStatus.ANSWERING);
            sink.toolStart(sb.id, sb.name);
          } else if (sb.type === 'text') {
            sink.status(MsgStatus.ANSWERING);
          }
          break;
        }
        case 'content_block_delta': {
          const sb = ev.index !== undefined ? active.get(ev.index) : undefined;
          const d = ev.delta;
          if (sb === undefined || d === undefined) {
            break;
          }
          if (d.type === 'thinking_delta') {
            const t = d.thinking ?? '';
            sb.thinking += t;
            sink.thinkingDelta(t);
          } else if (d.type === 'signature_delta') {
            sb.signature += d.signature ?? '';
          } else if (d.type === 'text_delta') {
            const t = d.text ?? '';
            sb.text += t;
            sink.textDelta(t);
          } else if (d.type === 'input_json_delta') {
            const frag = d.partial_json ?? '';
            sb.argsJson += frag;
            sink.toolArgs(sb.id, frag);
          }
          break;
        }
        case 'content_block_stop': {
          const sb = ev.index !== undefined ? active.get(ev.index) : undefined;
          if (sb === undefined) {
            break;
          }
          active.delete(ev.index ?? 0);
          if (sb.type === 'thinking') {
            const block: DsBlock = { type: 'thinking', thinking: sb.thinking, signature: sb.signature };
            blocks.push(block);
          } else if (sb.type === 'text') {
            if (sb.text.length > 0) {
              blocks.push({ type: 'text', text: sb.text });
            }
          } else if (sb.type === 'tool_use') {
            let input: Record<string, Object> = {};
            try {
              input = JSON.parse(sb.argsJson.length > 0 ? sb.argsJson : '{}') as Record<string, Object>;
            } catch (e) {
              input = {};
            }
            blocks.push({ type: 'tool_use', id: sb.id, name: sb.name, input: input });
            toolCalls.push(new ToolCallInfo(sb.id, sb.name, sb.argsJson));
            sink.toolReady(sb.id, sb.argsJson);
          }
          break;
        }
        case 'message_delta': {
          if (ev.delta !== undefined) {
            stopReason = ev.delta.stop_reason ?? stopReason;
          }
          if (ev.usage !== undefined) {
            outputTokens = ev.usage.output_tokens ?? outputTokens;
          }
          break;
        }
        case 'message_stop': {
          done = true;
          break;
        }
        default:
          break;
      }
    };

    sink.status(MsgStatus.REQUESTING);
    await streamPost(`${trimBaseUrl(baseUrl)}/v1/messages`, { 'x-api-key': apiKey },
      JSON.stringify(body), onEvent, handle);

    if (!done) {
      throw new ChatError('连接中断，响应不完整，已保留收到的内容');
    }
    if (inputTokens > 0 || outputTokens > 0) {
      sink.usage(`输入 ${inputTokens} · 输出 ${outputTokens} tokens`);
    }
    const result = new PhaseResult();
    result.payload = JSON.stringify(blocks);
    result.toolCalls = toolCalls;
    result.stopReason = stopReason;
    return result;
  }

  private buildMessages(conv: Conversation): DsMessage[] {
    const out: DsMessage[] = [];
    for (const msg of conv.messages) {
      if (msg.role === Role.USER) {
        out.push({ role: 'user', content: msg.textContent() });
        continue;
      }
      for (const phase of msg.phases) {
        let content: DsBlock[] = [];
        try {
          content = JSON.parse(phase) as DsBlock[];
        } catch (e) {
          continue;
        }
        out.push({ role: 'assistant', content: content });
        const results: DsBlock[] = [];
        for (const b of content) {
          if (b.type === 'tool_use' && b.id !== undefined) {
            results.push({ type: 'tool_result', tool_use_id: b.id, content: toolResultFor(msg, b.id) });
          }
        }
        if (results.length > 0) {
          out.push({ role: 'user', content: results });
        }
      }
    }
    return out;
  }
}