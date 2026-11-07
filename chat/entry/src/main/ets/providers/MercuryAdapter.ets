import { Conversation, Role, MsgStatus } from '../model/Types';
import { streamPost, StreamHandle, SseEvent, ChatError } from '../net/HttpClient';
import { ProviderAdapter, PhaseResult, StreamSink, ToolCallInfo, toolResultFor, trimBaseUrl, joinTexts } from './Base';
import { TOOL_DEFS, ToolSchema } from '../tools/ToolService';

interface MercFunction {
  name: string;
  arguments: string;
}

interface MercToolCall {
  id: string;
  type: string;
  function: MercFunction;
}

interface MercMessage {
  role: string;
  content?: string;
  tool_calls?: MercToolCall[];
  tool_call_id?: string;
}

interface MercToolDef {
  name: string;
  description: string;
  parameters: ToolSchema;
}

interface MercTool {
  type: string;
  function: MercToolDef;
}

interface MercRequest {
  model: string;
  messages: MercMessage[];
  stream: boolean;
  diffusing: boolean;
  reasoning_effort: string;
  max_completion_tokens: number;
  tools: MercTool[];
  tool_choice: string;
}

interface MercFunctionDelta {
  name?: string;
  arguments?: string;
}

interface MercToolCallDelta {
  index?: number;
  id?: string;
  type?: string;
  function?: MercFunctionDelta;
}

interface MercDelta {
  role?: string;
  content?: string;
  reasoning_content?: string;
  tool_calls?: MercToolCallDelta[];
}

interface MercChoice {
  index?: number;
  delta?: MercDelta;
  finish_reason?: string;
}

interface MercUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
}

interface MercError {
  message?: string;
}

interface MercChunk {
  choices?: MercChoice[];
  usage?: MercUsage;
  error?: MercError;
}

class MercToolAssembly {
  id: string = '';
  name: string = '';
  args: string = '';
  started: boolean = false;
}

