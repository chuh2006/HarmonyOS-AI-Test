import { httpJsonRequest } from '../services/HttpStream';
import {
  Message,
  ModelConfig,
  StreamEvent,
  ToolCall,
  ProviderSettings,
  ChatError,
  ContentPart
} from '../types/Types';
import http from '@ohos.net.http';

// DeepSeek Anthropic API 消息格式
interface AnthropicMessage {
  role: 'user' | 'assistant';
  content: AnthropicContent[];
}

interface AnthropicContent {
  type: 'text' | 'thinking' | 'tool_use' | 'tool_result';
  text?: string;
  thinking?: string;
  id?: string;
  name?: string;
  input?: any;
  tool_use_id?: string;
  content?: string;
}

// DeepSeek请求体
interface DeepSeekRequest {
  model: string;
  messages: AnthropicMessage[];
  max_tokens: number;
  stream: boolean;
  thinking?: { type: 'enabled' | 'disabled' };
  output_config?: { effort: 'low' | 'high' | 'max' };
  tools?: DeepSeekTool[];
}

interface DeepSeekTool {
  name: string;
  description: string;
  input_schema: any;
}

// DeepSeek流式响应事件
interface DeepSeekStreamEvent {
  type: string;
  index?: number;
  content_block?: {
    type: string;
    text?: string;
    thinking?: string;
    id?: string;
    name?: string;
    input?: any;
  };
  delta?: {
    type?: string;
    text?: string;
    thinking?: string;
    partial_json?: string;
  };
  message?: any;
  usage?: {
    input_tokens: number;
    output_tokens: number;
  };
  error?: {
    type: string;
    message: string;
  };
}

export class DeepSeekProvider {
  private settings: ProviderSettings;
  private baseUrl: string;
  
  constructor(settings: ProviderSettings) {
    this.settings = settings;
    this.baseUrl = settings.baseUrl || 'https://api.deepseek.com';
  }
  
  // 转换消息为Anthropic格式
  private convertMessages(messages: Message[]): AnthropicMessage[] {
    const result: AnthropicMessage[] = [];
    
    for (const msg of messages) {
      if (msg.role === 'system') {
        // DeepSeek不支持system消息，转为user消息前缀
        continue;
      }
      
      const content: AnthropicContent[] = [];
      
      // 添加思考内容(如果有)
      if (msg.thinking && msg.protocolData?.deepseek?.thinkingContent) {
        content.push({
          type: 'thinking',
          thinking: msg.protocolData.deepseek.thinkingContent
        });
      }
      
      // 添加工具调用
      if (msg.toolCalls && msg.toolCalls.length > 0) {
        for (const tc of msg.toolCalls) {
          if (tc.type === 'search' || tc.type === 'fetch') {
            content.push({
              type: 'tool_use',
              id: tc.id,
              name: tc.type,
              input: JSON.parse(tc.arguments)
            });
          }
        }
      }
      
      // 添加文本内容
      if (msg.content) {
        content.push({
          type: 'text',
          text: msg.content
        });
      }
      
      // 处理工具结果(role=tool的消息)
      if (msg.role === 'tool' && msg.toolCalls && msg.toolCalls.length > 0) {
        for (const tc of msg.toolCalls) {
          if (tc.result) {
            content.push({
              type: 'tool_result',
              tool_use_id: tc.id,
              content: tc.result
            });
          }
        }
      }
      
      if (content.length > 0) {
        result.push({
          role: msg.role === 'assistant' ? 'assistant' : 'user',
          content
        });
      }
    }
    
    return result;
  }
  
