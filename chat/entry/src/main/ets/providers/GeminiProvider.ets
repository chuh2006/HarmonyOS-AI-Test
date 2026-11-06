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

// Gemini Generate Content API 请求
interface GeminiRequest {
  contents: GeminiContent[];
  generationConfig?: {
    temperature?: number;
    maxOutputTokens?: number;
    thinkingConfig?: {
      includeThoughts: boolean;
      thinkingBudget?: number;
    };
  };
  tools?: GeminiTool[];
}

interface GeminiContent {
  role: 'user' | 'model';
  parts: GeminiPart[];
}

interface GeminiPart {
  text?: string;
  thought?: boolean;
  thoughtSignature?: string;
  functionCall?: {
    name: string;
    args: Record<string, any>;
  };
  functionResponse?: {
    name: string;
    response: any;
  };
}

interface GeminiTool {
  functionDeclarations: {
    name: string;
    description: string;
    parameters: any;
  }[];
}

// Gemini流式响应
interface GeminiStreamChunk {
  candidates?: {
    content: {
      parts: GeminiPart[];
      role: string;
    };
    finishReason?: string;
    index: number;
  }[];
  usageMetadata?: {
    promptTokenCount: number;
    candidatesTokenCount: number;
    totalTokenCount: number;
  };
  error?: {
    code: number;
    message: string;
    status: string;
  };
}

export class GeminiProvider {
  private settings: ProviderSettings;
  private baseUrl: string;
  
  constructor(settings: ProviderSettings) {
    this.settings = settings;
    this.baseUrl = settings.baseUrl || 'https://generativelanguage.googleapis.com';
  }
  
  // 转换消息为Gemini格式
  private convertMessages(messages: Message[]): GeminiContent[] {
    const result: GeminiContent[] = [];
    
    for (const msg of messages) {
      if (msg.role === 'system') {
        // Gemini不支持system消息，跳过
        continue;
      }
      
      const parts: GeminiPart[] = [];
      
      // 优先使用已保存的parts(如果有)
      if (msg.protocolData?.gemini?.parts) {
        for (const part of msg.protocolData.gemini.parts) {
          const geminiPart: GeminiPart = {};
          
          if (part.text !== undefined) {
            geminiPart.text = part.text;
          }
          if (part.thought !== undefined) {
            geminiPart.thought = part.thought;
          }
          if (part.functionCall) {
            geminiPart.functionCall = part.functionCall;
          }
          if (part.functionResponse) {
            geminiPart.functionResponse = part.functionResponse;
          }
          
          // 添加思考签名
          if (part.thoughtSignature) {
            geminiPart.thoughtSignature = part.thoughtSignature;
          }
          
          parts.push(geminiPart);
        }
      } else {
        // 从消息内容构建parts
        
        // 添加思考内容
        if (msg.thinking) {
          parts.push({
            text: msg.thinking,
            thought: true
          });
        }
        
        // 添加文本内容
        if (msg.content) {
          parts.push({
            text: msg.content
          });
        }
        
        // 添加工具调用
        if (msg.toolCalls && msg.toolCalls.length > 0) {
          for (const tc of msg.toolCalls) {
            parts.push({
              functionCall: {
                name: tc.type,
                args: JSON.parse(tc.arguments)
              }
            });
          }
        }
        
        // 处理工具结果
        if (msg.role === 'tool' && msg.toolCalls) {
          for (const tc of msg.toolCalls) {
            if (tc.result) {
              parts.push({
                functionResponse: {
                  name: tc.type,
                  response: { result: tc.result }
                }
              });
            }
          }
        }
      }
      
      if (parts.length > 0) {
        result.push({
          role: msg.role === 'assistant' ? 'model' : 'user',
          parts
        });
      }
    }
    
    return result;
  }
  
  // 获取工具定义
  private getToolDefinitions(): GeminiTool[] {
    return [
      {
        functionDeclarations: [
          {
            name: 'search',
            description: '搜索网页获取信息',
            parameters: {
              type: 'OBJECT',
              properties: {
                query: {
                  type: 'STRING',
                  description: '搜索关键词'
                }
              },
              required: ['query']
            }
          },
          {
            name: 'fetch',
            description: '抓取指定网页的内容',
            parameters: {
              type: 'OBJECT',
              properties: {
                url: {
                  type: 'STRING',
                  description: '要抓取的网页URL'
                }
              },
              required: ['url']
            }
          }
        ]
      }
    ];
  }
  
