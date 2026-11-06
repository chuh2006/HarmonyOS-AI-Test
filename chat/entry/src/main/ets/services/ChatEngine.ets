import {
  Message,
  ModelConfig,
  StreamEvent,
  ToolCall,
  MessageStatus,
  ChatError,
  AppSettings,
  ProviderId
} from '../types/Types';
import { DeepSeekProvider } from '../providers/DeepSeekProvider';
import { OpenAIProvider } from '../providers/OpenAIProvider';
import { MercuryProvider } from '../providers/MercuryProvider';
import { GeminiProvider } from '../providers/GeminiProvider';
import { DeepSeekTools, ToolResult } from './DeepSeekTools';
import { Store } from './Store';

// 聊天状态回调
export interface ChatCallbacks {
  onMessageUpdate: (message: Message) => void;
  onToolCallUpdate: (messageId: string, toolCall: ToolCall) => void;
  onError: (error: Error) => void;
  onComplete: (message: Message) => void;
}

// 生成阶段
export type GenerationPhase = 
  | 'idle' 
  | 'requesting' 
  | 'thinking' 
  | 'tool_calling' 
  | 'answering' 
  | 'complete' 
  | 'error';

export class ChatEngine {
  private store: Store;
  private settings: AppSettings;
  private abortSignal: { aborted: boolean } = { aborted: false };
  private currentMessageId?: string;
  private currentPhase: GenerationPhase = 'idle';
  
  // 工具调用循环限制
  private readonly MAX_TOOL_ITERATIONS = 10;
  
  constructor(store: Store, settings: AppSettings) {
    this.store = store;
    this.settings = settings;
  }
  
  // 更新设置
  updateSettings(settings: AppSettings): void {
    this.settings = settings;
  }
  
  // 获取当前阶段
  getPhase(): GenerationPhase {
    return this.currentPhase;
  }
  
  // 是否正在生成
  isGenerating(): boolean {
    return this.currentPhase !== 'idle' && this.currentPhase !== 'complete' && this.currentPhase !== 'error';
  }
  
  // 停止生成
  stop(): void {
    this.abortSignal.aborted = true;
    this.currentPhase = 'idle';
  }
  
  // 重置中止信号
  private resetAbort(): void {
    this.abortSignal = { aborted: false };
  }
  
  // 获取Provider实例
  private getProvider(config: ModelConfig) {
    const providerSettings = this.settings.providers[config.providerId];
    
    if (!providerSettings || !providerSettings.apiKey) {
      throw new ChatError(
        `请先配置 ${config.providerId} 的 API Key`,
        'NO_API_KEY',
        config.providerId
      );
    }
    
    switch (config.providerId) {
      case 'deepseek':
        return new DeepSeekProvider(providerSettings);
      case 'openai':
        return new OpenAIProvider(providerSettings);
      case 'mercury':
        return new MercuryProvider(providerSettings);
      case 'gemini':
        return new GeminiProvider(providerSettings);
      default:
        throw new Error(`Unknown provider: ${config.providerId}`);
    }
  }
  
