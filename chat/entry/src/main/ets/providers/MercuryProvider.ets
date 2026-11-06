import {
  Message,
  ModelConfig,
  StreamEvent,
  ToolCall,
  ProviderSettings,
  ChatError
} from '../types/Types';
import http from '@ohos.net.http';

// Mercury Chat Completions API 请求
interface MercuryRequest {
  model: string;
  messages: MercuryMessage[];
  stream: boolean;
  diffusing?: boolean;
  max_tokens?: number;
  tools?: MercuryTool[];
  reasoning_effort?: 'low' | 'medium' | 'high';
}

interface MercuryMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content?: string;
  tool_calls?: MercuryToolCall[];
  tool_call_id?: string;
}

interface MercuryToolCall {
  id: string;
  type: 'function';
  function: {
    name: string;
    arguments: string;
  };
}

interface MercuryTool {
  type: 'function';
  function: {
    name: string;
    description: string;
    parameters: any;
  };
}

// Mercury流式响应(普通模式)
interface MercuryStreamChunk {
  id: string;
  object: string;
  created: number;
  model: string;
  choices: {
    index: number;
    delta: {
      role?: string;
      content?: string;
      tool_calls?: {
        index: number;
        id?: string;
        type?: string;
        function?: {
          name?: string;
          arguments?: string;
        };
      }[];
    };
    finish_reason?: string;
  }[];
  usage?: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
  };
}

// Mercury扩散模式响应
interface MercuryDiffusionChunk {
  id: string;
  object: string;
  created: number;
  model: string;
  choices: {
    index: number;
    message: {
      role: string;
      content: string;  // 完整内容，不是增量
      tool_calls?: MercuryToolCall[];
    };
    finish_reason?: string;
    diffusion_step?: number;
  }[];
}

export class MercuryProvider {
  private settings: ProviderSettings;
  private baseUrl: string;
  
  constructor(settings: ProviderSettings) {
    this.settings = settings;
    this.baseUrl = settings.baseUrl || 'https://api.inceptionlabs.ai';
  }
  
  // 转换消息为Mercury格式
  private convertMessages(messages: Message[]): MercuryMessage[] {
    const result: MercuryMessage[] = [];
    
    for (const msg of messages) {
      if (msg.role === 'tool') {
        // 工具结果消息
        if (msg.toolCalls && msg.toolCalls.length > 0) {
          for (const tc of msg.toolCalls) {
            if (tc.result) {
              result.push({
                role: 'tool',
                tool_call_id: tc.id,
                content: tc.result
              });
            }
          }
        }
      } else {
        const mercuryMsg: MercuryMessage = {
          role: msg.role as 'system' | 'user' | 'assistant',
          content: msg.content
        };
        
        // 添加工具调用
        if (msg.toolCalls && msg.toolCalls.length > 0) {
          mercuryMsg.tool_calls = msg.toolCalls.map(tc => ({
            id: tc.id,
            type: 'function' as const,
            function: {
              name: tc.type,
              arguments: tc.arguments
            }
          }));
        }
        
        result.push(mercuryMsg);
      }
    }
    
    return result;
  }
  
  // 获取工具定义
  private getToolDefinitions(): MercuryTool[] {
    return [
      {
        type: 'function',
        function: {
          name: 'search',
          description: '搜索网页获取信息',
          parameters: {
            type: 'object',
            properties: {
              query: {
                type: 'string',
                description: '搜索关键词'
              }
            },
            required: ['query']
          }
        }
      },
      {
        type: 'function',
        function: {
          name: 'fetch',
          description: '抓取指定网页的内容',
          parameters: {
            type: 'object',
            properties: {
              url: {
                type: 'string',
                description: '要抓取的网页URL'
              }
            },
            required: ['url']
          }
        }
      }
    ];
  }
  
