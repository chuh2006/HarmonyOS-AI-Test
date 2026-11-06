import { httpStreamRequest } from '../services/HttpStream';
import {
  Message,
  ModelConfig,
  StreamEvent,
  ToolCall,
  ProviderSettings,
  ChatError,
  ContentPart
} from '../types/Types';
import { StreamChatCallbacks } from './DeepSeekProvider';

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
  streamChat(
    messages: Message[],
    config: ModelConfig,
    callbacks: StreamChatCallbacks,
    abortSignal?: { aborted: boolean }
  ): void {
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
    
    // 保存所有parts及其签名
    const allParts: ContentPart[] = [];
    const thoughtSignatures: Record<number, string> = {};
    let partIndex = 0;
    
    httpStreamRequest(
      {
        url,
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-goog-api-key': this.settings.apiKey
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
            const chunk: GeminiStreamChunk = JSON.parse(data);
            
            // 处理错误
            if (chunk.error) {
              callbacks.onEvent({
                type: 'error',
                error: chunk.error.message
              });
              return;
            }
            
            if (chunk.candidates && chunk.candidates.length > 0) {
              const candidate = chunk.candidates[0];
              
              // 处理parts
              if (candidate.content?.parts) {
                for (const part of candidate.content.parts) {
                  // 保存思考签名
                  if (part.thoughtSignature) {
                    thoughtSignatures[partIndex] = part.thoughtSignature;
                  }
                  
                  // 处理函数调用
                  if (part.functionCall) {
                    const toolCall: ToolCall = {
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
                    
                    callbacks.onEvent({
                      type: 'tool_call_end',
                      toolCall
                    });
                    
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
                      callbacks.onEvent({
                        type: 'thinking_delta',
                        data: part.text,
                        protocolData: { thoughtSignature: part.thoughtSignature }
                      });
                    } else {
                      callbacks.onEvent({
                        type: 'content_delta',
                        data: part.text
                      });
                    }
                    
                    partIndex++;
                  }
                }
              }
              
              // 使用量信息
              if (chunk.usageMetadata) {
                callbacks.onEvent({
                  type: 'usage',
                  usage: {
                    inputTokens: chunk.usageMetadata.promptTokenCount,
                    outputTokens: chunk.usageMetadata.candidatesTokenCount
                  }
                });
              }
              
              // 完成
              if (candidate.finishReason === 'STOP' || candidate.finishReason === 'MAX_TOKENS') {
                callbacks.onEvent({
                  type: 'complete',
                  protocolData: {
                    parts: allParts,
                    thoughtSignatures
                  }
                });
              }
            }
          } catch (e) {
            console.error('Gemini stream parse error:', e);
          }
        },
        
        onComplete: () => {
          callbacks.onEvent({
            type: 'complete',
            protocolData: {
              parts: allParts,
              thoughtSignatures
            }
          });
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