  // 发送消息并开始生成
  async sendMessage(
    sessionId: string,
    content: string,
    config: ModelConfig,
    callbacks: ChatCallbacks
  ): Promise<void> {
    this.resetAbort();
    this.currentPhase = 'requesting';
    
    try {
      // 创建用户消息
      const userMessage: Message = {
        id: `msg_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
        role: 'user',
        content,
        status: 'complete',
        timestamp: Date.now()
      };
      
      // 保存用户消息
      await this.store.addMessage(sessionId, userMessage);
      callbacks.onMessageUpdate(userMessage);
      
      // 获取历史消息
      const session = await this.store.getSession(sessionId);
      if (!session) {
        throw new Error('Session not found');
      }
      
      // 开始生成助手回复
      await this.generateResponse(sessionId, session.messages, config, callbacks);
      
    } catch (error) {
      this.currentPhase = 'error';
      callbacks.onError(error as Error);
      throw error;
    }
  }
  
  // 生成助手回复(支持工具调用循环)
  private async generateResponse(
    sessionId: string,
    messages: Message[],
    config: ModelConfig,
    callbacks: ChatCallbacks
  ): Promise<void> {
    let iteration = 0;
    let currentMessages = [...messages];
    
    while (iteration < this.MAX_TOOL_ITERATIONS) {
      if (this.abortSignal.aborted) {
        throw ChatError.stopped();
      }
      
      iteration++;
      
      // 创建助手消息
      const assistantMessage: Message = {
        id: `msg_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
        role: 'assistant',
        content: '',
        status: 'streaming',
        timestamp: Date.now(),
        toolCalls: []
      };
      
      this.currentMessageId = assistantMessage.id;
      this.currentPhase = 'requesting';
      
      // 保存助手消息(初始状态)
      await this.store.addMessage(sessionId, assistantMessage);
      callbacks.onMessageUpdate(assistantMessage);
      
      // 流式生成
      const provider = this.getProvider(config);
      
      let fullContent = '';
      let fullThinking = '';
      let hasToolCalls = false;
      const toolCalls: ToolCall[] = [];
      let protocolData: any = null;
      let streamCompleted = false;
      let streamError: Error | null = null;
      
      // 使用Promise包装回调
      await new Promise<void>((resolve) => {
        provider.streamChat(
          currentMessages,
          config,
          {
            onEvent: (event: StreamEvent) => {
              if (this.abortSignal.aborted) {
                return;
              }
              
              // 处理不同类型的流事件
              switch (event.type) {
                case 'thinking_delta':
                  this.currentPhase = 'thinking';
                  if (event.data) {
                    fullThinking += event.data;
                    assistantMessage.thinking = fullThinking;
                    callbacks.onMessageUpdate({ ...assistantMessage });
                  }
                  break;
                  
                case 'content_delta':
                  this.currentPhase = 'answering';
                  if (event.data) {
                    fullContent += event.data;
                    assistantMessage.content = fullContent;
                    callbacks.onMessageUpdate({ ...assistantMessage });
                  }
                  break;
                  
                case 'content_replace':
                  // 扩散模式:替换整个内容
                  this.currentPhase = 'answering';
                  if (event.data) {
                    fullContent = event.data;
                    assistantMessage.content = fullContent;
                    callbacks.onMessageUpdate({ ...assistantMessage });
                  }
                  break;
                  
                case 'tool_call_start':
                  this.currentPhase = 'tool_calling';
                  hasToolCalls = true;
                  if (event.toolCall) {
                    const tc: ToolCall = {
                      id: event.toolCall.id || '',
                      type: event.toolCall.type || 'search',
                      arguments: event.toolCall.arguments || '',
                      status: 'running',
                      startTime: Date.now()
                    };
                    toolCalls.push(tc);
                    assistantMessage.toolCalls = [...toolCalls];
                    callbacks.onToolCallUpdate(assistantMessage.id, tc);
                  }
                  break;
                  
                case 'tool_call_delta':
                  if (event.toolCall) {
                    const existingTc = toolCalls.find(tc => tc.id === event.toolCall!.id);
                    if (existingTc) {
                      existingTc.arguments = event.toolCall.arguments || '';
                      callbacks.onToolCallUpdate(assistantMessage.id, existingTc);
                    }
                  }
                  break;
                  
                case 'tool_call_end':
                  if (event.toolCall) {
                    const existingTc = toolCalls.find(tc => tc.id === event.toolCall!.id);
                    if (existingTc) {
                      existingTc.arguments = event.toolCall.arguments || '';
                      existingTc.status = 'pending';
                      callbacks.onToolCallUpdate(assistantMessage.id, existingTc);
                    } else {
                      // 工具调用完成但没有start事件(Gemini)
                      const tc: ToolCall = {
                        id: event.toolCall.id || '',
                        type: event.toolCall.type || 'search',
                        arguments: event.toolCall.arguments || '',
                        status: 'pending',
                        startTime: Date.now()
                      };
                      toolCalls.push(tc);
                      assistantMessage.toolCalls = [...toolCalls];
                      callbacks.onToolCallUpdate(assistantMessage.id, tc);
                      hasToolCalls = true;
                    }
                  }
                  break;
                  
                case 'usage':
                  // 可以记录token使用量
                  break;
                  
                case 'complete':
                  protocolData = event.protocolData;
                  break;
                  
                case 'error':
                  streamError = new ChatError(
                    event.error || '生成失败',
                    'STREAM_ERROR',
                    config.providerId
                  );
                  break;
              }
            },
            
            onComplete: () => {
              streamCompleted = true;
              resolve();
            },
            
            onError: (error: Error) => {
              streamError = error;
              streamCompleted = true;
              resolve();
            }
          },
          this.abortSignal
        );
      });
      
      // 检查中止
      if (this.abortSignal.aborted) {
        assistantMessage.status = 'stopped';
        await this.store.updateMessage(sessionId, assistantMessage.id, {
          status: 'stopped',
          content: fullContent
        });
        callbacks.onMessageUpdate(assistantMessage);
        throw ChatError.stopped();
      }
      
      // 检查错误
      if (streamError) {
        assistantMessage.status = 'error';
        assistantMessage.error = streamError.message;
        assistantMessage.content = fullContent; // 保留已生成的内容
        
        await this.store.updateMessage(sessionId, assistantMessage.id, assistantMessage);
        callbacks.onMessageUpdate(assistantMessage);
        
        this.currentPhase = 'error';
        this.currentMessageId = undefined;
        
        callbacks.onError(streamError);
        throw streamError;
      }
      
      // 更新消息为完成状态
      assistantMessage.content = fullContent;
      assistantMessage.thinking = fullThinking || undefined;
      assistantMessage.toolCalls = toolCalls;
      
      // 保存协议数据
      if (protocolData) {
        this.saveProtocolData(assistantMessage, config.providerId, protocolData);
      }
      
      // 如果有工具调用，执行工具
      if (hasToolCalls && toolCalls.length > 0) {
        assistantMessage.status = 'tool_call';
        await this.store.updateMessage(sessionId, assistantMessage.id, assistantMessage);
        callbacks.onMessageUpdate(assistantMessage);
        
        // 执行工具调用
        await this.executeTools(sessionId, assistantMessage, toolCalls, callbacks);
        
        // 重新获取消息历史，继续生成
        const updatedSession = await this.store.getSession(sessionId);
        if (updatedSession) {
          currentMessages = updatedSession.messages;
          continue; // 继续下一轮生成
        }
      } else {
        // 没有工具调用，完成生成
        assistantMessage.status = 'complete';
        await this.store.updateMessage(sessionId, assistantMessage.id, assistantMessage);
        callbacks.onMessageUpdate(assistantMessage);
        callbacks.onComplete(assistantMessage);
        
        this.currentPhase = 'complete';
        this.currentMessageId = undefined;
        return;
      }
    }
    
    // 超过最大迭代次数
    const errorMessage = new ChatError(
      `工具调用次数超过限制(${this.MAX_TOOL_ITERATIONS})`,
      'MAX_ITERATIONS',
      config.providerId
    );
    
    callbacks.onError(errorMessage);
    throw errorMessage;
  }
  
