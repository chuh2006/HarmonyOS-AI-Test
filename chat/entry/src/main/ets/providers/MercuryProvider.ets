import {
  Message,
  ModelConfig,
  StreamEvent,
  ToolCall,
  ProviderSettings,
  TokenUsage,
  ChatError
} from '../types/Types';
import { httpStreamRequest, AbortSignal } from '../services/HttpStream';
import { hasItems, hasText, listOr, numberOr, present, textOr } from '../services/Json';
import { ChatProvider, StreamChatCallbacks } from './IProtocol';

// ===== Chat Completions API 结构 =====

export interface MercuryFunctionDef {
  name: string;
  arguments: string;
}

export interface MercuryToolCallJson {
  id?: string;
  type?: string;
  function?: MercuryFunctionDef;
}

export interface MercuryMessageJson {
  role: string;
  content?: string;
  tool_calls?: MercuryToolCallJson[];
  tool_call_id?: string;
}

export interface MercuryFunctionSchemaProperty {
  type: string;
  description: string;
}

export interface MercuryFunctionSchemaProperties {
  query?: MercuryFunctionSchemaProperty;
  url?: MercuryFunctionSchemaProperty;
}

export interface MercuryFunctionSchema {
  type: string;
  properties: MercuryFunctionSchemaProperties;
  required: string[];
}

export interface MercuryFunctionDef2 {
  name: string;
  description: string;
  parameters: MercuryFunctionSchema;
}

export interface MercuryTool {
  type: string; // 'function'
  function: MercuryFunctionDef2;
}

export interface MercuryRequest {
  model: string;
  messages: MercuryMessageJson[];
  stream: boolean;
  diffusing?: boolean;          // TASK.md: 扩散输出 stream:true + diffusing:true
  max_tokens?: number;
  tools?: MercuryTool[];
  reasoning_effort?: string;    // 思考强度(官方文档参数)
}

// ===== 流式响应结构 =====

// 普通模式: delta增量帧; 扩散模式: message全量帧
export interface MercuryDeltaJson {
  role?: string;
  content?: string;
  reasoning_content?: string;
  tool_calls?: MercuryToolCallJson[];
}

export interface MercuryChoiceJson {
  index: number;
  delta?: MercuryDeltaJson;
  message?: MercuryMessageJson;
  finish_reason?: string;
  text?: string; // 扩散去噪过程字段兼容
}

export interface MercuryUsageJson {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
}

export interface MercuryStreamChunkJson {
  id?: string;
  object?: string;
  created?: number;
  model?: string;
  choices?: MercuryChoiceJson[];
  usage?: MercuryUsageJson;
}

// 工具调用累加状态(按call id去重，保证同一次调用只执行一次)
interface PendingTool {
  id: string;
  name: string;
  argsBuffer: string;
  emitted: boolean;
}

export class MercuryProvider implements ChatProvider {
  private apiKey: string;
  private baseUrl: string;

  constructor(settings: ProviderSettings) {
    this.apiKey = settings.apiKey;
    this.baseUrl = settings.baseUrl !== undefined && settings.baseUrl.length > 0
      ? settings.baseUrl
      : 'https://api.inceptionlabs.ai';
  }

  private convertMessages(messages: Message[]): MercuryMessageJson[] {
    const result: MercuryMessageJson[] = [];

    for (const msg of messages) {
      if (msg.role === 'tool') {
        // 工具结果消息
        for (const tc of listOr(msg.toolCalls)) {
          const toolMsg: MercuryMessageJson = {
            role: 'tool',
            tool_call_id: tc.id,
            content: tc.result !== undefined ? tc.result : (tc.error !== undefined ? `工具执行失败: ${tc.error}` : '')
          };
          result.push(toolMsg);
        }
        continue;
      }

      const hasCalls: boolean = msg.role === 'assistant' && hasItems(msg.toolCalls);
      if (msg.content.length === 0 && !hasCalls) {
        continue; // 失败或被停止的空消息不进上下文
      }

      const outMsg: MercuryMessageJson = { role: msg.role };
      if (msg.content.length > 0) {
        outMsg.content = msg.content;
      }

      if (hasCalls) {
        const calls: MercuryToolCallJson[] = [];
        for (const tc of msg.toolCalls as ToolCall[]) {
          const fn: MercuryFunctionDef = { name: tc.type, arguments: tc.arguments };
          const call: MercuryToolCallJson = { id: tc.id, type: 'function', function: fn };
          calls.push(call);
        }
        outMsg.tool_calls = calls;
      }

      result.push(outMsg);
    }

    return result;
  }

