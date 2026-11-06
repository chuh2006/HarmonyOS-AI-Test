import {
  AppSettings,
  ChatError,
  ContentPart,
  DeepSeekProtocolData,
  GeminiProtocolData,
  Message,
  ModelConfig,
  OpenAIProtocolData,
  ProtocolData,
  ProviderId,
  ProviderSettings,
  Session,
  StreamEvent,
  StreamProtocolData,
  ThoughtSignatureEntry,
  ToolCall,
  ToolStatus,
  generateId,
  getProviderSettings
} from '../types/Types';
import { ChatProvider, StreamChatCallbacks } from '../providers/IProtocol';
import { DeepSeekProvider } from '../providers/DeepSeekProvider';
import { OpenAIProvider } from '../providers/OpenAIProvider';
import { MercuryProvider } from '../providers/MercuryProvider';
import { GeminiProvider } from '../providers/GeminiProvider';
import { DeepSeekTools, ToolResult } from './DeepSeekTools';
import { AbortSignal } from './HttpStream';
import { hasItems, hasText } from './Json';
import { Store, MessagePatch } from './Store';

// UI 回调
export interface ChatCallbacks {
  onMessageUpdate: (message: Message) => void;
  onToolCallUpdate: (messageId: string, toolCall: ToolCall) => void;
  onError: (error: ChatError) => void;
  onComplete: (message: Message) => void;
}

// 生成阶段
export type GenerationPhase =
  | 'idle'
  | 'requesting'
  | 'thinking'
  | 'tool_calling'
  | 'answering'
  | 'complete'
  | 'error';

// 工具调用循环上限
const MAX_TOOL_ITERATIONS: number = 10;

// 一次流式请求累积的结果
class StreamAccumulator {
  content: string = '';
  thinking: string = '';
  toolCalls: ToolCall[] = [];
  protocolData: StreamProtocolData | null = null;
  error: ChatError | null = null;
  hasToolCalls: boolean = false;
}

function cloneToolCall(toolCall: ToolCall, status: ToolStatus): ToolCall {
  const copy: ToolCall = {
    id: toolCall.id,
    type: toolCall.type,
    arguments: toolCall.arguments,
    status: status,
    result: toolCall.result,
    resultSummary: toolCall.resultSummary,
    error: toolCall.error,
    startTime: toolCall.startTime,
    endTime: toolCall.endTime
  };
  return copy;
}

function findToolCall(toolCalls: ToolCall[], id: string): ToolCall | null {
  for (const tc of toolCalls) {
    if (tc.id === id) {
      return tc;
    }
  }
  return null;
}

// 工具结果必须覆盖 assistant 发起的全部调用
function coversAllToolCalls(calls: ToolCall[], results: ToolCall[] | undefined): boolean {
  if (results === undefined || results === null) {
    return false;
  }
  for (const call of calls) {
    if (findToolCall(results, call.id) === null) {
      return false;
    }
  }
  return true;
}

function withoutToolCalls(message: Message): Message {
  const copy: Message = {
    id: message.id,
    role: message.role,
    content: message.content,
    thinking: message.thinking,
    status: message.status,
    timestamp: message.timestamp,
    error: message.error,
    protocolData: message.protocolData
  };
  return copy;
}

export class ChatEngine {
  private store: Store;
  private settings: AppSettings;
  private abortSignal: AbortSignal = { aborted: false };
  private phase: GenerationPhase = 'idle';
  private currentMessageId: string = '';
  // 用于丢弃迟到数据：会话切换或新一轮生成后，旧回调不再写入
  private activeSessionId: string = '';
  private runToken: number = 0;

  constructor(store: Store, settings: AppSettings) {
    this.store = store;
    this.settings = settings;
  }

  updateSettings(settings: AppSettings): void {
    this.settings = settings;
  }

  getPhase(): GenerationPhase {
    return this.phase;
  }

  getCurrentMessageId(): string {
    return this.currentMessageId;
  }

