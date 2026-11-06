import {
  Message,
  ModelConfig,
  StreamEvent,
  ToolCall,
  ProviderSettings,
  ContentPart,
  GeminiFunctionCallPart,
  GeminiFunctionResponsePart,
  ThoughtSignatureEntry,
  GeminiStreamProtocolData,
  StreamProtocolData,
  TokenUsage,
  ChatError,
  generateId
} from '../types/Types';
import { httpStreamRequest, AbortSignal } from '../services/HttpStream';
import { ChatProvider, StreamChatCallbacks } from './IProtocol';

// ===== Generate Content REST API 结构 =====

export interface GeminiFunctionCallJson {
  name: string;
  args: Record<string, Object>;
}

export interface GeminiFunctionResponseJson {
  name: string;
  response: Record<string, Object>;
}

// Part: text/thought/thoughtSignature/functionCall/functionResponse
// 单一接口+可选字段(ArkTS限制)
export interface GeminiPartJson {
  text?: string;
  thought?: boolean;
  thoughtSignature?: string;
  functionCall?: GeminiFunctionCallJson;
  functionResponse?: GeminiFunctionResponseJson;
}

export interface GeminiContentJson {
  role: string; // 'user' | 'model'
  parts: GeminiPartJson[];
}

export interface GeminiThinkingConfig {
  includeThoughts?: boolean;
  thinkingBudget?: number;
}

export interface GeminiGenerationConfig {
  maxOutputTokens?: number;
  thinkingConfig?: GeminiThinkingConfig;
}

export interface GeminiSchemaProperty {
  type: string;
  description: string;
}

export interface GeminiSchemaProperties {
  query?: GeminiSchemaProperty;
  url?: GeminiSchemaProperty;
}

export interface GeminiFunctionSchema {
  type: string; // 'OBJECT'
  properties: GeminiSchemaProperties;
  required: string[];
}

export interface GeminiFunctionDeclaration {
  name: string;
  description: string;
  parameters: GeminiFunctionSchema;
}

export interface GeminiToolJson {
  functionDeclarations: GeminiFunctionDeclaration[];
}

export interface GeminiRequest {
  contents: GeminiContentJson[];
  generationConfig?: GeminiGenerationConfig;
  tools?: GeminiToolJson[];
}

// ===== 流式响应结构 =====

export interface GeminiContentJsonOut {
  parts?: GeminiPartJson[];
  role?: string;
}

export interface GeminiCandidateJson {
  content?: GeminiContentJsonOut;
  finishReason?: string;
  index?: number;
}

export interface GeminiUsageJson {
  promptTokenCount?: number;
  candidatesTokenCount?: number;
  totalTokenCount?: number;
}

export interface GeminiErrorJson {
  code?: number;
  message?: string;
  status?: string;
}

export interface GeminiStreamChunkJson {
  candidates?: GeminiCandidateJson[];
  usageMetadata?: GeminiUsageJson;
  error?: GeminiErrorJson;
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

export class GeminiProvider implements ChatProvider {
  private apiKey: string;
  private baseUrl: string;

  constructor(settings: ProviderSettings) {
    this.apiKey = settings.apiKey;
    this.baseUrl = settings.baseUrl !== undefined && settings.baseUrl.length > 0
      ? settings.baseUrl
      : 'https://generativelanguage.googleapis.com';
  }