export class MercuryAdapter implements ProviderAdapter {
  async streamPhase(conv: Conversation, apiKey: string, baseUrl: string, sink: StreamSink,
    handle: StreamHandle): Promise<PhaseResult> {
    const messages = this.buildMessages(conv);
    const tools: MercTool[] = [];
    for (const t of TOOL_DEFS) {
      tools.push({
        type: 'function',
        function: { name: t.name, description: t.description, parameters: t.schema }
      });
    }
    const body: MercRequest = {
      model: conv.model,
      messages: messages,
      stream: true,
      diffusing: conv.options.mercDiffusing,
      reasoning_effort: conv.options.mercEffort,
      max_completion_tokens: 32768,
      tools: tools,
      tool_choice: 'auto'
    };

    const diffusing = conv.options.mercDiffusing;
    const textBlocks: string[] = [];
    let currentText = '';
    let needNewBlock = false;
    let sawContent = false;
    const assemblies: Map<number, MercToolAssembly> = new Map();
    let finishReason = '';
    let sawDone = false;
    let usageText = '';

    const onEvent = (e: SseEvent): void => {
      if (e.data.length === 0) {
        return;
      }
      if (e.data === '[DONE]') {
        sawDone = true;
        return;
      }
      let chunk: MercChunk;
      try {
        chunk = JSON.parse(e.data) as MercChunk;
      } catch (parseErr) {
        throw new ChatError('Mercury 响应解析失败');
      }
      if (chunk.error !== undefined) {
        throw new ChatError(chunk.error.message ?? 'Mercury 服务返回错误');
      }
      if (chunk.usage !== undefined) {
        usageText = `输入 ${chunk.usage.prompt_tokens ?? 0} · 输出 ${chunk.usage.completion_tokens ?? 0} tokens`;
      }
      const choices = chunk.choices ?? [];
      for (const choice of choices) {
        const delta = choice.delta;
        if (delta !== undefined) {
          if (delta.reasoning_content !== undefined && delta.reasoning_content.length > 0) {
            sink.status(MsgStatus.THINKING);
            sink.thinkingDelta(delta.reasoning_content);
          }
          if (delta.content !== undefined && delta.content !== null && delta.content.length > 0) {
            if (needNewBlock) {
              textBlocks.push(currentText);
              currentText = '';
              needNewBlock = false;
              sink.newTextBlock();
            }
            sawContent = true;
            sink.status(MsgStatus.ANSWERING);
            if (diffusing) {
              currentText = delta.content;
              sink.textSnapshot(currentText);
            } else {
              currentText += delta.content;
              sink.textDelta(delta.content);
            }
          }
          const tcs = delta.tool_calls ?? [];
          for (const tcd of tcs) {
            if (sawContent || currentText.length > 0) {
              needNewBlock = true;
            }
            const idx = tcd.index ?? 0;
            let asm = assemblies.get(idx);
            if (asm === undefined) {
              asm = new MercToolAssembly();
              assemblies.set(idx, asm);
            }
            if (tcd.id !== undefined && tcd.id.length > 0) {
              asm.id = tcd.id;
            }
            if (tcd.function !== undefined) {
              if (tcd.function.name !== undefined) {
                asm.name += tcd.function.name;
              }
              if (tcd.function.arguments !== undefined) {
                const frag = tcd.function.arguments;
                asm.args += frag;
                if (asm.id.length > 0) {
                  sink.toolArgs(asm.id, frag);
                }
              }
            }
            if (!asm.started && asm.id.length > 0) {
              asm.started = true;
              sink.status(MsgStatus.ANSWERING);
              sink.toolStart(asm.id, asm.name);
            }
          }
        }
        if (choice.finish_reason !== undefined && choice.finish_reason !== null && choice.finish_reason.length > 0) {
          finishReason = choice.finish_reason;
        }
      }
    };

    sink.status(MsgStatus.REQUESTING);
    await streamPost(`${trimBaseUrl(baseUrl)}/chat/completions`, { 'Authorization': `Bearer ${apiKey}` },
      JSON.stringify(body), onEvent, handle);

    if (!sawDone && finishReason.length === 0) {
      throw new ChatError('连接中断，响应不完整，已保留收到的内容');
    }
    if (currentText.length > 0) {
      textBlocks.push(currentText);
    }
    const toolCalls: ToolCallInfo[] = [];
    const payloadCalls: MercToolCall[] = [];
    const keys = Array.from(assemblies.keys()).sort((a: number, b: number) => a - b);
    for (const k of keys) {
      const asm = assemblies.get(k);
      if (asm === undefined || asm.id.length === 0) {
        continue;
      }
      const args = asm.args.length > 0 ? asm.args : '{}';
      toolCalls.push(new ToolCallInfo(asm.id, asm.name, args));
      payloadCalls.push({ id: asm.id, type: 'function', function: { name: asm.name, arguments: args } });
      sink.toolReady(asm.id, args);
    }
    if (usageText.length > 0) {
      sink.usage(usageText);
    }
    const payload: MercMessage = { role: 'assistant', content: joinTexts(textBlocks) };
    if (payloadCalls.length > 0) {
      payload.tool_calls = payloadCalls;
    }
    const result = new PhaseResult();
    result.payload = JSON.stringify(payload);
    result.toolCalls = toolCalls;
    result.stopReason = finishReason;
    return result;
  }

  private buildMessages(conv: Conversation): MercMessage[] {
    const out: MercMessage[] = [];
    for (const msg of conv.messages) {
      if (msg.role === Role.USER) {
        out.push({ role: 'user', content: msg.textContent() });
        continue;
      }
      for (const phase of msg.phases) {
        let assistant: MercMessage;
        try {
          assistant = JSON.parse(phase) as MercMessage;
        } catch (e) {
          continue;
        }
        out.push(assistant);
        const calls = assistant.tool_calls ?? [];
        for (const tc of calls) {
          out.push({ role: 'tool', tool_call_id: tc.id, content: toolResultFor(msg, tc.id) });
        }
      }
    }
    return out;
  }
}