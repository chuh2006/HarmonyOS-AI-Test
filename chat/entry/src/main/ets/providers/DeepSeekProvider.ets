import {
  Message,
  ModelConfig,
  StreamEvent,
  ToolCall,
  ProviderSettings,
  ChatError,
  DeepSeekStreamProtocolData,
  StreamProtocolData,
  TokenUsage,
  generateId
} from '../types/Types';
import { httpStreamRequest, AbortSignal, extractErrorMessage } from '../services/HttpStream';
import { ChatProvider, StreamChatCallbacks } from './IProtocol';

// ===== Anthropic Messages API 结构 =====

// 思考内容块(按官方要求在工具调用后原样回传)
export interface AnthropicThinkingBlock {
  type: string; // 'thinking'
  thinking: string;
}

export interface AnthropicTextBlock {
  type: string; // 'text'
  text: string;
}

export interface AnthropicToolUseBlock {
  type: string; // 'tool_use'
  id: string;
  name: string;
  input: Record<string, Object>;
}

export interface AnthropicToolResultBlock {
  type: string; // 'tool_result'
  tool_use_id: string;
  content: string;
}

// content联合：用可选字段区分(避免union of object literals)
export interface AnthropicContentBlock {
  type: string;
  text?: string;
  thinking?: string;
  id?: string;
  name?: string;
  input?: Record<string, Object>;
  tool_use_id?: string;
  content?: string;
}

export interface AnthropicMessage {
  role: string;
  content: AnthropicContentBlock[];
}

export interface AnthropicThinkingConfig {
  type: string; // 'enabled' | 'disabled'
}

export interface AnthropicOutputConfig {
  effort: string; // 'low' | 'high' | 'max'
}

export interface AnthropicToolSchemaProperty {
  type: string;
  description: string;
}

export interface AnthropicToolSchemaProperties {
  query?: AnthropicToolSchemaProperty;
  url?: AnthropicToolSchemaProperty;
}

export interface AnthropicToolSchema {
  type: string;
  properties: AnthropicToolSchemaProperties;
  required: string[];
}

// 官方要求: name/description/input_schema，无type字段
export interface AnthropicTool {
  name: string;
  description: string;
  input_schema: AnthropicToolSchema;
}

export interface DeepSeekRequest {
  model: string;
  messages: AnthropicMessage[];
  max_tokens: number;
  stream: boolean;
  thinking?: AnthropicThinkingConfig;
  output_config?: AnthropicOutputConfig;
  tools?: AnthropicTool[];
}

// ===== 流式事件结构 =====

export interface StreamDelta {
  type?: string;
  text?: string;
  thinking?: string;
  // DeepSeek 兼容字段
  reasoning_content?: string;
  partial_json?: string;
  stop_reason?: string;
}

export interface StreamContentBlock {
  type: string;
  text?: string;
  thinking?: string;
  id?: string;
  name?: string;
  input?: Record<string, Object>;
}

export interface StreamUsage {
  input_tokens?: number;
  output_tokens?: number;
}

export interface DeepSeekStreamEventJson {
  type?: string;
  index?: number;
  content_block?: StreamContentBlock;
  delta?: StreamDelta;
  usage?: StreamUsage;
  error?: ErrorBody;
  // DeepSeek 原生兼容字段
  reasoning_content?: string;
  content?: string;
}

export interface ErrorBody {
  type?: string;
  message?: string;
}

// 工具调用累加状态
interface PendingToolCall {
  id: string;
  name: string;
  jsonBuffer: string;
}

// 工具参数以JSON字符串保存，回传时还原为对象
function parseJsonObject(text: string): Record<string, Object> {
  const empty: Record<string, Object> = {};
  if (text.length === 0) {
    return empty;
  }
  try {
    const parsed: Object = JSON.parse(text) as Object;
    return parsed as Record<string, Object>;
  } catch (e) {
    return empty;
  }
}

export class DeepSeekProvider implements ChatProvider {
  private apiKey: string;
  private baseUrl: string;

  constructor(settings: ProviderSettings) {
    this.apiKey = settings.apiKey;
    this.baseUrl = settings.baseUrl !== undefined && settings.baseUrl.length > 0
      ? settings.baseUrl
      : 'https://api.deepseek.com';
  }