  // 转换消息为Gemini contents
  // TASK.md: 保持Parts结构和签名对应关系，不能压成单个字符串
  private convertMessages(messages: Message[]): GeminiContentJson[] {
    const result: GeminiContentJson[] = [];

    for (const msg of messages) {
      if (msg.role === 'system') {
        continue;
      }

      const parts: GeminiPartJson[] = [];

      if (msg.role === 'tool') {
        // 工具结果 → functionResponse parts (user角色)
        if (msg.toolCalls !== undefined) {
          for (const tc of msg.toolCalls) {
            const respText: string = tc.result !== undefined
              ? tc.result
              : (tc.error !== undefined ? `工具执行失败: ${tc.error}` : '');
            const respObj: Record<string, Object> = { 'result': respText };
            const fnResp: GeminiFunctionResponseJson = { name: tc.type, response: respObj };
            const part: GeminiPartJson = { functionResponse: fnResp };
            parts.push(part);
          }
        }
        if (parts.length > 0) {
          const content: GeminiContentJson = { role: 'user', parts: parts };
          result.push(content);
        }
        continue;
      }

      if (msg.role === 'assistant') {
        // 优先使用保存的Parts结构(含每个Part各自的签名，保持归属和顺序)
        const saved: ContentPart[] | undefined =
          msg.protocolData !== undefined && msg.protocolData.gemini !== undefined
            ? msg.protocolData.gemini.parts
            : undefined;

        if (saved !== undefined && saved.length > 0) {
          for (const sp of saved) {
            const part: GeminiPartJson = {};
            if (sp.text !== undefined) {
              part.text = sp.text;
            }
            if (sp.thought !== undefined) {
              part.thought = sp.thought;
            }
            // 签名原样回传，保留与原始Part的对应关系
            if (sp.thoughtSignature !== undefined) {
              part.thoughtSignature = sp.thoughtSignature;
            }
            if (sp.functionCall !== undefined) {
              const argsObj: Record<string, Object> = parseJsonObject(sp.functionCall.args);
              const fc: GeminiFunctionCallJson = { name: sp.functionCall.name, args: argsObj };
              part.functionCall = fc;
            }
            if (sp.functionResponse !== undefined) {
              const respObj: Record<string, Object> = parseJsonObject(sp.functionResponse.response);
              const fr: GeminiFunctionResponseJson = { name: sp.functionResponse.name, response: respObj };
              part.functionResponse = fr;
            }
            parts.push(part);
          }
        } else {
          // 无保存结构时从消息内容重建
          if (msg.thinking !== undefined && msg.thinking.length > 0) {
            const thinkPart: GeminiPartJson = { text: msg.thinking, thought: true };
            parts.push(thinkPart);
          }
          if (msg.content.length > 0) {
            const textPart: GeminiPartJson = { text: msg.content };
            parts.push(textPart);
          }
          if (msg.toolCalls !== undefined) {
            for (const tc of msg.toolCalls) {
              const argsObj: Record<string, Object> = parseJsonObject(tc.arguments);
              const fc: GeminiFunctionCallJson = { name: tc.type, args: argsObj };
              const fcPart: GeminiPartJson = { functionCall: fc };
              parts.push(fcPart);
            }
          }
        }

        if (parts.length > 0) {
          const content: GeminiContentJson = { role: 'model', parts: parts };
          result.push(content);
        }
        continue;
      }

      // user
      if (msg.content.length > 0) {
        const textPart: GeminiPartJson = { text: msg.content };
        parts.push(textPart);
        const content: GeminiContentJson = { role: 'user', parts: parts };
        result.push(content);
      }
    }

    return result;
  }

  private getToolDefinitions(): GeminiToolJson[] {
    const queryProp: GeminiSchemaProperty = { type: 'STRING', description: '搜索关键词' };
    const searchProps: GeminiSchemaProperties = { query: queryProp };
    const searchSchema: GeminiFunctionSchema = { type: 'OBJECT', properties: searchProps, required: ['query'] };
    const searchDecl: GeminiFunctionDeclaration = {
      name: 'search',
      description: '按关键词搜索网页，返回标题、链接与摘要',
      parameters: searchSchema
    };

    const urlProp: GeminiSchemaProperty = { type: 'STRING', description: '要抓取的网页完整URL' };
    const fetchProps: GeminiSchemaProperties = { url: urlProp };
    const fetchSchema: GeminiFunctionSchema = { type: 'OBJECT', properties: fetchProps, required: ['url'] };
    const fetchDecl: GeminiFunctionDeclaration = {
      name: 'fetch',
      description: '抓取单个网页，以Markdown文本返回页面内容',
      parameters: fetchSchema
    };

    const tool: GeminiToolJson = { functionDeclarations: [searchDecl, fetchDecl] };
    return [tool];
  }