  // 流式请求
  async *streamChat(
    messages: Message[],
    config: ModelConfig,
    abortSignal?: { aborted: boolean }
  ): AsyncGenerator<StreamEvent> {
    const url = `${this.baseUrl}/v1beta/models/${config.modelId}:streamGenerateContent?alt=sse`;
    
    const requestBody: GeminiRequest = {
      contents: this.convertMessages(messages),
      tools: this.getToolDefinitions(),
      generationConfig: {
        maxOutputTokens: config.maxTokens || 8192,
        thinkingConfig: {
          includeThoughts: config.thinkingEnabled
        }
      }
    };
    
    // 思考预算配置
    if (config.thinkingEnabled && config.thinkingEffort !== 'none') {
      const budgetMap: Record<string, number> = {
        'low': 1024,
        'medium': 4096,
        'high': 16384
      };
      if (budgetMap[config.thinkingEffort]) {
        requestBody.generationConfig!.thinkingConfig!.thinkingBudget = budgetMap[config.thinkingEffort];
      }
    }
    
    const httpRequest = http.createHttp();
    
    try {
      const response = await httpRequest.request(
        url,
        {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type': 'application/json',
            'x-goog-api-key': this.settings.apiKey
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
      
      // 保存所有parts及其签名
      const allParts: ContentPart[] = [];
      const thoughtSignatures: Map<number, string> = new Map();
      let currentToolCall: Partial<ToolCall> | null = null;
      let partIndex = 0;
      
      for (const line of lines) {
        if (abortSignal?.aborted) {
          throw ChatError.stopped();
        }
        
        if (!line.startsWith('data: ')) continue;
        
        const data = line.substring(6).trim();
        if (data === '[DONE]') break;
        
        try {
          const chunk: GeminiStreamChunk = JSON.parse(data);
          
          // 处理错误
          if (chunk.error) {
            yield {
              type: 'error',
              error: chunk.error.message
            };
            return;
          }
          
          if (chunk.candidates && chunk.candidates.length > 0) {
            const candidate = chunk.candidates[0];
            
            // 处理parts
            if (candidate.content?.parts) {
              for (const part of candidate.content.parts) {
                // 保存思考签名
                if (part.thoughtSignature) {
                  thoughtSignatures.set(partIndex, part.thoughtSignature);
                }
                
                // 处理函数调用
                if (part.functionCall) {
                  currentToolCall = {
                    id: `call_${Date.now()}_${partIndex}`,
                    type: part.functionCall.name as 'search' | 'fetch',
                    arguments: JSON.stringify(part.functionCall.args),
                    status: 'pending'
                  };
                  
                  // 保存为ContentPart
                  allParts.push({
                    type: 'tool_call',
                    functionCall: part.functionCall,
                    thoughtSignature: part.thoughtSignature
                  });
                  
                  yield {
                    type: 'tool_call_end',
                    toolCall: currentToolCall
                  };
                  
                  currentToolCall = null;
                  partIndex++;
                  continue;
                }
                
                // 处理函数响应
                if (part.functionResponse) {
                  allParts.push({
                    type: 'tool_result',
                    functionResponse: part.functionResponse
                  });
                  partIndex++;
                  continue;
                }
                
                // 处理文本和思考
                if (part.text !== undefined) {
                  const contentPart: ContentPart = {
                    type: part.thought ? 'thinking' : 'text',
                    text: part.text,
                    thought: part.thought,
                    thoughtSignature: part.thoughtSignature
                  };
                  allParts.push(contentPart);
                  
                  if (part.thought) {
                    yield {
                      type: 'thinking_delta',
                      data: part.text,
                      protocolData: { thoughtSignature: part.thoughtSignature }
                    };
                  } else {
                    yield {
                      type: 'content_delta',
                      data: part.text
                    };
                  }
                  
                  partIndex++;
                }
              }
            }
            
            // 使用量信息
            if (chunk.usageMetadata) {
              yield {
                type: 'usage',
                usage: {
                  inputTokens: chunk.usageMetadata.promptTokenCount,
                  outputTokens: chunk.usageMetadata.candidatesTokenCount
                }
              };
            }
            
            // 完成
            if (candidate.finishReason === 'STOP' || candidate.finishReason === 'MAX_TOKENS') {
              yield {
                type: 'complete',
                protocolData: {
                  parts: allParts,
                  thoughtSignatures
                }
              };
              return;
            }
          }
        } catch (e) {
          console.error('Gemini stream parse error:', e);
        }
      }
      
      yield {
        type: 'complete',
        protocolData: {
          parts: allParts,
          thoughtSignatures
        }
      };
      
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
    
    if (statusCode === 400 && errorMessage.includes('API key')) {
      throw ChatError.invalidApiKey('gemini');
    } else if (statusCode === 401 || statusCode === 403) {
      throw ChatError.invalidApiKey('gemini');
    } else if (statusCode === 429) {
      throw ChatError.rateLimited('gemini');
    } else {
      throw new ChatError(errorMessage, 'HTTP_ERROR', 'gemini');
    }
  }
}
