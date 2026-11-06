// 服务商标识
export type ProviderId = 'deepseek' | 'openai' | 'mercury' | 'gemini';

// 消息角色
export type MessageRole = 'user' | 'assistant' | 'system' | 'tool';

// 消息状态
export type MessageStatus =
  | 'idle'        // 待处理
  | 'thinking'    // 思考中
  | 'tool_call'   // 工具调用中
  | 'streaming'   // 流式输出中
  | 'complete'    // 完成
  | 'stopped'     // 已停止
  | 'error';      // 错误

// 思考强度
export type ThinkingEffort = 'none' | 'low' | 'medium' | 'high' | 'xhigh' | 'max';

// OpenAI reasoning mode
export type OpenAIReasoningMode = 'standard' | 'pro';

// OpenAI速度模式
export type OpenAISpeedMode = 'normal' | 'fast' | 'ultrafast';

// 工具类型
export type ToolType = 'search' | 'fetch';

// 工具调用状态
export type ToolStatus = 'pending' | 'running' | 'complete' | 'error';

// 工具调用记录
export interface ToolCall {
  id: string;
  type: ToolType;
  arguments: string; // JSON字符串
  status: ToolStatus;
  result?: string;
  error?: string;
  startTime?: number;
  endTime?: number;
}

// 模型能力
export interface ModelCapabilities {
  supportsThinking: boolean;       // 支持思考模式
  supportsToolCall: boolean;       // 支持工具调用
  supportsStream: boolean;         // 支持流式输出
  supportsDiffusion?: boolean;     // 支持扩散输出(Mercury默认功能)
  thinkingEfforts?: ThinkingEffort[]; // 可选的思考强度
  reasoningModes?: OpenAIReasoningMode[]; // OpenAI的reasoning modes
  speedModes?: OpenAISpeedMode[];  // OpenAI的速度模式
  maxTokens?: number;              // 最大token数
}

// 模型定义
export interface ModelInfo {
  id: string;
  name: string;
  provider: ProviderId;
  capabilities: ModelCapabilities;
}

// 模型配置(用户选择的选项)
export interface ModelConfig {
  providerId: ProviderId;
  modelId: string;
  thinkingEnabled: boolean;
  thinkingEffort: ThinkingEffort;
  reasoningMode?: OpenAIReasoningMode;
  speedMode?: OpenAISpeedMode;
  diffusionEnabled?: boolean;
  maxTokens?: number;
}

// 消息内容部分(用于Gemini的Parts结构)
export interface ContentPart {
  type: 'text' | 'thinking' | 'tool_call' | 'tool_result' | 'thought_signature';
  text?: string;
  toolCall?: ToolCall;
  // Gemini特有
  functionCall?: {
    name: string;
    args: Record<string, any>;
  };
  functionResponse?: {
    name: string;
    response: any;
  };
  thoughtSignature?: string;
  thought?: boolean; // 是否是思考摘要
}

// 消息
export interface Message {
  id: string;
  role: MessageRole;
  content: string;              // 主要内容文本
  thinking?: string;            // 思考内容/摘要
  status: MessageStatus;
  toolCalls?: ToolCall[];       // 工具调用列表
  timestamp: number;
  error?: string;
  
  // 协议特定数据(用于继续对话)
  protocolData?: {
    // OpenAI Responses API
    openai?: {
      responseId?: string;
      encryptedContent?: string;
      reasoning?: any;
      output?: any[];
    };
    // Gemini
    gemini?: {
      parts?: ContentPart[];
      thoughtSignatures?: Record<number, string>; // 使用Record而不是Map以便JSON序列化
    };
    // DeepSeek Anthropic API
    deepseek?: {
      thinkingContent?: any;    // 需要回传的思考内容
    };
    // Mercury
    mercury?: {
      messageId?: string;
    };
  };
}

// 会话
export interface Session {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  messages: Message[];
  modelConfig: ModelConfig;     // 记住该会话使用的模型和配置
}

// Provider设置
export interface ProviderSettings {
  apiKey: string;
  baseUrl?: string;             // 自定义Base URL
}

// 全局设置
export interface AppSettings {
  providers: Record<ProviderId, ProviderSettings>;
  defaultProvider?: ProviderId;
  defaultModel?: string;
}

// 流式事件类型
export type StreamEventType =
  | 'thinking_delta'    // 思考内容增量
  | 'content_delta'     // 正文增量
  | 'content_replace'   // 内容替换(扩散模式)
  | 'tool_call_start'   // 工具调用开始
  | 'tool_call_delta'   // 工具调用参数增量
  | 'tool_call_end'     // 工具调用参数完成
  | 'complete'          // 生成完成
  | 'error'             // 错误
  | 'usage';            // Token使用量

// 流式事件
export interface StreamEvent {
  type: StreamEventType;
  data?: string;
  toolCall?: Partial<ToolCall>;
  error?: string;
  usage?: {
    inputTokens?: number;
    outputTokens?: number;
  };
  protocolData?: any;   // 协议特定的中间数据
}

// 生成状态(用于UI显示)
export interface GenerationState {
  isGenerating: boolean;
  phase: 'idle' | 'requesting' | 'thinking' | 'tool_calling' | 'answering' | 'complete' | 'error';
  currentMessageId?: string;
  error?: string;
}

// 错误类型
export class ChatError extends Error {
  code: string;
  provider?: ProviderId;
  
