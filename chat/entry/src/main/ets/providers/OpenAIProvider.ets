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

// OpenAI Responses API 请求
interface OpenAIRequest {
  model: string;
  input: OpenAIInput;
  stream: boolean;
  reasoning?: {
    effort?: 'low' | 'medium' | 'high' | 'xhigh' | 'max';
    mode?: 'standard' | 'pro';
  };
  service_tier?: 'auto' | 'fast' | 'ultrafast';
  tools?: OpenAITool[];
  store?: boolean;
}

type OpenAIInput = string | OpenAIInputMessage[];

interface OpenAIInputMessage {
  role: 'user' | 'assistant' | 'system' | 'tool';
  content: string | OpenAIContentPart[];
  name?: string;
  tool_call_id?: string;
}

interface OpenAIContentPart {
  type: 'text' | 'tool_call' | 'tool_result';
  text?: string;
  tool_call?: any;
  tool_result?: any;
}

interface OpenAITool {
  type: 'function';
  name: string;
  description: string;
  parameters: any;
}

// OpenAI流式响应事件
interface OpenAIStreamEvent {
  type: string;
  response?: {
    id: string;
    output: any[];
    usage?: {
      input_tokens: number;
      output_tokens: number;
    };
  };
  item?: any;
  delta?: string;
  content_index?: number;
  output_index?: number;
  part?: any;
  error?: {
    message: string;
    type: string;
  };
}

export class OpenAIProvider {
  private settings: ProviderSettings;
  private baseUrl: string;
  
  constructor(settings: ProviderSettings) {
    this.settings = settings;
    this.baseUrl = settings.baseUrl || 'https://api.openai.com';
  }
  
  // 转换消息为OpenAI格式
  private convertMessages(messages: Message[]): OpenAIInputMessage[] {
    const result: OpenAIInputMessage[] = [];
    
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
        const content: OpenAIContentPart[] = [];
        
        // 添加文本内容
        if (msg.content) {
          content.push({
            type: 'text',
            text: msg.content
          });
        }
        
        // 添加工具调用
        if (msg.toolCalls && msg.toolCalls.length > 0) {
          for (const tc of msg.toolCalls) {
            content.push({
              type: 'tool_call',
              tool_call: {
                id: tc.id,
                type: 'function',
                function: {
                  name: tc.type,
                  arguments: tc.arguments
                }
              }
            });
          }
        }
        
        if (content.length > 0) {
          result.push({
            role: msg.role as 'user' | 'assistant' | 'system',
            content: content.length === 1 && content[0].type === 'text' 
              ? content[0].text! 
              : content
          });
        }
      }
    }
    
    return result;
  }
  
  // 获取工具定义
  private getToolDefinitions(): OpenAITool[] {
    return [
      {
        type: 'function',
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
      },
      {
        type: 'function',
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
    ];
  }
  
  // 流式请求
  streamChat(
    messages: Message[],
    config: ModelConfig,
    callbacks: StreamChatCallbacks,
    abortSignal?: { aborted: boolean }
  ): void {
    const url = `${this.baseUrl}/v1/responses`;
    
    const requestBody: OpenAIRequest = {
      model: config.modelId,
      input: this.convertMessages(messages),
      stream: true,
      tools: this.getToolDefinitions(),
      store: false // 无状态模式
    };
    
    // 思考配置
    if (config.thinkingEnabled && config.thinkingEffort !== 'none') {
      requestBody.reasoning = {
        effort: config.thinkingEffort as 'low' | 'medium' | 'high' | 'xhigh' | 'max'
      };
      
      if (config.reasoningMode) {
        requestBody.reasoning.mode = config.reasoningMode;
      }
    }
    
    // 速度模式配置(实际功能)
    if (config.speedMode && config.speedMode !== 'normal') {
      requestBody.service_tier = config.speedMode as 'fast' | 'ultrafast';
    }
    
    let currentToolCall: Partial<ToolCall> | null = null;
    let toolCallArgs = '';
    let responseId = '';
    let encryptedContent = '';
    
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
            const event: OpenAIStreamEvent = JSON.parse(data);
            
            // 处理错误
            if (event.error) {
              callbacks.onEvent({
                type: 'error',
                error: event.error.message
              });
              return;
            }
            
            // 记录响应ID
            if (event.response?.id) {
              responseId = event.response.id;
            }
            
            // 处理不同类型的事件
            switch (event.type) {
              case 'response.output_item.added':
                if (event.item?.type === 'function_call') {
                  currentToolCall = {
                    id: event.item.id || '',
                    type: event.item.name as 'search' | 'fetch',
                    arguments: '',
                    status: 'pending'
                  };
                  toolCallArgs = '';
                  callbacks.onEvent({
                    type: 'tool_call_start',
                    toolCall: currentToolCall
                  });
                }
                break;
                
              case 'response.summary_text.delta':
                if (event.delta) {
                  callbacks.onEvent({
                    type: 'thinking_delta',
                    data: event.delta
                  });
                }
                break;
                
              case 'response.output_text.delta':
                if (event.delta) {
                  callbacks.onEvent({
                    type: 'content_delta',
                    data: event.delta
                  });
                }
                break;
                
              case 'response.function_call_arguments.delta':
                if (event.delta && currentToolCall) {
                  toolCallArgs += event.delta;
                  callbacks.onEvent({
                    type: 'tool_call_delta',
                    toolCall: { ...currentToolCall, arguments: toolCallArgs }
                  });
                }
                break;
                
              case 'response.function_call_arguments.done':
                if (currentToolCall) {
                  currentToolCall.arguments = toolCallArgs;
                  currentToolCall.status = 'pending';
                  callbacks.onEvent({
                    type: 'tool_call_end',
                    toolCall: currentToolCall
                  });
                  currentToolCall = null;
                  toolCallArgs = '';
                }
                break;
                
              case 'response.completed':
                // 提取加密的reasoning内容用于后续请求
                if (event.response?.output) {
                  for (const item of event.response.output) {
                    if (item.type === 'reasoning' && item.encrypted_content) {
                      encryptedContent = item.encrypted_content;
                    }
                  }
                }
                
                if (event.response?.usage) {
                  callbacks.onEvent({
                    type: 'usage',
                    usage: {
                      inputTokens: event.response.usage.input_tokens,
                      outputTokens: event.response.usage.output_tokens
                    }
                  });
                }
                
                callbacks.onEvent({
                  type: 'complete',
                  protocolData: {
                    responseId,
                    encryptedContent: encryptedContent || undefined,
                    output: event.response?.output
                  }
                });
                break;
            }
          } catch (e) {
            console.error('OpenAI stream parse error:', e);
          }
        },
        
        onComplete: () => {
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
