import {
  Message,
  ModelConfig,
  StreamEvent,
  ToolCall,
  ProviderSettings,
  ChatError,
  OpenAIStreamProtocolData,
  StreamProtocolData,
  TokenUsage
} from '../types/Types';
import { httpStreamRequest, AbortSignal } from '../services/HttpStream';
import { hasText, listOr, present, recordOrNull, stringField, textOr } from '../services/Json';
import { ChatProvider, StreamChatCallbacks } from './IProtocol';

// ===== Responses API 请求结构 =====

// 消息内容Part
export interface ResponsesMessageContent {
  type: string; // 'input_text' | 'output_text'
  text: string;
}

// 思考摘要Part
export interface ResponsesSummaryPart {
  type: string; // 'summary_text'
  text: string;
}

// 输入项：message / reasoning / function_call / function_call_output
// 用单一接口+可选字段表达(ArkTS不支持对象字面量联合类型)
export interface ResponsesInputItem {
  type: string;
  // message
  role?: string;
  content?: ResponsesMessageContent[];
  // reasoning (无状态回传加密思考内容)
  id?: string;
  encrypted_content?: string;
  summary?: ResponsesSummaryPart[];
  // function_call
  call_id?: string;
  name?: string;
  arguments?: string;
  // function_call_output
  output?: string;
}

export interface ResponsesReasoningConfig {
  effort?: string; // low/medium/high/xhigh/max
  mode?: string;   // standard/pro
  summary?: string; // 'auto' - TASK.md要求请求摘要
}

export interface ResponsesFunctionParametersProperty {
  type: string;
  description: string;
}

export interface ResponsesFunctionParametersProperties {
  query?: ResponsesFunctionParametersProperty;
  url?: ResponsesFunctionParametersProperty;
}

export interface ResponsesFunctionParameters {
  type: string;
  properties: ResponsesFunctionParametersProperties;
  required: string[];
}

export interface ResponsesTool {
  type: string; // 'function'
  name: string;
  description: string;
  parameters: ResponsesFunctionParameters;
}

export interface OpenAIRequest {
  model: string;
  input: ResponsesInputItem[];
  stream: boolean;
  store: boolean;               // TASK.md: 必须使用无状态API
  include: string[];            // 官方要求: 无状态时须显式请求encrypted_content
  reasoning?: ResponsesReasoningConfig;
  service_tier?: string;        // fast/ultrafast速度模式
  max_output_tokens?: number;
  tools?: ResponsesTool[];
}

// ===== 流式事件结构 =====

export interface ResponsesStreamItem {
  type?: string;
  id?: string;
  call_id?: string;
  name?: string;
  arguments?: string;
  encrypted_content?: string;
  summary?: ResponsesSummaryPart[];
  role?: string;
  content?: ResponsesMessageContent[];
}

export interface ResponsesStreamUsage {
  input_tokens?: number;
  output_tokens?: number;
}

export interface ResponsesStreamResponse {
  id?: string;
  status?: string;
  output?: ResponsesStreamItem[];
  usage?: ResponsesStreamUsage;
  error?: ErrorBodyJson;
}

export interface ErrorBodyJson {
  message?: string;
  type?: string;
}

export interface ResponsesStreamEventJson {
  type?: string;
  response?: ResponsesStreamResponse;
  item?: ResponsesStreamItem;
  delta?: string;
  output_index?: number;
  error?: ErrorBodyJson;
}

// 工具调用累加状态
interface PendingFunctionCall {
  callId: string;
  name: string;
  argsBuffer: string;
}

export class OpenAIProvider implements ChatProvider {
  private apiKey: string;
  private baseUrl: string;

  constructor(settings: ProviderSettings) {
    this.apiKey = settings.apiKey;
    this.baseUrl = settings.baseUrl !== undefined && settings.baseUrl.length > 0
      ? settings.baseUrl
      : 'https://api.openai.com';
  }