  constructor(message: string, code: string, provider?: ProviderId) {
    super(message);
    this.code = code;
    this.provider = provider;
  }
  
  static invalidApiKey(provider: ProviderId): ChatError {
    return new ChatError('API Key 无效', 'INVALID_API_KEY', provider);
  }
  
  static rateLimited(provider: ProviderId): ChatError {
    return new ChatError('请求过于频繁，请稍后再试', 'RATE_LIMITED', provider);
  }
  
  static networkError(detail?: string): ChatError {
    return new ChatError(detail || '网络连接失败', 'NETWORK_ERROR');
  }
  
  static timeout(): ChatError {
    return new ChatError('请求超时', 'TIMEOUT');
  }
  
  static parseError(detail?: string): ChatError {
    return new ChatError(detail || '响应解析失败', 'PARSE_ERROR');
  }
  
  static stopped(): ChatError {
    return new ChatError('已停止生成', 'STOPPED');
  }
}

// 内置模型列表
export const BUILTIN_MODELS: ModelInfo[] = [
  // DeepSeek
  {
    id: 'deepseek-flash',
    name: 'DeepSeek Flash',
    provider: 'deepseek',
    capabilities: {
      supportsThinking: true,
      supportsToolCall: true,
      supportsStream: true,
      thinkingEfforts: ['none', 'low', 'high', 'max'],
      maxTokens: 114514
    }
  },
  {
    id: 'deepseek-v4-pro',
    name: 'DeepSeek V4 Pro',
    provider: 'deepseek',
    capabilities: {
      supportsThinking: true,
      supportsToolCall: true,
      supportsStream: true,
      thinkingEfforts: ['none', 'low', 'high', 'max'],
      maxTokens: 114514
    }
  },
  // OpenAI
  {
    id: 'gpt-6-astra',
    name: 'GPT-6 Astra',
    provider: 'openai',
    capabilities: {
      supportsThinking: true,
      supportsToolCall: true,
      supportsStream: true,
      thinkingEfforts: ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
      reasoningModes: ['standard', 'pro'],
      speedModes: ['normal', 'fast', 'ultrafast'],
      maxTokens: 32768
    }
  },
  {
    id: 'gpt-6.1-sol',
    name: 'GPT-6.1 Sol',
    provider: 'openai',
    capabilities: {
      supportsThinking: true,
      supportsToolCall: true,
      supportsStream: true,
      thinkingEfforts: ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
      reasoningModes: ['standard', 'pro'],
      speedModes: ['normal', 'fast', 'ultrafast'],
      maxTokens: 32768
    }
  },
  {
    id: 'gpt-6.1-terra',
    name: 'GPT-6.1 Terra',
    provider: 'openai',
    capabilities: {
      supportsThinking: true,
      supportsToolCall: true,
      supportsStream: true,
      thinkingEfforts: ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
      reasoningModes: ['standard', 'pro'],
      speedModes: ['normal', 'fast', 'ultrafast'],
      maxTokens: 32768
    }
  },
  {
    id: 'gpt-6-luna',
    name: 'GPT-6 Luna',
    provider: 'openai',
    capabilities: {
      supportsThinking: true,
      supportsToolCall: true,
      supportsStream: true,
      thinkingEfforts: ['none', 'low', 'medium', 'high', 'xhigh', 'max'],
      reasoningModes: ['standard', 'pro'],
      speedModes: ['normal', 'fast'],
      maxTokens: 32768
    }
  },
  // Mercury
  {
    id: 'mercury-3',
    name: 'Mercury 3',
    provider: 'mercury',
    capabilities: {
      supportsThinking: true,
      supportsToolCall: true,
      supportsStream: true,
      supportsDiffusion: true,
      thinkingEfforts: ['none', 'low', 'medium', 'high'],
      maxTokens: 8192
    }
  },
  // Gemini
  {
    id: 'gemini-3.8-flash',
    name: 'Gemini 3.8 Flash',
    provider: 'gemini',
    capabilities: {
      supportsThinking: true,
      supportsToolCall: true,
      supportsStream: true,
      thinkingEfforts: ['none', 'low', 'medium', 'high'],
      maxTokens: 8192
    }
  },
  {
    id: 'gemini-4-argon',
    name: 'Gemini 4 Argon',
    provider: 'gemini',
    capabilities: {
      supportsThinking: true,
      supportsToolCall: true,
      supportsStream: true,
      thinkingEfforts: ['none', 'low', 'medium', 'high'],
      maxTokens: 8192
    }
  }
];

// 获取模型信息
export function getModelInfo(providerId: ProviderId, modelId: string): ModelInfo | undefined {
  return BUILTIN_MODELS.find(m => m.provider === providerId && m.id === modelId);
}

// 获取服务商的所有模型
export function getProviderModels(providerId: ProviderId): ModelInfo[] {
  return BUILTIN_MODELS.filter(m => m.provider === providerId);
}

// 服务商显示名称
export const PROVIDER_NAMES: Record<ProviderId, string> = {
  deepseek: 'DeepSeek',
  openai: 'OpenAI GPT',
  mercury: 'Inception Mercury',
  gemini: 'Google Gemini'
};

// 默认Base URL
export const DEFAULT_BASE_URLS: Record<ProviderId, string> = {
  deepseek: 'https://api.deepseek.com',
  openai: 'https://api.openai.com',
  mercury: 'https://api.inceptionlabs.ai',
  gemini: 'https://generativelanguage.googleapis.com'
};