  isGenerating(): boolean {
    return this.phase === 'requesting' || this.phase === 'thinking'
      || this.phase === 'tool_calling' || this.phase === 'answering';
  }

  stop(): void {
    this.abortSignal.aborted = true;
    this.phase = 'idle';
  }

  private isStale(sessionId: string, token: number): boolean {
    return token !== this.runToken || sessionId !== this.activeSessionId;
  }

  private getProvider(config: ModelConfig): ChatProvider {
    const providerSettings: ProviderSettings = getProviderSettings(this.settings.providers, config.providerId);
    if (providerSettings.apiKey.trim().length === 0) {
      throw new ChatError('请先在设置中配置 API Key', 'NO_API_KEY', config.providerId);
    }

    if (config.providerId === 'deepseek') {
      return new DeepSeekProvider(providerSettings);
    }
    if (config.providerId === 'openai') {
      return new OpenAIProvider(providerSettings);
    }
    if (config.providerId === 'mercury') {
      return new MercuryProvider(providerSettings);
    }
    return new GeminiProvider(providerSettings);
  }

  // 发送一条用户消息并生成回复
  async sendMessage(
    sessionId: string,
    content: string,
    config: ModelConfig,
    callbacks: ChatCallbacks
  ): Promise<void> {
    this.abortSignal = { aborted: false };
    this.runToken++;
    this.activeSessionId = sessionId;
    this.phase = 'requesting';

    const token: number = this.runToken;

    const userMessage: Message = {
      id: generateId('msg'),
      role: 'user',
      content: content,
      status: 'complete',
      timestamp: Date.now()
    };

    await this.store.addMessage(sessionId, userMessage);
    if (!this.isStale(sessionId, token)) {
      callbacks.onMessageUpdate(userMessage);
    }

    const session: Session | null = await this.store.getSession(sessionId);
    if (session === null) {
      this.phase = 'error';
      const error: ChatError = new ChatError('会话不存在', 'SESSION_NOT_FOUND', config.providerId);
      callbacks.onError(error);
      throw error;
    }

    await this.generateResponse(sessionId, token, session.messages, config, callbacks);
  }

  // 生成回复，内部处理工具调用多轮循环
  // 组装请求前清洗历史：
  // 出错、被停止或切换会话时，带工具调用的 assistant 消息可能已落库而对应的
  // 工具结果没有落库。Anthropic 要求 tool_use 之后必须紧跟包含全部 tool_result 的
  // user 消息，否则整条请求被拒——一个残缺的工具轮次会让会话之后永远无法继续。
  private sanitizeHistory(history: Message[]): Message[] {
    const result: Message[] = [];

    for (let i = 0; i < history.length; i++) {
      const msg: Message = history[i];

      if (msg.role === 'tool') {
        continue; // 只在 assistant 配对成功时一起push，孤立的工具结果丢弃
      }

      if (msg.role === 'assistant' && hasItems(msg.toolCalls)) {
        const next: Message | null = i + 1 < history.length ? history[i + 1] : null;
        const calls: ToolCall[] = msg.toolCalls as ToolCall[];
        if (next !== null && next.role === 'tool' && coversAllToolCalls(calls, next.toolCalls)) {
          result.push(msg);
          result.push(next);
          i++;
          continue;
        }
        // 缺少工具结果：剥离工具调用，只保留文本，避免整条请求被服务端拒绝
        if (msg.content.trim().length > 0 || hasText(msg.thinking)) {
          result.push(withoutToolCalls(msg));
        }
        continue;
      }

      // 空的占位消息(失败/被停止)不进上下文
      if (msg.role === 'assistant' && msg.content.trim().length === 0 && !hasText(msg.thinking)) {
        continue;
      }
      if (msg.role === 'user' && msg.content.trim().length === 0) {
        continue;
      }

      result.push(msg);
    }

    return result;
  }