  // 转换消息为Responses API输入项
  // 按官方要求回传reasoning.encrypted_content，保持顺序:
  // reasoning → function_call → function_call_output → message
  private convertMessages(messages: Message[]): ResponsesInputItem[] {
    const result: ResponsesInputItem[] = [];

    for (const msg of messages) {
      if (msg.role === 'system') {
        const sysContent: ResponsesMessageContent = { type: 'input_text', text: msg.content };
        const sysItem: ResponsesInputItem = {
          type: 'message',
          role: 'system',
          content: [sysContent]
        };
        result.push(sysItem);
        continue;
      }

      if (msg.role === 'tool') {
        // 工具结果 → function_call_output
        if (msg.toolCalls !== undefined) {
          for (const tc of msg.toolCalls) {
            const outputText: string = tc.result !== undefined
              ? tc.result
              : (tc.error !== undefined ? `工具执行失败: ${tc.error}` : '');
            const outItem: ResponsesInputItem = {
              type: 'function_call_output',
              call_id: tc.id,
              output: outputText
            };
            result.push(outItem);
          }
        }
        continue;
      }

      if (msg.role === 'assistant') {
        // 回传加密思考内容(无状态模式必需)：reasoning 项要带自身的 id 与 encrypted_content
        if (msg.protocolData !== undefined && msg.protocolData.openai !== undefined) {
          const pd = msg.protocolData.openai;
          if (hasText(pd.encryptedContent)) {
            const reasoningItem: ResponsesInputItem = {
              type: 'reasoning',
              encrypted_content: pd.encryptedContent,
              summary: []
            };
            if (hasText(pd.reasoningItemId)) {
              reasoningItem.id = pd.reasoningItemId;
            }
            result.push(reasoningItem);
          }
        }

        // 工具调用 → function_call
        if (msg.toolCalls !== undefined) {
          for (const tc of msg.toolCalls) {
            const fcItem: ResponsesInputItem = {
              type: 'function_call',
              call_id: tc.id,
              name: tc.type,
              arguments: tc.arguments
            };
            result.push(fcItem);
          }
        }

        // 文本 → message
        if (msg.content.length > 0) {
          const textContent: ResponsesMessageContent = { type: 'output_text', text: msg.content };
          const msgItem: ResponsesInputItem = {
            type: 'message',
            role: 'assistant',
            content: [textContent]
          };
          result.push(msgItem);
        }
        continue;
      }

      // user
      if (msg.content.length > 0) {
        const userContent: ResponsesMessageContent = { type: 'input_text', text: msg.content };
        const userItem: ResponsesInputItem = {
          type: 'message',
          role: 'user',
          content: [userContent]
        };
        result.push(userItem);
      }
    }

    return result;
  }

  private getToolDefinitions(): ResponsesTool[] {
    const queryProp: ResponsesFunctionParametersProperty = { type: 'string', description: '搜索关键词' };
    const searchProps: ResponsesFunctionParametersProperties = { query: queryProp };
    const searchParams: ResponsesFunctionParameters = {
      type: 'object',
      properties: searchProps,
      required: ['query']
    };
    const searchTool: ResponsesTool = {
      type: 'function',
      name: 'search',
      description: '按关键词搜索网页，返回标题、链接与摘要',
      parameters: searchParams
    };

    const urlProp: ResponsesFunctionParametersProperty = { type: 'string', description: '要抓取的网页完整URL' };
    const fetchProps: ResponsesFunctionParametersProperties = { url: urlProp };
    const fetchParams: ResponsesFunctionParameters = {
      type: 'object',
      properties: fetchProps,
      required: ['url']
    };
    const fetchTool: ResponsesTool = {
      type: 'function',
      name: 'fetch',
      description: '抓取单个网页，以Markdown文本返回页面内容',
      parameters: fetchParams
    };

    return [searchTool, fetchTool];
  }