  // 转换消息为Anthropic格式
  // 按官方要求：assistant的thinking块必须在工具调用回传时原样保留
  private convertMessages(messages: Message[]): AnthropicMessage[] {
    const result: AnthropicMessage[] = [];

    for (const msg of messages) {
      if (msg.role === 'system') {
        continue; // Anthropic API的system是顶层参数，这里跳过
      }

      if (msg.role === 'tool') {
        // 工具结果: user消息中的tool_result块
        const blocks: AnthropicContentBlock[] = [];
        if (msg.toolCalls !== undefined) {
          for (const tc of msg.toolCalls) {
            const resultBlock: AnthropicContentBlock = {
              type: 'tool_result',
              tool_use_id: tc.id,
              content: tc.result !== undefined ? tc.result : (tc.error !== undefined ? `工具执行失败: ${tc.error}` : '')
            };
            blocks.push(resultBlock);
          }
        }
        if (blocks.length > 0) {
          const toolMsg: AnthropicMessage = { role: 'user', content: blocks };
          result.push(toolMsg);
        }
        continue;
      }

      const blocks: AnthropicContentBlock[] = [];

      // assistant消息: 先thinking块(回传保存的思考内容)，再tool_use，最后text
      if (msg.role === 'assistant') {
        const savedThinking: string | undefined =
          msg.protocolData !== undefined && msg.protocolData.deepseek !== undefined
            ? msg.protocolData.deepseek.thinkingContent
            : undefined;
        if (savedThinking !== undefined && savedThinking.length > 0) {
          const thinkingBlock: AnthropicContentBlock = { type: 'thinking', thinking: savedThinking };
          blocks.push(thinkingBlock);
        }

        if (msg.toolCalls !== undefined) {
          for (const tc of msg.toolCalls) {
            const inputObj: Record<string, Object> = parseJsonObject(tc.arguments);
            const toolUseBlock: AnthropicContentBlock = {
              type: 'tool_use',
              id: tc.id,
              name: tc.type,
              input: inputObj
            };
            blocks.push(toolUseBlock);
          }
        }
      }

      if (msg.content.length > 0) {
        const textBlock: AnthropicContentBlock = { type: 'text', text: msg.content };
        blocks.push(textBlock);
      }

      if (blocks.length > 0) {
        const m: AnthropicMessage = { role: msg.role, content: blocks };
        result.push(m);
      }
    }

    return result;
  }

  // search/fetch工具定义(TASK.md: DeepSeek v1/tools接口)
  private getToolDefinitions(): AnthropicTool[] {
    const queryProp: AnthropicToolSchemaProperty = { type: 'string', description: '搜索关键词' };
    const searchProps: AnthropicToolSchemaProperties = { query: queryProp };
    const searchSchema: AnthropicToolSchema = {
      type: 'object',
      properties: searchProps,
      required: ['query']
    };
    const searchTool: AnthropicTool = {
      name: 'search',
      description: '按关键词搜索网页，返回标题、链接与摘要',
      input_schema: searchSchema
    };

    const urlProp: AnthropicToolSchemaProperty = { type: 'string', description: '要抓取的网页完整URL' };
    const fetchProps: AnthropicToolSchemaProperties = { url: urlProp };
    const fetchSchema: AnthropicToolSchema = {
      type: 'object',
      properties: fetchProps,
      required: ['url']
    };
    const fetchTool: AnthropicTool = {
      name: 'fetch',
      description: '抓取单个网页，以Markdown文本返回页面内容',
      input_schema: fetchSchema
    };

    return [searchTool, fetchTool];
  }