  // 流式请求
  async *streamChat(
    messages: Message[],
    config: ModelConfig,
    abortSignal?: { aborted: boolean }
  ): AsyncGenerator<StreamEvent> {
    const url = `${this.baseUrl}/v1/chat/completions`;
    const useDiffusion = config.diffusionEnabled !== false; // 默认开启扩散
    
    const requestBody: MercuryRequest = {
      model: config.modelId,
      messages: this.convertMessages(messages),
      stream: true,
      max_tokens: config.maxTokens || 4096,
      tools: this.getToolDefinitions()
    };
    
    // 扩散模式
    if (useDiffusion) {
      requestBody.diffusing = true;
    }
    
    // 思考配置
    if (config.thinkingEnabled && config.thinkingEffort !== 'none') {
      requestBody.reasoning_effort = config.thinkingEffort as 'low' | 'medium' | 'high';
    }
    
    const httpRequest = http.createHttp();
    
    try {
      const response = await httpRequest.request(
        url,
        {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${this.settings.apiKey}`
          },
          extraData: JSON.stringify(requestBody),
          readTimeout: 300000,
          connectTimeout: 30000,
          expectDataType: http.HttpDataType.STRING
        }
      );
      
      if (abortSignal?.aborted) {
        throw ChatError.stopped();
      }
      
      if (response.responseCode !== 200) {
        const errorBody = response.result as string;
        this.handleHttpError(response.responseCode, errorBody);
      }
      
      // 解析SSE流
      const fullResponse = response.result as string;
      const lines = fullResponse.split('\n');
      
      // 工具调用状态跟踪
      const toolCalls: Map<number, Partial<ToolCall>> = new Map();
      
      for (const line of lines) {
        if (abortSignal?.aborted) {
          throw ChatError.stopped();
        }
        
        if (!line.startsWith('data: ')) continue;
        
        const data = line.substring(6).trim();
        if (data === '[DONE]') break;
        
        try {
          if (useDiffusion) {
            // 扩散模式处理
            const chunk: MercuryDiffusionChunk = JSON.parse(data);
            
            if (chunk.choices && chunk.choices.length > 0) {
              const choice = chunk.choices[0];
              const content = choice.message?.content || '';
              
              // 扩散模式：每次都是完整内容，使用content_replace
              if (content) {
                yield {
                  type: 'content_replace',
                  data: content
                };
              }
              
              // 处理工具调用
              if (choice.message?.tool_calls) {
                for (const tc of choice.message.tool_calls) {
                  const existingCall = toolCalls.get(0) || {
                    id: tc.id,
                    type: tc.function.name as 'search' | 'fetch',
                    arguments: '',
                    status: 'pending' as const
                  };
                  
                  existingCall.arguments = tc.function.arguments;
                  toolCalls.set(0, existingCall);
                  
                  yield {
                    type: 'tool_call_end',
                    toolCall: existingCall
                  };
                }
              }
              
              // 完成
              if (choice.finish_reason === 'stop' || choice.finish_reason === 'tool_calls') {
                yield { type: 'complete' };
                return;
              }
            }
          } else {
            // 普通流式模式处理
            const chunk: MercuryStreamChunk = JSON.parse(data);
            
            if (chunk.choices && chunk.choices.length > 0) {
              const choice = chunk.choices[0];
              const delta = choice.delta;
              
              // 处理文本增量
              if (delta?.content) {
                yield {
                  type: 'content_delta',
                  data: delta.content
                };
              }
              
              // 处理工具调用
              if (delta?.tool_calls) {
                for (const tc of delta.tool_calls) {
                  const idx = tc.index;
                  let existingCall = toolCalls.get(idx);
                  
                  if (!existingCall) {
                    existingCall = {
                      id: tc.id || '',
                      type: (tc.function?.name || '') as 'search' | 'fetch',
                      arguments: '',
                      status: 'pending'
                    };
                    toolCalls.set(idx, existingCall);
                    
                    yield {
                      type: 'tool_call_start',
                      toolCall: existingCall
                    };
                  }
                  
                  if (tc.function?.arguments) {
                    existingCall.arguments = (existingCall.arguments || '') + tc.function.arguments;
                    
                    yield {
                      type: 'tool_call_delta',
                      toolCall: existingCall
                    };
                  }
                }
              }
              
              // 使用量信息
              if (chunk.usage) {
                yield {
                  type: 'usage',
                  usage: {
                    inputTokens: chunk.usage.prompt_tokens,
                    outputTokens: chunk.usage.completion_tokens
                  }
                };
              }
              
              // 完成
              if (choice.finish_reason) {
                // 完成所有未结束的工具调用
                for (const [, tc] of toolCalls) {
                  if (tc.status === 'pending') {
                    yield {
                      type: 'tool_call_end',
                      toolCall: tc
                    };
                  }
                }
                
                yield { type: 'complete' };
                return;
              }
            }
          }
        } catch (e) {
          console.error('Mercury stream parse error:', e);
        }
      }
      
      // 完成所有未结束的工具调用
      for (const [, tc] of toolCalls) {
        if (tc.status === 'pending') {
          yield {
            type: 'tool_call_end',
            toolCall: tc
          };
        }
      }
      
      yield { type: 'complete' };
      
    } catch (error) {
      if (error instanceof ChatError) {
        yield { type: 'error', error: error.message };
        throw error;
      }
      const chatError = ChatError.networkError((error as Error).message);
      yield { type: 'error', error: chatError.message };
      throw chatError;
    } finally {
      httpRequest.destroy();
    }
  }
  
  // 处理HTTP错误
  private handleHttpError(statusCode: number, body: string): never {
    let errorMessage = `HTTP ${statusCode}`;
    
    try {
      const errorJson = JSON.parse(body);
      if (errorJson.error?.message) {
        errorMessage = errorJson.error.message;
      }
    } catch {
      if (body) {
        errorMessage = body.substring(0, 200);
      }
    }
    
    if (statusCode === 401 || statusCode === 403) {
      throw ChatError.invalidApiKey('mercury');
    } else if (statusCode === 429) {
      throw ChatError.rateLimited('mercury');
    } else {
      throw new ChatError(errorMessage, 'HTTP_ERROR', 'mercury');
    }
  }
}