  private getToolDefinitions(): MercuryTool[] {
    const queryProp: MercuryFunctionSchemaProperty = { type: 'string', description: '搜索关键词' };
    const searchProps: MercuryFunctionSchemaProperties = { query: queryProp };
    const searchSchema: MercuryFunctionSchema = { type: 'object', properties: searchProps, required: ['query'] };
    const searchFn: MercuryFunctionDef2 = {
      name: 'search',
      description: '按关键词搜索网页，返回标题、链接与摘要',
      parameters: searchSchema
    };
    const searchTool: MercuryTool = { type: 'function', function: searchFn };

    const urlProp: MercuryFunctionSchemaProperty = { type: 'string', description: '要抓取的网页完整URL' };
    const fetchProps: MercuryFunctionSchemaProperties = { url: urlProp };
    const fetchSchema: MercuryFunctionSchema = { type: 'object', properties: fetchProps, required: ['url'] };
    const fetchFn: MercuryFunctionDef2 = {
      name: 'fetch',
      description: '抓取单个网页，以Markdown文本返回页面内容',
      parameters: fetchSchema
    };
    const fetchTool: MercuryTool = { type: 'function', function: fetchFn };

    return [searchTool, fetchTool];
  }

  streamChat(
    messages: Message[],
    config: ModelConfig,
    callbacks: StreamChatCallbacks,
    abortSignal?: AbortSignal
  ): void {
    const url: string = `${this.baseUrl}/v1/chat/completions`;
    // TASK.md: 默认开启扩散输出，用户可以切换
    const useDiffusion: boolean = config.diffusionEnabled === undefined || config.diffusionEnabled;

    const requestBody: MercuryRequest = {
      model: config.modelId,
      messages: this.convertMessages(messages),
      stream: true,
      max_tokens: config.maxTokens !== undefined ? config.maxTokens : 65536,
      tools: this.getToolDefinitions()
    };

    if (useDiffusion) {
      requestBody.diffusing = true;
    }

    // 思考强度(官方文档参数)
    if (config.thinkingEnabled && config.thinkingEffort !== 'none') {
      requestBody.reasoning_effort = config.thinkingEffort;
    }

    // ===== 流式解析状态 =====
    // TASK.md: 正确处理普通增量与扩散全量帧的不同语义；
    // 处理多个生成阶段，避免最后一帧丢失、内容被清空或阶段互相覆盖
    let finalizedContent: string = '';   // 已完成阶段的文本(工具调用前的阶段)
    let currentContent: string = '';     // 当前阶段文本(扩散模式下被全量帧反复修订)
    let currentThinking: string = '';
    const pendingTools: PendingTool[] = [];
    let completed: boolean = false;
    let sawFinishReason: boolean = false;
    let sawDone: boolean = false;

    const emitContent = (): void => {
      // 扩散与增量统一用content_replace上抛完整当前文本，UI直接替换显示
      const full: string = finalizedContent + currentContent;
      const event: StreamEvent = { type: 'content_replace', data: full };
      callbacks.onEvent(event);
    };

    const emitComplete = (): void => {
      if (completed) {
        return;
      }
      completed = true;
      const event: StreamEvent = { type: 'complete' };
      callbacks.onEvent(event);
    };

    // 处理帧内tool_calls。
    // 增量帧累加参数；扩散全量帧的语义官方文档未明确，用前缀判断兼容两种情况：
    // 新值以已累积内容为前缀说明是完整快照(直接替换)，否则按增量累加。
    const handleToolCalls = (calls: MercuryToolCallJson[], fullFrame: boolean): void => {
      for (const callJson of calls) {
        if (callJson === undefined || callJson === null) {
          continue;
        }
        const fn: MercuryFunctionDef | undefined = callJson.function;
        const fnName: string = fn !== undefined && fn !== null ? textOr(fn.name) : '';
        const fnArgs: string = fn !== undefined && fn !== null ? textOr(fn.arguments) : '';
        const callId: string = textOr(callJson.id);

        // 查找已有pending(按id，id为空时按name+未完成状态)
        let pending: PendingTool | null = null;
        for (const p of pendingTools) {
          if (!p.emitted && ((callId.length > 0 && p.id === callId) ||
            (callId.length === 0 && p.name === fnName && fnName.length > 0))) {
            pending = p;
            break;
          }
        }

        if (pending === null) {
          // 新工具调用
          const newPending: PendingTool = {
            id: callId.length > 0 ? callId : `call_${Date.now()}_${pendingTools.length}`,
            name: fnName,
            argsBuffer: fnArgs,
            emitted: false
          };
          pendingTools.push(newPending);
          const tc: ToolCall = {
            id: newPending.id,
            type: newPending.name === 'fetch' ? 'fetch' : 'search',
            arguments: newPending.argsBuffer,
            status: 'running'
          };
          const startEvent: StreamEvent = { type: 'tool_call_start', toolCall: tc };
          callbacks.onEvent(startEvent);
        } else {
          if (callId.length > 0 && pending.id.length === 0) {
            pending.id = callId;
          }
          if (fnName.length > 0 && pending.name.length === 0) {
            pending.name = fnName;
          }
          if (fullFrame && fnArgs.startsWith(pending.argsBuffer)) {
            pending.argsBuffer = fnArgs;
          } else {
            pending.argsBuffer += fnArgs;
          }

          const tc: ToolCall = {
            id: pending.id,
            type: pending.name === 'fetch' ? 'fetch' : 'search',
            arguments: pending.argsBuffer,
            status: 'running'
          };
          const deltaEvent: StreamEvent = { type: 'tool_call_delta', toolCall: tc };
          callbacks.onEvent(deltaEvent);
        }
      }
    };

    // 应用一帧正文/思考/工具调用
    const applyFrame = (frame: MercuryDeltaJson, isMessageFrame: boolean): void => {
      if (hasText(frame.reasoning_content)) {
        const think: string = textOr(frame.reasoning_content);
        currentThinking += think;
        const thinkEvent: StreamEvent = { type: 'thinking_delta', data: think };
        callbacks.onEvent(thinkEvent);
      }

      // TASK.md: 只有结束信息、没有正文的事件不能清空已有内容
      if (hasText(frame.content)) {
        const text: string = textOr(frame.content);
        // 官方文档: 扩散模式下每个chunk的content是当前阶段的全量文本，覆盖显示
        if (useDiffusion || isMessageFrame) {
          currentContent = text;
        } else {
          currentContent += text;
        }
        emitContent();
      }

      if (hasItems(frame.tool_calls)) {
        handleToolCalls(frame.tool_calls as MercuryToolCallJson[], useDiffusion || isMessageFrame);
      }
    };

    // 结束帧才是参数完整的权威信号，此时统一发射待执行的调用(同一次调用只发射一次)
    const flushPendingTools = (): void => {
      for (const p of pendingTools) {
        if (p.emitted || p.name.length === 0) {
          continue;
        }
        p.emitted = true;
        const tc: ToolCall = {
          id: p.id,
          type: p.name === 'fetch' ? 'fetch' : 'search',
          arguments: p.argsBuffer.length > 0 ? p.argsBuffer : '{}',
          status: 'pending'
        };
        const endEvent: StreamEvent = { type: 'tool_call_end', toolCall: tc };
        callbacks.onEvent(endEvent);
      }
    };

    httpStreamRequest(
      {
        url: url,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${this.apiKey}`
        },
        body: JSON.stringify(requestBody),
        timeout: 300000,
        provider: 'mercury'
      },
      {
        onData: (data: string) => {
          if (completed) {
            return;
          }
          const trimmed: string = data.trim();
          if (trimmed.length === 0) {
            return;
          }
          if (trimmed === '[DONE]') {
            sawDone = true;
            return;
          }

          let chunk: MercuryStreamChunkJson;
          try {
            chunk = JSON.parse(trimmed) as MercuryStreamChunkJson;
          } catch (e) {
            return;
          }

          if (present(chunk.usage)) {
            const usageJson: MercuryUsageJson = chunk.usage as MercuryUsageJson;
            const usage: TokenUsage = {
              inputTokens: numberOr(usageJson.prompt_tokens),
              outputTokens: numberOr(usageJson.completion_tokens)
            };
            const usageEvent: StreamEvent = { type: 'usage', usage: usage };
            callbacks.onEvent(usageEvent);
          }

          // 只有元信息的帧；choices 也可能是显式 null
          if (!hasItems(chunk.choices)) {
            return;
          }

          const choice: MercuryChoiceJson = (chunk.choices as MercuryChoiceJson[])[0];

          // 流式帧: delta。扩散模式下 content 是当前阶段的全量文本，普通模式下是增量
          if (present(choice.delta)) {
            const delta: MercuryDeltaJson = choice.delta as MercuryDeltaJson;
            applyFrame(delta, false);
          }

          // 兼容非流式形状: message
          if (present(choice.message)) {
            const msgJson: MercuryMessageJson = choice.message as MercuryMessageJson;
            const asDelta: MercuryDeltaJson = {
              content: msgJson.content,
              tool_calls: msgJson.tool_calls
            };
            applyFrame(asDelta, true);
          }

          // 结束帧: 定格最终文本(TASK.md: 扩散结束时准确显示最终文本)
          if (present(choice.finish_reason)) {
            const reason: string = textOr(choice.finish_reason);
            sawFinishReason = true;
            flushPendingTools();
            if (reason === 'tool_calls') {
              // 当前阶段定格，工具回传后是新阶段，避免阶段互相覆盖
              finalizedContent += currentContent;
              currentContent = '';
            } else {
              emitComplete();
            }
          }
        },

        onComplete: () => {
          if (!sawFinishReason && !sawDone && !completed) {
            // 没有结束帧也没有[DONE]，说明连接被提前关闭，已收到的内容仍然保留
            const errEvent: StreamEvent = { type: 'error', error: '响应在结束帧前中断，请重试' };
            callbacks.onEvent(errEvent);
          }
          flushPendingTools();
          // 连接结束前若有未上抛的当前内容，最后上抛一次，避免最后一帧丢失
          if (currentContent.length > 0 || finalizedContent.length > 0) {
            emitContent();
          }
          emitComplete();
          callbacks.onComplete();
        },

        onError: (error: ChatError) => {
          callbacks.onError(error);
        }
      },
      abortSignal
    );
  }
}