  // 流式请求
  streamChat(
    messages: Message[],
    config: ModelConfig,
    callbacks: StreamChatCallbacks,
    abortSignal?: AbortSignal
  ): void {
    const url: string = `${this.baseUrl}/anthropic/v1/messages`;

    const requestBody: DeepSeekRequest = {
      model: config.modelId,
      messages: this.convertMessages(messages),
      // 不人为限制输出量：使用用户配置或模型能力值
      max_tokens: config.maxTokens !== undefined ? config.maxTokens : 128000,
      stream: true, // TASK.md: 必须使用流式请求
      tools: this.getToolDefinitions()
    };

    // 思考配置(TASK.md示例格式): thinking.type + output_config.effort，none表示关闭
    if (config.thinkingEnabled && config.thinkingEffort !== 'none') {
      const thinking: AnthropicThinkingConfig = { type: 'enabled' };
      requestBody.thinking = thinking;
      const outputConfig: AnthropicOutputConfig = { effort: config.thinkingEffort };
      requestBody.output_config = outputConfig;
    } else {
      const thinking: AnthropicThinkingConfig = { type: 'disabled' };
      requestBody.thinking = thinking;
    }

    // 流式解析状态
    let thinkingBuffer: string = '';
    let pendingTool: PendingToolCall | null = null;
    let completed: boolean = false;

    const emitComplete = (): void => {
      if (completed) {
        return;
      }
      completed = true;
      const dsData: DeepSeekStreamProtocolData = {
        thinkingContent: thinkingBuffer.length > 0 ? thinkingBuffer : undefined
      };
      const proto: StreamProtocolData = { deepseek: dsData };
      const event: StreamEvent = { type: 'complete', protocolData: proto };
      callbacks.onEvent(event);
    };

    httpStreamRequest(
      {
        url: url,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          // TASK.md: x-api-key 或 Bearer 任选其一
          'x-api-key': this.apiKey,
          'anthropic-version': '2023-06-01'
        },
        body: JSON.stringify(requestBody),
        timeout: 300000,
        provider: 'deepseek'
      },
      {
        onData: (data: string) => {
          if (completed) {
            return;
          }
          if (data.trim().length === 0 || data.trim() === '[DONE]') {
            return;
          }

          let evt: DeepSeekStreamEventJson;
          try {
            evt = JSON.parse(data) as DeepSeekStreamEventJson;
          } catch (e) {
            return; // 忽略无法解析的分片
          }

          // 错误事件
          if (evt.error !== undefined && evt.error.message !== undefined) {
            const errEvent: StreamEvent = { type: 'error', error: evt.error.message };
            callbacks.onEvent(errEvent);
            return;
          }

          const evtType: string = evt.type !== undefined ? evt.type : '';

          if (evtType === 'content_block_start') {
            const block: StreamContentBlock | undefined = evt.content_block;
            if (block !== undefined && block.type === 'tool_use') {
              pendingTool = {
                id: block.id !== undefined ? block.id : generateId('toolu'),
                name: block.name !== undefined ? block.name : '',
                jsonBuffer: ''
              };
              const tc: ToolCall = {
                id: pendingTool.id,
                type: pendingTool.name === 'fetch' ? 'fetch' : 'search',
                arguments: '',
                status: 'running'
              };
              const startEvent: StreamEvent = { type: 'tool_call_start', toolCall: tc };
              callbacks.onEvent(startEvent);
            }
            return;
          }

          if (evtType === 'content_block_delta') {
            const delta: StreamDelta | undefined = evt.delta;
            if (delta === undefined) {
              return;
            }
            const deltaType: string = delta.type !== undefined ? delta.type : '';

            // 思考增量
            if (deltaType === 'thinking_delta' && delta.thinking !== undefined) {
              thinkingBuffer += delta.thinking;
              const thinkEvent: StreamEvent = { type: 'thinking_delta', data: delta.thinking };
              callbacks.onEvent(thinkEvent);
              return;
            }
            // 正文增量
            if (deltaType === 'text_delta' && delta.text !== undefined) {
              const contentEvent: StreamEvent = { type: 'content_delta', data: delta.text };
              callbacks.onEvent(contentEvent);
              return;
            }
            // 工具参数增量：参数完整后再执行
            if (deltaType === 'input_json_delta' && delta.partial_json !== undefined) {
              if (pendingTool !== null) {
                pendingTool.jsonBuffer += delta.partial_json;
                const tc: ToolCall = {
                  id: pendingTool.id,
                  type: pendingTool.name === 'fetch' ? 'fetch' : 'search',
                  arguments: pendingTool.jsonBuffer,
                  status: 'running'
                };
                const deltaEvent: StreamEvent = { type: 'tool_call_delta', toolCall: tc };
                callbacks.onEvent(deltaEvent);
              }
              return;
            }
            return;
          }

          if (evtType === 'content_block_stop') {
            if (pendingTool !== null) {
              const args: string = pendingTool.jsonBuffer.length > 0 ? pendingTool.jsonBuffer : '{}';
              const tc: ToolCall = {
                id: pendingTool.id,
                type: pendingTool.name === 'fetch' ? 'fetch' : 'search',
                arguments: args,
                status: 'pending'
              };
              const endEvent: StreamEvent = { type: 'tool_call_end', toolCall: tc };
              callbacks.onEvent(endEvent);
              pendingTool = null;
            }
            return;
          }

          if (evtType === 'message_delta') {
            if (evt.usage !== undefined) {
              const usage: TokenUsage = {
                inputTokens: evt.usage.input_tokens,
                outputTokens: evt.usage.output_tokens
              };
              const usageEvent: StreamEvent = { type: 'usage', usage: usage };
              callbacks.onEvent(usageEvent);
            }
            return;
          }

          if (evtType === 'message_stop') {
            emitComplete();
            return;
          }

          // 兼容DeepSeek原生字段(reasoning_content/content直出)
          if (evt.reasoning_content !== undefined && evt.reasoning_content.length > 0) {
            thinkingBuffer += evt.reasoning_content;
            const thinkEvent: StreamEvent = { type: 'thinking_delta', data: evt.reasoning_content };
            callbacks.onEvent(thinkEvent);
          }
          if (evt.content !== undefined && evt.content.length > 0) {
            const contentEvent: StreamEvent = { type: 'content_delta', data: evt.content };
            callbacks.onEvent(contentEvent);
          }
        },

        onComplete: () => {
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

  // 从HTTP错误响应构建错误(非流式路径使用)
  static buildHttpError(statusCode: number, body: string): ChatError {
    return ChatError.httpError(statusCode, extractErrorMessage(body), 'deepseek');
  }
}
