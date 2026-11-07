import { Conversation, Role, MsgStatus } from '../model/Types';
import { streamPost, StreamHandle, SseEvent, ChatError } from '../net/HttpClient';
import { ProviderAdapter, PhaseResult, StreamSink, ToolCallInfo, toolResultFor, trimBaseUrl } from './Base';
import { TOOL_DEFS, ToolSchema } from '../tools/ToolService';

interface OaiReasoning {
  effort?: string;
  summary?: string;
  mode?: string;
}

interface OaiTool {
  type: string;
  name: string;
  description: string;
  parameters: ToolSchema;
  strict: boolean;
}

interface OaiRequest {
  model: string;
  input: Object[];
  stream: boolean;
  store: boolean;
  include: string[];
  reasoning?: OaiReasoning;
  tools: OaiTool[];
  tool_choice: string;
  service_tier?: string;
}

interface OaiItem {
  type?: string;
  id?: string;
  call_id?: string;
  name?: string;
  arguments?: string;
  status?: string;
}

interface OaiUsage {
  input_tokens?: number;
  output_tokens?: number;
}

interface OaiError {
  message?: string;
  code?: string;
}

interface OaiIncomplete {
  reason?: string;
}

interface OaiResponse {
  status?: string;
  usage?: OaiUsage;
  error?: OaiError;
  incomplete_details?: OaiIncomplete;
}

interface OaiEvent {
  type?: string;
  output_index?: number;
  item_id?: string;
  item?: OaiItem;
  delta?: string;
  text?: string;
  arguments?: string;
  response?: OaiResponse;
  error?: OaiError;
  message?: string;
  code?: string;
}

interface OaiUserContent {
  type: string;
  text: string;
}

interface OaiUserMessage {
  role: string;
  content: OaiUserContent[];
}

interface OaiFunctionOutput {
  type: string;
  call_id: string;
  output: string;
}

export class OpenAIAdapter implements ProviderAdapter {
  async streamPhase(conv: Conversation, apiKey: string, baseUrl: string, sink: StreamSink,
    handle: StreamHandle): Promise<PhaseResult> {
    const input = this.buildInput(conv);
    const tools: OaiTool[] = [];
    for (const t of TOOL_DEFS) {
      tools.push({
        type: 'function',
        name: t.name,
        description: t.description,
        parameters: t.schema,
        strict: false
      });
    }
    const body: OaiRequest = {
      model: conv.model,
      input: input,
      stream: true,
      store: false,
      include: ['reasoning.encrypted_content'],
      tools: tools,
      tool_choice: 'auto'
    };
    if (conv.options.oaiEffort === 'none') {
      body.reasoning = { effort: 'none' };
    } else {
      body.reasoning = { effort: conv.options.oaiEffort, summary: 'auto', mode: conv.options.oaiMode };
    }
    if (conv.options.oaiTier !== 'standard') {
      body.service_tier = conv.options.oaiTier;
    }

    const outputItems: OaiItem[] = [];
    const toolCalls: ToolCallInfo[] = [];
    const argsAcc: Map<string, string> = new Map();
    const itemToCall: Map<string, string> = new Map();
    let done = false;
    let stopReason = 'end';
    let usageText = '';

    const onEvent = (e: SseEvent): void => {
      if (e.data.length === 0 || e.data === '[DONE]') {
        return;
      }
      let ev: OaiEvent;
      try {
        ev = JSON.parse(e.data) as OaiEvent;
      } catch (parseErr) {
        throw new ChatError('OpenAI 响应解析失败');
      }
      const type = ev.type ?? e.event;
      switch (type) {
        case 'response.output_item.added': {
          const item = ev.item;
          if (item === undefined) {
            break;
          }
          if (item.type === 'reasoning') {
            sink.status(MsgStatus.THINKING);
          } else if (item.type === 'message') {
            sink.status(MsgStatus.ANSWERING);
          } else if (item.type === 'function_call') {
            const callId = item.call_id ?? '';
            const itemId = item.id ?? '';
            itemToCall.set(itemId, callId);
            argsAcc.set(itemId, '');
            sink.status(MsgStatus.ANSWERING);
            sink.toolStart(callId, item.name ?? '');
          }
          break;
        }
        case 'response.reasoning_summary_text.delta': {
          sink.thinkingDelta(ev.delta ?? '');
          break;
        }
        case 'response.output_text.delta': {
          sink.status(MsgStatus.ANSWERING);
          sink.textDelta(ev.delta ?? '');
          break;
        }
        case 'response.function_call_arguments.delta': {
          const itemId = ev.item_id ?? '';
          const frag = ev.delta ?? '';
          argsAcc.set(itemId, (argsAcc.get(itemId) ?? '') + frag);
          sink.toolArgs(itemToCall.get(itemId) ?? '', frag);
          break;
        }
        case 'response.function_call_arguments.done': {
          const itemId = ev.item_id ?? '';
          argsAcc.set(itemId, ev.arguments ?? argsAcc.get(itemId) ?? '');
          break;
        }
        case 'response.output_item.done': {
          const item = ev.item;
          if (item === undefined) {
            break;
          }
          outputItems.push(item);
          if (item.type === 'function_call') {
            const callId = item.call_id ?? '';
            const args = item.arguments ?? argsAcc.get(item.id ?? '') ?? '{}';
            toolCalls.push(new ToolCallInfo(callId, item.name ?? '', args));
            sink.toolReady(callId, args);
          }
          break;
        }
        case 'response.completed': {
          done = true;
          const usage = ev.response?.usage;
          if (usage !== undefined) {
            usageText = `输入 ${usage.input_tokens ?? 0} · 输出 ${usage.output_tokens ?? 0} tokens`;
          }
          break;
        }
        case 'response.incomplete': {
          done = true;
          stopReason = ev.response?.incomplete_details?.reason ?? 'incomplete';
          break;
        }
        case 'response.failed': {
          throw new ChatError(ev.response?.error?.message ?? 'OpenAI 生成失败');
        }
        case 'error': {
          throw new ChatError(ev.message ?? ev.error?.message ?? 'OpenAI 服务返回错误');
        }
        default:
          break;
      }
    };

    sink.status(MsgStatus.REQUESTING);
    await streamPost(`${trimBaseUrl(baseUrl)}/responses`, { 'Authorization': `Bearer ${apiKey}` },
      JSON.stringify(body), onEvent, handle);

    if (!done) {
      throw new ChatError('连接中断，响应不完整，已保留收到的内容');
    }
    if (usageText.length > 0) {
      sink.usage(usageText);
    }
    const result = new PhaseResult();
    result.payload = JSON.stringify(outputItems);
    result.toolCalls = toolCalls;
    result.stopReason = stopReason;
    return result;
  }

  private buildInput(conv: Conversation): Object[] {
    const out: Object[] = [];
    for (const msg of conv.messages) {
      if (msg.role === Role.USER) {
        const um: OaiUserMessage = { role: 'user', content: [{ type: 'input_text', text: msg.textContent() }] };
        out.push(um);
        continue;
      }
      for (const phase of msg.phases) {
        let items: OaiItem[] = [];
        try {
          items = JSON.parse(phase) as OaiItem[];
        } catch (e) {
          continue;
        }
        const callIds: string[] = [];
        for (const item of items) {
          out.push(item);
          if (item.type === 'function_call' && item.call_id !== undefined) {
            callIds.push(item.call_id);
          }
        }
        for (const callId of callIds) {
          const fo: OaiFunctionOutput = {
            type: 'function_call_output',
            call_id: callId,
            output: toolResultFor(msg, callId)
          };
          out.push(fo);
        }
      }
    }
    return out;
  }
}