  streamChat(
    messages: Message[],
    config: ModelConfig,
    callbacks: StreamChatCallbacks,
    abortSignal?: AbortSignal
  ): void {
    // TASK.md: 流式端点与模型名有关
    const url: string =
      `${this.baseUrl}/v1beta/models/${config.modelId}:streamGenerateContent?alt=sse`;

    // 思考配置: TASK.md要求开启思考摘要(includeThoughts)并支持思考强度
    const thinkingConfig: GeminiThinkingConfig = {};
    if (config.thinkingEnabled && config.thinkingEffort !== 'none') {
      thinkingConfig.includeThoughts = true;
      // 思考强度 → thinkingBudget映射(-1为动态最大)
      if (config.thinkingEffort === 'low') {
        thinkingConfig.thinkingBudget = 4096;
      } else if (config.thinkingEffort === 'medium') {
        thinkingConfig.thinkingBudget = 16384;
      } else {
        thinkingConfig.thinkingBudget = -1;
      }
    } else {
      thinkingConfig.includeThoughts = false;
      thinkingConfig.thinkingBudget = 0; // 关闭思考
    }

    const generationConfig: GeminiGenerationConfig = {
      maxOutputTokens: config.maxTokens !== undefined ? config.maxTokens : 65536,
      thinkingConfig: thinkingConfig
    };

    const requestBody: GeminiRequest = {
      contents: this.convertMessages(messages),
      generationConfig: generationConfig,
      tools: this.getToolDefinitions()
    };

    // ===== 流式解析状态 =====
    // TASK.md: thoughtSignature作为不透明数据原样保存，保留与Part的对应关系和顺序
    const savedParts: ContentPart[] = [];
    let completed: boolean = false;
    let textAccumulated: boolean = false;

    const emitComplete = (): void => {
      if (completed) {
        return;
      }
      completed = true;
      const sigEntries: ThoughtSignatureEntry[] = [];
      for (let i = 0; i < savedParts.length; i++) {
        const p: ContentPart = savedParts[i];
        if (p.thoughtSignature !== undefined && p.thoughtSignature.length > 0) {
          const entry: ThoughtSignatureEntry = { index: i, signature: p.thoughtSignature };
          sigEntries.push(entry);
        }
      }
      const gData: GeminiStreamProtocolData = {
        parts: savedParts,
        thoughtSignatures: sigEntries
      };
      const proto: StreamProtocolData = { gemini: gData };
      const event: StreamEvent = { type: 'complete', protocolData: proto };
      callbacks.onEvent(event);
    };

    httpStreamRequest(
      {
        url: url,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          // TASK.md: x-goog-api-key认证
          'x-goog-api-key': this.apiKey
        },
        body: JSON.stringify(requestBody),
        timeout: 300000,
        provider: 'gemini'
      },
      {
        onData: (data: string) => {
          if (completed) {
            return;
          }
          if (data.trim().length === 0 || data.trim() === '[DONE]') {
            return;
          }

          let chunk: GeminiStreamChunkJson;
          try {
            chunk = JSON.parse(data) as GeminiStreamChunkJson;
          } catch (e) {
            return;
          }

          if (chunk.error !== undefined && chunk.error.message !== undefined) {
            const errEvent: StreamEvent = { type: 'error', error: chunk.error.message };
            callbacks.onEvent(errEvent);
            return;
          }

          if (chunk.usageMetadata !== undefined) {
            const usage: TokenUsage = {
              inputTokens: chunk.usageMetadata.promptTokenCount,
              outputTokens: chunk.usageMetadata.candidatesTokenCount
            };
            const usageEvent: StreamEvent = { type: 'usage', usage: usage };
            callbacks.onEvent(usageEvent);
          }

          if (chunk.candidates === undefined || chunk.candidates.length === 0) {
            return;
          }

          const candidate: GeminiCandidateJson = chunk.candidates[0];

          if (candidate.content !== undefined && candidate.content.parts !== undefined) {
            for (const part of candidate.content.parts) {
              // 函数调用Part(Gemini一次给出完整调用)
              if (part.functionCall !== undefined) {
                const fc: GeminiFunctionCallJson = part.functionCall;
                const argsStr: string = JSON.stringify(fc.args);
                const tc: ToolCall = {
                  id: generateId('gemcall'),
                  type: fc.name === 'fetch' ? 'fetch' : 'search',
                  arguments: argsStr,
                  status: 'pending'
                };
                // 保存Part结构(含签名归属)
                const fcStored: GeminiFunctionCallPart = { name: fc.name, args: argsStr };
                const storedPart: ContentPart = {
                  type: 'tool_call',
                  functionCall: fcStored,
                  thoughtSignature: part.thoughtSignature
                };
                savedParts.push(storedPart);

                const startEvent: StreamEvent = { type: 'tool_call_start', toolCall: tc };
                callbacks.onEvent(startEvent);
                const endEvent: StreamEvent = { type: 'tool_call_end', toolCall: tc };
                callbacks.onEvent(endEvent);
                continue;
              }

              // 文本/思考Part
              if (part.text !== undefined) {
                const isThought: boolean = part.thought === true;
                const storedPart: ContentPart = {
                  type: isThought ? 'thinking' : 'text',
                  text: part.text,
                  thought: part.thought,
                  thoughtSignature: part.thoughtSignature
                };
                savedParts.push(storedPart);

                if (isThought) {
                  // TASK.md: 思考摘要根据thought标记识别并实时展示
                  const thinkEvent: StreamEvent = { type: 'thinking_delta', data: part.text };
                  callbacks.onEvent(thinkEvent);
                } else {
                  textAccumulated = true;
                  const contentEvent: StreamEvent = { type: 'content_delta', data: part.text };
                  callbacks.onEvent(contentEvent);
                }
              }
            }
          }

          // 结束: TASK.md: 摘要为空时也应正常完成请求
          if (candidate.finishReason !== undefined && candidate.finishReason !== null) {
            const reason: string = candidate.finishReason;
            if (reason === 'STOP' || reason === 'MAX_TOKENS' || reason === 'TOOL_CALLS'
              || reason === 'SAFETY' || reason === 'RECITATION' || reason === 'OTHER') {
              emitComplete();
            }
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
}