  // 获取工具定义
  private getToolDefinitions(): DeepSeekTool[] {
    return [
      {
        name: 'search',
        description: '搜索网页获取信息',
        input_schema: {
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
        name: 'fetch',
        description: '抓取指定网页的内容',
        input_schema: {
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
  async *streamChat(
    messages: Message[],
    config: ModelConfig,
    abortSignal?: { aborted: boolean }
  ): AsyncGenerator<StreamEvent> {
    const url = `${this.baseUrl}/anthropic/v1/messages`;
    
    const requestBody: DeepSeekRequest = {
      model: config.modelId,
      messages: this.convertMessages(messages),
      max_tokens: config.maxTokens || 8192,
      stream: true,
      tools: this.getToolDefinitions()
    };
    
    // 思考配置
    if (config.thinkingEnabled && config.thinkingEffort !== 'none') {
      requestBody.thinking = { type: 'enabled' };
      requestBody.output_config = {
        effort: config.thinkingEffort as 'low' | 'high' | 'max'
      };
    } else {
      requestBody.thinking = { type: 'disabled' };
    }
    
    const httpRequest = http.createHttp();
    
    try {
      const response = await httpRequest.request(
        url,
        {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type': 'application/json',
            'x-api-key': this.settings.apiKey,
            'anthropic-version': '2023-06-01'
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
      
      let currentToolCall: Partial<ToolCall> | null = null;
      let toolCallJson = '';
      let thinkingContent = '';
      
      for (const line of lines) {
        if (abortSignal?.aborted) {
          throw ChatError.stopped();
        }
        
        if (!line.startsWith('data: ')) continue;
        
        const data = line.substring(6).trim();
        if (data === '[DONE]') break;
        
        try {
          const event: DeepSeekStreamEvent = JSON.parse(data);
          
          // 处理错误
          if (event.error) {
            yield {
              type: 'error',
              error: event.error.message
            };
            return;
          }
          
          // 处理不同类型的事件
          switch (event.type) {
            case 'content_block_start':
              if (event.content_block?.type === 'thinking') {
                yield { type: 'thinking_delta', data: '' };
              } else if (event.content_block?.type === 'tool_use') {
                currentToolCall = {
                  id: event.content_block.id || '',
                  type: event.content_block.name as 'search' | 'fetch',
                  arguments: '',
                  status: 'pending'
                };
                toolCallJson = '';
                yield {
                  type: 'tool_call_start',
                  toolCall: currentToolCall
                };
              }
              break;
              
            case 'content_block_delta':
              if (event.delta?.type === 'thinking_delta' && event.delta.thinking) {
                thinkingContent += event.delta.thinking;
                yield {
                  type: 'thinking_delta',
                  data: event.delta.thinking,
                  protocolData: { thinkingContent }
                };
              } else if (event.delta?.type === 'text_delta' && event.delta.text) {
                yield {
                  type: 'content_delta',
                  data: event.delta.text
                };
              } else if (event.delta?.type === 'input_json_delta' && event.delta.partial_json) {
                toolCallJson += event.delta.partial_json;
                if (currentToolCall) {
                  yield {
                    type: 'tool_call_delta',
                    toolCall: { ...currentToolCall, arguments: toolCallJson }
                  };
                }
              }
              break;
              
            case 'content_block_stop':
              if (currentToolCall) {
                currentToolCall.arguments = toolCallJson;
                currentToolCall.status = 'pending';
                yield {
                  type: 'tool_call_end',
                  toolCall: currentToolCall
                };
                currentToolCall = null;
                toolCallJson = '';
              }
              break;
              
            case 'message_delta':
              if (event.usage) {
                yield {
                  type: 'usage',
                  usage: {
                    inputTokens: event.usage.input_tokens,
                    outputTokens: event.usage.output_tokens
                  }
                };
              }
              break;
              
            case 'message_stop':
              yield {
                type: 'complete',
                protocolData: {
                  thinkingContent: thinkingContent || undefined
                }
              };
              return;
          }
        } catch (e) {
          // 忽略JSON解析错误，继续处理下一个事件
          console.error('DeepSeek stream parse error:', e);
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
      throw ChatError.invalidApiKey('deepseek');
    } else if (statusCode === 429) {
      throw ChatError.rateLimited('deepseek');
    } else {
      throw new ChatError(errorMessage, 'HTTP_ERROR', 'deepseek');
    }
  }
}