  // 执行工具调用
  private async executeTools(
    sessionId: string,
    assistantMessage: Message,
    toolCalls: ToolCall[],
    callbacks: ChatCallbacks
  ): Promise<void> {
    // 初始化工具
    const deepseekSettings = this.settings.providers.deepseek;
    const tools = new DeepSeekTools(deepseekSettings);
    
    // 并行执行所有工具调用
    const toolPromises = toolCalls.map(async (tc) => {
      tc.status = 'running';
      tc.startTime = Date.now();
      callbacks.onToolCallUpdate(assistantMessage.id, tc);
      
      try {
        const result: ToolResult = await tools.executeTool(tc.type, tc.arguments);
        
        tc.status = result.success ? 'complete' : 'error';
        tc.result = result.data;
        tc.error = result.error;
        tc.endTime = Date.now();
        
      } catch (error) {
        tc.status = 'error';
        tc.error = (error as Error).message;
        tc.endTime = Date.now();
      }
      
      callbacks.onToolCallUpdate(assistantMessage.id, tc);
      return tc;
    });
    
    const completedToolCalls = await Promise.all(toolPromises);
    
    // 更新助手消息的工具调用状态
    assistantMessage.toolCalls = completedToolCalls;
    await this.store.updateMessage(sessionId, assistantMessage.id, {
      toolCalls: completedToolCalls
    });
    
    // 创建工具结果消息
    const toolMessage: Message = {
      id: `msg_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      role: 'tool',
      content: '',
      status: 'complete',
      timestamp: Date.now(),
      toolCalls: completedToolCalls
    };
    
    await this.store.addMessage(sessionId, toolMessage);
    callbacks.onMessageUpdate(toolMessage);
  }
  
  // 保存协议特定数据
  private saveProtocolData(message: Message, providerId: ProviderId, data: any): void {
    if (!message.protocolData) {
      message.protocolData = {};
    }
    
    switch (providerId) {
      case 'deepseek':
        message.protocolData.deepseek = {
          thinkingContent: data.thinkingContent
        };
        break;
        
      case 'openai':
        message.protocolData.openai = {
          responseId: data.responseId,
          encryptedContent: data.encryptedContent,
          output: data.output
        };
        break;
        
      case 'gemini':
        message.protocolData.gemini = {
          parts: data.parts,
          thoughtSignatures: data.thoughtSignatures
        };
        break;
        
      case 'mercury':
        message.protocolData.mercury = {
          messageId: data.messageId
        };
        break;
    }
  }
  
  // 重试最后一条失败的消息
  async retryLastMessage(
    sessionId: string,
    config: ModelConfig,
    callbacks: ChatCallbacks
  ): Promise<void> {
    const session = await this.store.getSession(sessionId);
    if (!session) {
      throw new Error('Session not found');
    }
    
    // 查找最后一条助手消息
    const lastAssistantMsg = [...session.messages].reverse().find(m => m.role === 'assistant');
    
    if (!lastAssistantMsg || lastAssistantMsg.status !== 'error') {
      throw new Error('没有可重试的消息');
    }
    
    // 删除失败的消息及其后的所有消息
    const msgIndex = session.messages.findIndex(m => m.id === lastAssistantMsg.id);
    const messagesToKeep = session.messages.slice(0, msgIndex);
    
    await this.store.updateSession(sessionId, { messages: messagesToKeep });
    
    // 重新生成
    this.resetAbort();
    await this.generateResponse(sessionId, messagesToKeep, config, callbacks);
  }
}