  private async generateResponse(
    sessionId: string,
    token: number,
    history: Message[],
    config: ModelConfig,
    callbacks: ChatCallbacks
  ): Promise<void> {
    const messages: Message[] = this.sanitizeHistory(history);
    let iteration: number = 0;

    while (iteration < MAX_TOOL_ITERATIONS) {
      if (this.abortSignal.aborted) {
        this.finishWithError(sessionId, token, callbacks, ChatError.stopped());
        return;
      }
      iteration++;

      const assistant: Message = {
        id: generateId('msg'),
        role: 'assistant',
        content: '',
        status: 'streaming',
        timestamp: Date.now(),
        toolCalls: []
      };
      this.currentMessageId = assistant.id;
      this.phase = 'requesting';

      await this.store.addMessage(sessionId, assistant);
      this.emit(sessionId, token, callbacks, assistant);

      const acc: StreamAccumulator = await this.streamOnce(sessionId, token, messages, config, assistant, callbacks);

      // 迟到的数据不属于当前会话，直接丢弃
      if (this.isStale(sessionId, token)) {
        return;
      }

      if (this.abortSignal.aborted) {
        const stoppedPatch: MessagePatch = {
          content: acc.content,
          thinking: acc.thinking.length > 0 ? acc.thinking : undefined,
          status: 'stopped',
          toolCalls: acc.toolCalls.slice()
        };
        await this.store.updateMessage(sessionId, assistant.id, stoppedPatch);
        assistant.content = acc.content;
        assistant.status = 'stopped';
        assistant.toolCalls = acc.toolCalls.slice();
        this.emit(sessionId, token, callbacks, assistant);
        this.phase = 'idle';
        this.currentMessageId = '';
        callbacks.onError(ChatError.stopped());
        return;
      }

      const hasToolWork: boolean = acc.hasToolCalls && acc.toolCalls.length > 0;
      let streamError: ChatError | null = acc.error;
      if (streamError === null && !hasToolWork
        && acc.content.trim().length === 0 && acc.thinking.trim().length === 0) {
        // 服务端提前断开或响应被丢弃时会走到这里，不能当成一条正常的空回复
        streamError = new ChatError('模型没有返回任何内容，请重试', 'EMPTY_RESPONSE', config.providerId);
      }
      if (streamError !== null) {
        const errorPatch: MessagePatch = {
          content: acc.content,
          thinking: acc.thinking.length > 0 ? acc.thinking : undefined,
          status: 'error',
          error: streamError.message,
          toolCalls: acc.toolCalls.slice()
        };
        await this.store.updateMessage(sessionId, assistant.id, errorPatch);
        assistant.content = acc.content;
        assistant.status = 'error';
        assistant.error = streamError.message;
        this.emit(sessionId, token, callbacks, assistant);
        this.phase = 'error';
        this.currentMessageId = '';
        callbacks.onError(streamError);
        return;
      }

      const protocolData: ProtocolData | undefined = this.toProtocolData(config.providerId, acc.protocolData);

      if (hasToolWork) {
        assistant.content = acc.content;
        assistant.thinking = acc.thinking.length > 0 ? acc.thinking : undefined;
        assistant.status = 'tool_call';
        assistant.protocolData = protocolData;
        assistant.toolCalls = acc.toolCalls.slice();

        const toolPatch: MessagePatch = {
          content: acc.content,
          thinking: assistant.thinking,
          status: 'tool_call',
          toolCalls: assistant.toolCalls,
          protocolData: protocolData
        };
        await this.store.updateMessage(sessionId, assistant.id, toolPatch);
        this.emit(sessionId, token, callbacks, assistant);
        messages.push(assistant);

        this.phase = 'tool_calling';
        const finishedCalls: ToolCall[] =
          await this.executeTools(sessionId, token, assistant.id, assistant.toolCalls, callbacks);

        if (this.isStale(sessionId, token)) {
          return;
        }

        assistant.toolCalls = finishedCalls;
        const resultPatch: MessagePatch = { toolCalls: finishedCalls };
        await this.store.updateMessage(sessionId, assistant.id, resultPatch);
        this.emit(sessionId, token, callbacks, assistant);

        const toolMessage: Message = {
          id: generateId('msg'),
          role: 'tool',
          content: '',
          status: 'complete',
          timestamp: Date.now(),
          toolCalls: finishedCalls
        };
        await this.store.addMessage(sessionId, toolMessage);
        messages.push(toolMessage);
        this.emit(sessionId, token, callbacks, toolMessage);

        this.phase = 'requesting';
        continue;
      }

      assistant.content = acc.content;
      assistant.thinking = acc.thinking.length > 0 ? acc.thinking : undefined;
      assistant.status = 'complete';
      assistant.protocolData = protocolData;
      assistant.toolCalls = acc.toolCalls.slice();

      const completePatch: MessagePatch = {
        content: acc.content,
        thinking: assistant.thinking,
        status: 'complete',
        toolCalls: assistant.toolCalls,
        protocolData: protocolData
      };
      await this.store.updateMessage(sessionId, assistant.id, completePatch);
      this.emit(sessionId, token, callbacks, assistant);

      this.phase = 'complete';
      this.currentMessageId = '';
      callbacks.onComplete(assistant);
      return;
    }

    const limitError: ChatError = new ChatError(
      `工具调用轮次已达上限(${MAX_TOOL_ITERATIONS})`, 'MAX_ITERATIONS', config.providerId);
    this.phase = 'error';
    this.currentMessageId = '';
    callbacks.onError(limitError);
    throw limitError;
  }