  streamChat(
    messages: Message[],
    config: ModelConfig,
    callbacks: StreamChatCallbacks,
    abortSignal?: AbortSignal
  ): void {
    const url: string = `${this.baseUrl}/v1/responses`;

    const requestBody: OpenAIRequest = {
      model: config.modelId,
      input: this.convertMessages(messages),
      stream: true, // TASK.md: 必须使用流式请求
      store: false, // TASK.md: 必须使用无状态API
      include: ['reasoning.encrypted_content'], // 官方要求: 无状态时显式请求加密思考内容
      tools: this.getToolDefinitions(),
      max_output_tokens: config.maxTokens !== undefined ? config.maxTokens : 128000
    };

    // 思考配置: effort + mode，并请求摘要(TASK.md: 必须请求摘要)
    if (config.thinkingEnabled && config.thinkingEffort !== 'none') {
      const reasoning: ResponsesReasoningConfig = {
        effort: config.thinkingEffort,
        summary: 'auto'
      };
      if (config.reasoningMode !== undefined) {
        reasoning.mode = config.reasoningMode;
      }
      requestBody.reasoning = reasoning;
    }

    // 速度模式: TASK.md要求对支持的模型允许Fast/Ultrafast
    if (config.speedMode !== undefined && config.speedMode !== 'normal') {
      requestBody.service_tier = config.speedMode;
    }

    // 流式解析状态
    const pendingCalls: PendingFunctionCall[] = [];
    let responseId: string = '';
    let reasoningItemId: string = '';
    let encryptedContent: string = '';
    let completed: boolean = false;
    let sawTerminalEvent: boolean = false;

    const emitComplete = (): void => {
      if (completed) {
        return;
      }
      completed = true;
      const oaData: OpenAIStreamProtocolData = {
        responseId: responseId.length > 0 ? responseId : undefined,
        reasoningItemId: reasoningItemId.length > 0 ? reasoningItemId : undefined,
        encryptedContent: encryptedContent.length > 0 ? encryptedContent : undefined
      };
      const proto: StreamProtocolData = { openai: oaData };
      const event: StreamEvent = { type: 'complete', protocolData: proto };
      callbacks.onEvent(event);
    };

    const emitError = (message: string): void => {
      const errEvent: StreamEvent = { type: 'error', error: message };
      callbacks.onEvent(errEvent);
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
        provider: 'openai'
      },
      {
        onData: (data: string) => {
          if (completed) {
            return;
          }
          if (data.trim().length === 0 || data.trim() === '[DONE]') {
            return;
          }

          let evt: ResponsesStreamEventJson;
          try {
            evt = JSON.parse(data) as ResponsesStreamEventJson;
          } catch (e) {
            return;
          }

          // error 字段在正常事件里是显式 null，必须先排除
          const topError: Record<string, Object> | null = recordOrNull(evt.error);
          if (topError !== null) {
            const message: string = stringField(topError, 'message');
            emitError(message.length > 0 ? message : '服务端返回错误');
            return;
          }

          const response: ResponsesStreamResponse | undefined = evt.response;
          if (response !== undefined && response !== null && hasText(response.id)) {
            responseId = textOr(response.id);
          }

          const evtType: string = textOr(evt.type);

          // 新输出项: function_call开始 / reasoning项的id
          if (evtType === 'response.output_item.added') {
            const item: ResponsesStreamItem | undefined = evt.item;
            if (item !== undefined && item !== null && item.type === 'function_call') {
              const pending: PendingFunctionCall = {
                callId: textOr(item.call_id),
                name: textOr(item.name),
                argsBuffer: ''
              };
              pendingCalls.push(pending);
              const tc: ToolCall = {
                id: pending.callId,
                type: pending.name === 'fetch' ? 'fetch' : 'search',
                arguments: '',
                status: 'running'
              };
              const startEvent: StreamEvent = { type: 'tool_call_start', toolCall: tc };
              callbacks.onEvent(startEvent);
            }
            return;
          }

          // 思考摘要增量(TASK.md: 实时展示summary)
          if (evtType === 'response.reasoning_summary_text.delta' || evtType === 'response.summary_text.delta'
            || evtType === 'response.reasoning_text.delta') {
            if (hasText(evt.delta)) {
              const thinkEvent: StreamEvent = { type: 'thinking_delta', data: textOr(evt.delta) };
              callbacks.onEvent(thinkEvent);
            }
            return;
          }

          // 正文增量(TASK.md: 实时展示content)
          if (evtType === 'response.output_text.delta' || evtType === 'response.text.delta') {
            if (hasText(evt.delta)) {
              const contentEvent: StreamEvent = { type: 'content_delta', data: textOr(evt.delta) };
              callbacks.onEvent(contentEvent);
            }
            return;
          }

          // 工具参数增量
          if (evtType === 'response.function_call_arguments.delta') {
            if (evt.delta !== undefined && evt.delta !== null && pendingCalls.length > 0) {
              const last: PendingFunctionCall = pendingCalls[pendingCalls.length - 1];
              last.argsBuffer += evt.delta;
              const tc: ToolCall = {
                id: last.callId,
                type: last.name === 'fetch' ? 'fetch' : 'search',
                arguments: last.argsBuffer,
                status: 'running'
              };
              const deltaEvent: StreamEvent = { type: 'tool_call_delta', toolCall: tc };
              callbacks.onEvent(deltaEvent);
            }
            return;
          }

          // 工具参数完成: 此时才执行
          if (evtType === 'response.function_call_arguments.done') {
            if (pendingCalls.length > 0) {
              const last: PendingFunctionCall = pendingCalls.pop() as PendingFunctionCall;
              const finalArgs: string = hasText(evt.delta) ? textOr(evt.delta) : last.argsBuffer;
              const tc: ToolCall = {
                id: last.callId,
                type: last.name === 'fetch' ? 'fetch' : 'search',
                arguments: finalArgs.length > 0 ? finalArgs : '{}',
                status: 'pending'
              };
              const endEvent: StreamEvent = { type: 'tool_call_end', toolCall: tc };
              callbacks.onEvent(endEvent);
            }
            return;
          }

          // 输出项完成: 捕获reasoning项的id与encrypted_content(工具调用后继续对话必需)
          if (evtType === 'response.output_item.done') {
            const item: ResponsesStreamItem | undefined = evt.item;
            if (item !== undefined && item !== null && item.type === 'reasoning') {
              if (hasText(item.id)) {
                reasoningItemId = textOr(item.id);
              }
              if (hasText(item.encrypted_content)) {
                encryptedContent = textOr(item.encrypted_content);
              }
            }
            return;
          }

          // 终止事件: 使用量、错误与最终输出都在这里
          if (evtType === 'response.completed' || evtType === 'response.incomplete'
            || evtType === 'response.failed') {
            sawTerminalEvent = true;
            if (response !== undefined && response !== null) {
              // 从最终输出兜底提取reasoning项
              for (const item of listOr(response.output)) {
                if (item.type === 'reasoning') {
                  if (hasText(item.id)) {
                    reasoningItemId = textOr(item.id);
                  }
                  if (hasText(item.encrypted_content)) {
                    encryptedContent = textOr(item.encrypted_content);
                  }
                }
              }
              if (present(response.usage)) {
                const usageValue: ResponsesStreamUsage = response.usage as ResponsesStreamUsage;
                const usage: TokenUsage = {
                  inputTokens: usageValue.input_tokens,
                  outputTokens: usageValue.output_tokens
                };
                const usageEvent: StreamEvent = { type: 'usage', usage: usage };
                callbacks.onEvent(usageEvent);
              }
              const responseError: Record<string, Object> | null = recordOrNull(response.error);
              if (responseError !== null) {
                const message: string = stringField(responseError, 'message');
                emitError(message.length > 0 ? message : '服务端返回错误');
                return;
              }
            }
            if (evtType === 'response.failed') {
              emitError('请求失败');
              return;
            }
            emitComplete();
            return;
          }
        },

        onComplete: () => {
          if (!sawTerminalEvent && !completed) {
            // 没有终止事件说明连接被提前关闭，已收到的内容仍然保留
            emitError('响应在完成事件前中断，请重试');
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
