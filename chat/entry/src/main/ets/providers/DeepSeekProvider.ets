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
import { httpStreamRequest, AbortSignal } from '../services/HttpStream';
import {
  hasText,
  listOr,
  numberOr,
  parseJsonObject,
  present,
  recordOrNull,
  stringField,
  textOr
} from '../services/Json';
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
  // Anthropic格式的system是顶层参数，不在messages里
  system?: string;
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

export class DeepSeekProvider implements ChatProvider {
  private apiKey: string;
  private baseUrl: string;

  constructor(settings: ProviderSettings) {
    this.apiKey = settings.apiKey;
    this.baseUrl = settings.baseUrl !== undefined && settings.baseUrl.length > 0
      ? settings.baseUrl
      : 'https://api.deepseek.com';
  }

  // system 是顶层参数
  private extractSystem(messages: Message[]): string {
    const parts: string[] = [];
    for (const msg of messages) {
      if (msg.role === 'system' && msg.content.trim().length > 0) {
        parts.push(msg.content.trim());
      }
    }
    return parts.join('\n\n');
  }

  // 转换消息为Anthropic格式
  // 官方兼容文档: assistant 含 tool_use 时，紧接着必须是 user 消息且为全部调用提供 tool_result，
  // tool_result 块要放在文本之前；思考模式下必须原样回传 assistant 的完整 content 数组(含 thinking)，
  // 遗漏会导致服务端无法恢复而返回 400。关闭思考时则不能带 thinking 块。
  private convertMessages(messages: Message[], includeThinking: boolean): AnthropicMessage[] {
    const result: AnthropicMessage[] = [];

    for (const msg of messages) {
      if (msg.role === 'system') {
        continue; // 顶层参数
      }

      if (msg.role === 'tool') {
        // 工具结果: user消息中的tool_result块
        const blocks: AnthropicContentBlock[] = [];
        for (const tc of listOr(msg.toolCalls)) {
          const resultBlock: AnthropicContentBlock = {
            type: 'tool_result',
            tool_use_id: tc.id,
            content: tc.result !== undefined ? tc.result : (tc.error !== undefined ? `工具执行失败: ${tc.error}` : '')
          };
          blocks.push(resultBlock);
        }
        if (blocks.length > 0) {
          const toolMsg: AnthropicMessage = { role: 'user', content: blocks };
          result.push(toolMsg);
        }
        continue;
      }

      const blocks: AnthropicContentBlock[] = [];

      // assistant消息: 先thinking块，再tool_use，最后text
      if (msg.role === 'assistant') {
        const savedThinking: string | undefined =
          msg.protocolData !== undefined && msg.protocolData.deepseek !== undefined
            ? msg.protocolData.deepseek.thinkingContent
            : undefined;
        if (includeThinking && hasText(savedThinking)) {
          const thinkingBlock: AnthropicContentBlock = { type: 'thinking', thinking: savedThinking };
          blocks.push(thinkingBlock);
        }

        for (const tc of listOr(msg.toolCalls)) {
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

      if (msg.content.length > 0) {
        const textBlock: AnthropicContentBlock = { type: 'text', text: msg.content };
        blocks.push(textBlock);
      }

      if (blocks.length > 0) {
        const m: AnthropicMessage = { role: msg.role, content: blocks };
        result.push(m);
      }
    }

    return this.mergeSameRole(result);
  }

  // Anthropic 要求 user/assistant 交替出现：清洗历史后可能出现相邻同角色消息，
  // 这里把它们的 content 块合并成一条(tool_result 块天然排在文本之前)
  private mergeSameRole(messages: AnthropicMessage[]): AnthropicMessage[] {
    const merged: AnthropicMessage[] = [];
    for (const m of messages) {
      const last: AnthropicMessage | null = merged.length > 0 ? merged[merged.length - 1] : null;
      if (last !== null && last.role === m.role) {
        for (const block of m.content) {
          last.content.push(block);
        }
        continue;
      }
      const blocks: AnthropicContentBlock[] = [];
      for (const block of m.content) {
        blocks.push(block);
      }
      const entry: AnthropicMessage = { role: m.role, content: blocks };
      merged.push(entry);
    }
    return merged;
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

  // 官方文档给出的 base_url 是 https://api.deepseek.com/anthropic，
  // 用户可能填根域名也可能填带 /anthropic 的完整地址，两种都要能拼出正确端点
  private messagesUrl(): string {
    let base: string = this.baseUrl;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/anthropic')) {
      return `${base}/v1/messages`;
    }
    return `${base}/anthropic/v1/messages`;
  }

  // 流式请求
  streamChat(
    messages: Message[],
    config: ModelConfig,
    callbacks: StreamChatCallbacks,
    abortSignal?: AbortSignal
  ): void {
    const url: string = this.messagesUrl();
    const thinkingOn: boolean = config.thinkingEnabled && config.thinkingEffort !== 'none';

    const requestBody: DeepSeekRequest = {
      model: config.modelId,
      messages: this.convertMessages(messages, thinkingOn),
      // 不人为限制输出量：使用用户配置或模型能力值
      max_tokens: config.maxTokens !== undefined ? config.maxTokens : 128000,
      stream: true, // TASK.md: 必须使用流式请求
      tools: this.getToolDefinitions()
    };

    const systemText: string = this.extractSystem(messages);
    if (systemText.length > 0) {
      requestBody.system = systemText;
    }

    // 思考配置(TASK.md示例格式): thinking.type + output_config.effort，none表示关闭
    if (thinkingOn) {
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
    let sawMessageStop: boolean = false;

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

          // 错误帧: 官方文档说明超时会产生一个没有 type、只有 error 的无名 data 帧
          const errorRecord: Record<string, Object> | null = recordOrNull(evt.error);
          if (errorRecord !== null) {
            const message: string = stringField(errorRecord, 'message');
            const errEvent: StreamEvent = { type: 'error', error: message.length > 0 ? message : '服务端返回错误' };
            callbacks.onEvent(errEvent);
            return;
          }

          const evtType: string = textOr(evt.type);

          if (evtType === 'content_block_start') {
            const block: StreamContentBlock | undefined = evt.content_block;
            if (block !== undefined && block !== null && block.type === 'tool_use') {
              const toolId: string = hasText(block.id) ? textOr(block.id) : generateId('toolu');
              pendingTool = {
                id: toolId,
                name: textOr(block.name),
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
            if (delta === undefined || delta === null) {
              return;
            }
            const deltaType: string = textOr(delta.type);

            // 思考增量
            if (deltaType === 'thinking_delta' && hasText(delta.thinking)) {
              const think: string = textOr(delta.thinking);
              thinkingBuffer += think;
              const thinkEvent: StreamEvent = { type: 'thinking_delta', data: think };
              callbacks.onEvent(thinkEvent);
              return;
            }
            // 正文增量
            if (deltaType === 'text_delta' && hasText(delta.text)) {
              const contentEvent: StreamEvent = { type: 'content_delta', data: textOr(delta.text) };
              callbacks.onEvent(contentEvent);
              return;
            }
            // 工具参数增量：参数完整后再执行
            if (deltaType === 'input_json_delta' && hasText(delta.partial_json)) {
              if (pendingTool !== null) {
                pendingTool.jsonBuffer += textOr(delta.partial_json);
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

          // 官方文档: 以最后的 message_delta.usage 为本次用量，不与 message_start 相加
          if (evtType === 'message_delta') {
            if (present(evt.usage)) {
              const usageJson: StreamUsage = evt.usage as StreamUsage;
              const usage: TokenUsage = {
                inputTokens: numberOr(usageJson.input_tokens),
                outputTokens: numberOr(usageJson.output_tokens)
              };
              const usageEvent: StreamEvent = { type: 'usage', usage: usage };
              callbacks.onEvent(usageEvent);
            }
            return;
          }

          if (evtType === 'message_stop') {
            sawMessageStop = true;
            emitComplete();
            return;
          }

          // 兼容DeepSeek原生字段(reasoning_content/content直出)
          if (hasText(evt.reasoning_content)) {
            const think: string = textOr(evt.reasoning_content);
            thinkingBuffer += think;
            const thinkEvent: StreamEvent = { type: 'thinking_delta', data: think };
            callbacks.onEvent(thinkEvent);
          }
          if (hasText(evt.content)) {
            const contentEvent: StreamEvent = { type: 'content_delta', data: textOr(evt.content) };
            callbacks.onEvent(contentEvent);
          }
        },

        onComplete: () => {
          // 官方文档: 流中没有 data:[DONE]，未收到 message_stop 就断开表示响应不完整
          if (!sawMessageStop && !completed) {
            const errEvent: StreamEvent = { type: 'error', error: '响应在 message_stop 前中断，请重试' };
            callbacks.onEvent(errEvent);
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