  private finishWithError(sessionId: string, token: number, callbacks: ChatCallbacks, error: ChatError): void {
    this.phase = 'error';
    this.currentMessageId = '';
    if (!this.isStale(sessionId, token)) {
      callbacks.onError(error);
    }
  }

  // 单轮流式请求：把 Provider 的回调事件累积成消息内容
  private streamOnce(
    sessionId: string,
    token: number,
    messages: Message[],
    config: ModelConfig,
    assistant: Message,
    callbacks: ChatCallbacks
  ): Promise<StreamAccumulator> {
    const provider: ChatProvider = this.getProvider(config);
    const signal: AbortSignal = this.abortSignal;

    return new Promise<StreamAccumulator>((resolve: (value: StreamAccumulator) => void) => {
      const acc: StreamAccumulator = new StreamAccumulator();
      let settled: boolean = false;

      const finish = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        resolve(acc);
      };

      const emitSnapshot = (): void => {
        if (settled || this.isStale(sessionId, token)) {
          return;
        }
        assistant.content = acc.content;
        assistant.thinking = acc.thinking.length > 0 ? acc.thinking : undefined;
        assistant.toolCalls = acc.toolCalls.slice();
        assistant.status = acc.hasToolCalls ? 'tool_call' : 'streaming';
        callbacks.onMessageUpdate(this.snapshot(assistant));
      };

      const streamCallbacks: StreamChatCallbacks = {
        onEvent: (event: StreamEvent) => {
          if (settled || signal.aborted || this.isStale(sessionId, token)) {
            return;
          }
          this.handleEvent(event, acc);
          if (event.type === 'thinking_delta') {
            this.phase = 'thinking';
            emitSnapshot();
          } else if (event.type === 'content_delta' || event.type === 'content_replace') {
            this.phase = 'answering';
            emitSnapshot();
          } else if (event.type === 'tool_call_start' || event.type === 'tool_call_end') {
            this.phase = 'tool_calling';
            emitSnapshot();
            const toolCall: ToolCall | undefined = event.toolCall;
            if (toolCall !== undefined) {
              callbacks.onToolCallUpdate(assistant.id, cloneToolCall(toolCall, toolCall.status));
            }
          } else if (event.type === 'complete') {
            // 结束事件里的协议数据在 handleEvent 中已保存
          }
        },
        onComplete: () => {
          finish();
        },
        onError: (error: ChatError) => {
          acc.error = error;
          finish();
        }
      };

      provider.streamChat(messages, config, streamCallbacks, signal);
    });
  }

  private handleEvent(event: StreamEvent, acc: StreamAccumulator): void {
    if (event.type === 'thinking_delta') {
      if (event.data !== undefined) {
        acc.thinking += event.data;
      }
      return;
    }

    if (event.type === 'content_delta') {
      if (event.data !== undefined) {
        acc.content += event.data;
      }
      return;
    }

    if (event.type === 'content_replace') {
      // Mercury 扩散输出：整段替换当前阶段文本
      if (event.data !== undefined) {
        acc.content = event.data;
      }
      return;
    }

    if (event.type === 'tool_call_start') {
      const source: ToolCall | undefined = event.toolCall;
      if (source === undefined) {
        return;
      }
      if (findToolCall(acc.toolCalls, source.id) !== null) {
        return;
      }
      acc.hasToolCalls = true;
      const started: ToolCall = {
        id: source.id.length > 0 ? source.id : generateId('call'),
        type: source.type,
        arguments: source.arguments,
        status: 'running',
        startTime: Date.now()
      };
      acc.toolCalls.push(started);
      return;
    }

    if (event.type === 'tool_call_delta') {
      const source: ToolCall | undefined = event.toolCall;
      if (source === undefined) {
        return;
      }
      const existing: ToolCall | null = findToolCall(acc.toolCalls, source.id);
      if (existing !== null) {
        // Provider 上报的是累积后的完整参数
        existing.arguments = source.arguments;
        existing.type = source.type;
      }
      return;
    }

    if (event.type === 'tool_call_end') {
      const source: ToolCall | undefined = event.toolCall;
      if (source === undefined) {
        return;
      }
      acc.hasToolCalls = true;
      const existing: ToolCall | null = findToolCall(acc.toolCalls, source.id);
      if (existing !== null) {
        existing.arguments = source.arguments.length > 0 ? source.arguments : existing.arguments;
        existing.type = source.type;
        existing.status = 'pending';
        return;
      }
      // Gemini 只有结束事件，没有开始事件
      const created: ToolCall = {
        id: source.id.length > 0 ? source.id : generateId('call'),
        type: source.type,
        arguments: source.arguments.length > 0 ? source.arguments : '{}',
        status: 'pending',
        startTime: Date.now()
      };
      acc.toolCalls.push(created);
      return;
    }

    if (event.type === 'complete') {
      const data: StreamProtocolData | undefined = event.protocolData;
      if (data !== undefined) {
        acc.protocolData = data;
      }
      return;
    }

    if (event.type === 'error') {
      acc.error = new ChatError(
        event.error !== undefined && event.error.length > 0 ? event.error : '生成失败', 'STREAM_ERROR');
    }
  }

  // 并行执行工具调用，结果分别给用户(摘要)和模型(完整内容)
  private executeTools(
    sessionId: string,
    token: number,
    assistantId: string,
    toolCalls: ToolCall[],
    callbacks: ChatCallbacks
  ): Promise<ToolCall[]> {
    const providerSettings: ProviderSettings = getProviderSettings(this.settings.providers, 'deepseek');
    const tools: DeepSeekTools = new DeepSeekTools(providerSettings);
    const total: number = toolCalls.length;

    return new Promise<ToolCall[]>((resolve: (value: ToolCall[]) => void) => {
      if (total === 0) {
        resolve([]);
        return;
      }

      const results: ToolCall[] = [];
      for (const tc of toolCalls) {
        results.push(tc);
      }
      let finished: number = 0;

      for (let i = 0; i < total; i++) {
        const index: number = i;
        this.runTool(tools, toolCalls[index])
          .then((done: ToolCall) => {
            results[index] = done;
            finished++;
            if (!this.isStale(sessionId, token)) {
              callbacks.onToolCallUpdate(assistantId, done);
            }
            if (finished === total) {
              resolve(results);
            }
          })
          .catch((error: Error) => {
            const failed: ToolCall = cloneToolCall(toolCalls[index], 'error');
            failed.error = error.message;
            failed.endTime = Date.now();
            results[index] = failed;
            finished++;
            if (!this.isStale(sessionId, token)) {
              callbacks.onToolCallUpdate(assistantId, failed);
            }
            if (finished === total) {
              resolve(results);
            }
          });
      }
    });
  }

  private async runTool(tools: DeepSeekTools, toolCall: ToolCall): Promise<ToolCall> {
    const startTime: number = Date.now();
    const result: ToolResult = await tools.executeTool(toolCall.type, toolCall.arguments);
    const status: ToolStatus = result.success ? 'complete' : 'error';
    const finished: ToolCall = {
      id: toolCall.id,
      type: toolCall.type,
      arguments: toolCall.arguments,
      status: status,
      result: result.data,
      resultSummary: result.summary,
      error: result.error,
      startTime: startTime,
      endTime: Date.now()
    };
    return finished;
  }

  // 把流式协议数据落到消息上，供后续对话回传
  private toProtocolData(providerId: ProviderId, data: StreamProtocolData | null): ProtocolData | undefined {
    if (data === null) {
      return undefined;
    }

    if (providerId === 'deepseek' && data.deepseek !== undefined) {
      const deepseek: DeepSeekProtocolData = { thinkingContent: data.deepseek.thinkingContent };
      const result: ProtocolData = { deepseek: deepseek };
      return result;
    }

    if (providerId === 'openai' && data.openai !== undefined) {
      const openai: OpenAIProtocolData = {
        responseId: data.openai.responseId,
        reasoningItemId: data.openai.reasoningItemId,
        encryptedContent: data.openai.encryptedContent
      };
      const result: ProtocolData = { openai: openai };
      return result;
    }

    if (providerId === 'gemini' && data.gemini !== undefined) {
      const parts: ContentPart[] = data.gemini.parts !== undefined ? data.gemini.parts : [];
      const signatures: ThoughtSignatureEntry[] =
        data.gemini.thoughtSignatures !== undefined ? data.gemini.thoughtSignatures : [];
      const gemini: GeminiProtocolData = { parts: parts, thoughtSignatures: signatures };
      const result: ProtocolData = { gemini: gemini };
      return result;
    }

    return undefined;
  }

  private snapshot(message: Message): Message {
    const copy: Message = {
      id: message.id,
      role: message.role,
      content: message.content,
      thinking: message.thinking,
      status: message.status,
      toolCalls: message.toolCalls !== undefined ? message.toolCalls.slice() : undefined,
      timestamp: message.timestamp,
      error: message.error,
      protocolData: message.protocolData
    };
    return copy;
  }

  private emit(sessionId: string, token: number, callbacks: ChatCallbacks, message: Message): void {
    if (this.isStale(sessionId, token)) {
      return;
    }
    callbacks.onMessageUpdate(this.snapshot(message));
  }

  // 重试最后一条失败的助手消息
  async retryLastMessage(
    sessionId: string,
    config: ModelConfig,
    callbacks: ChatCallbacks
  ): Promise<void> {
    const session: Session | null = await this.store.getSession(sessionId);
    if (session === null) {
      throw new ChatError('会话不存在', 'SESSION_NOT_FOUND', config.providerId);
    }

    let target: Message | null = null;
    for (let i = session.messages.length - 1; i >= 0; i--) {
      const message: Message = session.messages[i];
      if (message.role === 'assistant') {
        target = message;
        break;
      }
    }

    if (target === null || target.status !== 'error') {
      throw new ChatError('没有可重试的消息', 'NOTHING_TO_RETRY', config.providerId);
    }

    const targetId: string = target.id;
    let cutIndex: number = session.messages.length;
    for (let i = 0; i < session.messages.length; i++) {
      if (session.messages[i].id === targetId) {
        cutIndex = i;
        break;
      }
    }

    const kept: Message[] = session.messages.slice(0, cutIndex);
    await this.store.updateSession(sessionId, { messages: kept });

    this.abortSignal = { aborted: false };
    this.runToken++;
    this.activeSessionId = sessionId;

    await this.generateResponse(sessionId, this.runToken, kept, config, callbacks);
  }
}
