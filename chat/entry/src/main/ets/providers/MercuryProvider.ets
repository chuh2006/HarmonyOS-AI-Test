import { httpStreamRequest } from '../services/HttpStream';
import {
  Message,
  ModelConfig,
  StreamEvent,
  ToolCall,
  ProviderSettings,
  ChatError
} from '../types/Types';
import { StreamChatCallbacks } from './DeepSeekProvider';

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
  streamChat(
    messages: Message[],
    config: ModelConfig,
    callbacks: StreamChatCallbacks,
    abortSignal?: { aborted: boolean }
  ): void {
    const url = `${this.baseUrl}/v1/chat/completions`;
    // 扩散模式默认开启(不是实验性功能)
    const useDiffusion = config.diffusionEnabled !== false;
    
    const requestBody: MercuryRequest = {
      model: config.modelId,
      messages: this.convertMessages(messages),
      stream: true,
      max_tokens: config.maxTokens || 8192, // 匹配模型定义的默认值
      tools: this.getToolDefinitions()
    };
    
    // 扩散模式(默认功能)
    if (useDiffusion) {
      requestBody.diffusing = true;
    }
    
    // 思考配置
    if (config.thinkingEnabled && config.thinkingEffort !== 'none') {
      requestBody.reasoning_effort = config.thinkingEffort as 'low' | 'medium' | 'high';
    }
    
    // 工具调用状态跟踪
    const toolCalls: Map<number, Partial<ToolCall>> = new Map();
    
    httpStreamRequest(
      {
        url,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${this.settings.apiKey}`
        },
        body: JSON.stringify(requestBody),
        timeout: 300000
      },
      {
        onData: (data: string) => {
          if (abortSignal?.aborted) {
            return;
          }
          
          if (data === '[DONE]') {
            return;
          }
          
          try {
            if (useDiffusion) {
              // 扩散模式处理(全量帧)
              const chunk: MercuryDiffusionChunk = JSON.parse(data);
              
              if (chunk.choices && chunk.choices.length > 0) {
                const choice = chunk.choices[0];
                const content = choice.message?.content || '';
                
                // 扩散模式：每次都是完整内容，使用content_replace
                if (content) {
                  callbacks.onEvent({
                    type: 'content_replace',
                    data: content
                  });
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
                    
                    callbacks.onEvent({
                      type: 'tool_call_end',
                      toolCall: existingCall
                    });
                  }
                }
                
                // 完成
                if (choice.finish_reason === 'stop' || choice.finish_reason === 'tool_calls') {
                  callbacks.onEvent({ type: 'complete' });
                }
              }
            } else {
              // 普通流式模式处理(增量)
              const chunk: MercuryStreamChunk = JSON.parse(data);
              
              if (chunk.choices && chunk.choices.length > 0) {
                const choice = chunk.choices[0];
                const delta = choice.delta;
                
                // 处理文本增量
                if (delta?.content) {
                  callbacks.onEvent({
                    type: 'content_delta',
                    data: delta.content
                  });
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
                      
                      callbacks.onEvent({
                        type: 'tool_call_start',
                        toolCall: existingCall
                      });
                    }
                    
                    if (tc.function?.arguments) {
                      existingCall.arguments = (existingCall.arguments || '') + tc.function.arguments;
                      
                      callbacks.onEvent({
                        type: 'tool_call_delta',
                        toolCall: existingCall
                      });
                    }
                  }
                }
                
                // 使用量信息
                if (chunk.usage) {
                  callbacks.onEvent({
                    type: 'usage',
                    usage: {
                      inputTokens: chunk.usage.prompt_tokens,
                      outputTokens: chunk.usage.completion_tokens
                    }
                  });
                }
                
                // 完成
                if (choice.finish_reason) {
                  // 完成所有未结束的工具调用
                  for (const [, tc] of toolCalls) {
                    if (tc.status === 'pending') {
                      callbacks.onEvent({
                        type: 'tool_call_end',
                        toolCall: tc
                      });
                    }
                  }
                  
                  callbacks.onEvent({ type: 'complete' });
                }
              }
            }
          } catch (e) {
            console.error('Mercury stream parse error:', e);
          }
        },
        
        onComplete: () => {
          // 完成所有未结束的工具调用
          for (const [, tc] of toolCalls) {
            if (tc.status === 'pending') {
              callbacks.onEvent({
                type: 'tool_call_end',
                toolCall: tc
              });
            }
          }
          
          callbacks.onComplete();
        },
        
        onError: (error: Error) => {
          callbacks.onError(error);
        }
      },
      abortSignal
    ).catch((error: Error) => {
      if (error instanceof ChatError) {
        callbacks.onError(error);
      } else {
        callbacks.onError(ChatError.networkError(error.message));
      }
    });
  }
}
