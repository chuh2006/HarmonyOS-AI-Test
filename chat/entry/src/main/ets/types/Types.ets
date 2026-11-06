// 服务商标识
export type ProviderId = 'deepseek' | 'openai' | 'mercury' | 'gemini';

// 消息角色
export type MessageRole = 'user' | 'assistant' | 'system' | 'tool';

// 消息状态
export type MessageStatus =
  | 'idle'
  | 'thinking'
  | 'tool_call'
  | 'streaming'
  | 'complete'
  | 'stopped'
  | 'error';

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
  supportsThinking: boolean;
  supportsToolCall: boolean;
  supportsStream: boolean;
  supportsDiffusion?: boolean; // Mercury默认功能
  thinkingEfforts?: ThinkingEffort[];
  reasoningModes?: OpenAIReasoningMode[];
  speedModes?: OpenAISpeedMode[];
  maxTokens?: number;
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

// Gemini函数调用Part
export interface GeminiFunctionCallPart {
  name: string;
  args: string; // JSON字符串，避免any
}

// Gemini函数响应Part
export interface GeminiFunctionResponsePart {
  name: string;
  response: string; // JSON字符串，避免any
}

// 消息内容部分(用于Gemini的Parts结构)
export interface ContentPart {
  type: 'text' | 'thinking' | 'tool_call' | 'tool_result';
  text?: string;
  functionCall?: GeminiFunctionCallPart;
  functionResponse?: GeminiFunctionResponsePart;
  thoughtSignature?: string;
  thought?: boolean;
}

// Gemini思考签名条目(数组形式，可JSON序列化)
export interface ThoughtSignatureEntry {
  index: number;
  signature: string;
}

// OpenAI协议数据
export interface OpenAIProtocolData {
  responseId?: string;
  encryptedContent?: string;
}

// Gemini协议数据
export interface GeminiProtocolData {
  parts?: ContentPart[];
  thoughtSignatures?: ThoughtSignatureEntry[];
}

// DeepSeek协议数据
export interface DeepSeekProtocolData {
  thinkingContent?: string;
}

// Mercury协议数据
export interface MercuryProtocolData {
  messageId?: string;
}

// 协议特定数据(用于继续对话)
export interface ProtocolData {
  openai?: OpenAIProtocolData;
  gemini?: GeminiProtocolData;
  deepseek?: DeepSeekProtocolData;
  mercury?: MercuryProtocolData;
}

// 消息
export interface Message {
  id: string;
  role: MessageRole;
  content: string;
  thinking?: string;
  status: MessageStatus;
  toolCalls?: ToolCall[];
  timestamp: number;
  error?: string;
  protocolData?: ProtocolData;
}

// 会话
export interface Session {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  messages: Message[];
  modelConfig: ModelConfig;
}

// Provider设置
export interface ProviderSettings {
  apiKey: string;
  baseUrl?: string;
}

// 全局设置
export interface AppSettings {
  providers: ProviderSettingsMap;
  defaultProvider?: ProviderId;
  defaultModel?: string;
}

// Provider设置映射(用显式字段替代Record，避免对象字面量类型问题)
export interface ProviderSettingsMap {
  deepseek: ProviderSettings;
  openai: ProviderSettings;
  mercury: ProviderSettings;
  gemini: ProviderSettings;
}

// Token使用量
export interface TokenUsage {
  inputTokens?: number;
  outputTokens?: number;
}

// 流式事件类型
export type StreamEventType =
  | 'thinking_delta'
  | 'content_delta'
  | 'content_replace'
  | 'tool_call_start'
  | 'tool_call_delta'
  | 'tool_call_end'
  | 'complete'
  | 'error'
  | 'usage';

// DeepSeek协议中间数据
export interface DeepSeekStreamProtocolData {
  thinkingContent?: string;
}

// OpenAI协议中间数据
export interface OpenAIStreamProtocolData {
  responseId?: string;
  encryptedContent?: string;
}

// Gemini协议中间数据
export interface GeminiStreamProtocolData {
  parts?: ContentPart[];
  thoughtSignatures?: ThoughtSignatureEntry[];
  thoughtSignature?: string;
}

// 流式事件协议数据联合
export interface StreamProtocolData {
  deepseek?: DeepSeekStreamProtocolData;
  openai?: OpenAIStreamProtocolData;
  gemini?: GeminiStreamProtocolData;
}

// 流式事件
export interface StreamEvent {
  type: StreamEventType;
  data?: string;
  toolCall?: ToolCall;
  error?: string;
  usage?: TokenUsage;
  protocolData?: StreamProtocolData;
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
    return new ChatError('API Key 无效，请在设置中检查', 'INVALID_API_KEY', provider);
  }

  static rateLimited(provider: ProviderId): ChatError {
    return new ChatError('请求过于频繁，请稍后再试', 'RATE_LIMITED', provider);
  }

  static networkError(detail?: string): ChatError {
    return new ChatError(detail && detail.length > 0 ? `网络错误: ${detail}` : '网络连接失败', 'NETWORK_ERROR');
  }

  static timeout(): ChatError {
    return new ChatError('请求超时', 'TIMEOUT');
  }

  static parseError(detail?: string): ChatError {
    return new ChatError(detail && detail.length > 0 ? `响应解析失败: ${detail}` : '响应解析失败', 'PARSE_ERROR');
  }

  static stopped(): ChatError {
    return new ChatError('已停止生成', 'STOPPED');
  }

  static httpError(statusCode: number, detail: string, provider?: ProviderId): ChatError {
    if (statusCode === 401 || statusCode === 403) {
      return ChatError.invalidApiKey(provider || 'deepseek');
    }
    if (statusCode === 429) {
      return ChatError.rateLimited(provider || 'deepseek');
    }
    return new ChatError(`HTTP ${statusCode}: ${detail}`, 'HTTP_ERROR', provider);
  }
}

// 内置模型列表
export function getBuiltinModels(): ModelInfo[] {
  const models: ModelInfo[] = [];

  // DeepSeek
  const dsCap: ModelCapabilities = {
    supportsThinking: true,
    supportsToolCall: true,
    supportsStream: true,
    thinkingEfforts: ['none', 'low', 'high', 'max'],
    maxTokens: 128000
  };
  const dsFlash: ModelInfo = {
    id: 'deepseek-chat',
    name: 'DeepSeek Chat',
    provider: 'deepseek',
    capabilities: dsCap
  };
  models.push(dsFlash);
  const dsReasonerCap: ModelCapabilities = {
    supportsThinking: true,
    supportsToolCall: true,
    supportsStream: true,
    thinkingEfforts: ['none', 'low', 'high', 'max'],
    maxTokens: 128000
  };
  const dsReasoner: ModelInfo = {
    id: 'deepseek-reasoner',
    name: 'DeepSeek Reasoner',
    provider: 'deepseek',
    capabilities: dsReasonerCap
  };
  models.push(dsReasoner);

  // OpenAI
  const gptCap: ModelCapabilities = {
    supportsThinking: true,
    supportsToolCall: true,
    supportsStream: true,
    thinkingEfforts: ['none', 'low', 'medium', 'high', 'max'],
    reasoningModes: ['standard', 'pro'],
    speedModes: ['normal', 'fast', 'ultrafast'],
    maxTokens: 128000
  };
  const gpt1: ModelInfo = { id: 'gpt-5', name: 'GPT-5', provider: 'openai', capabilities: gptCap };
  models.push(gpt1);
  const gpt2: ModelInfo = { id: 'gpt-5-mini', name: 'GPT-5 Mini', provider: 'openai', capabilities: gptCap };
  models.push(gpt2);

  // Mercury
  const mercuryCap: ModelCapabilities = {
    supportsThinking: true,
    supportsToolCall: true,
    supportsStream: true,
    supportsDiffusion: true,
    thinkingEfforts: ['none', 'low', 'medium', 'high'],
    maxTokens: 65536
  };
  const mercury: ModelInfo = {
    id: 'mercury-coder',
    name: 'Mercury Coder',
    provider: 'mercury',
    capabilities: mercuryCap
  };
  models.push(mercury);

  // Gemini
  const geminiCap: ModelCapabilities = {
    supportsThinking: true,
    supportsToolCall: true,
    supportsStream: true,
    thinkingEfforts: ['none', 'low', 'medium', 'high'],
    maxTokens: 65536
  };
  const gemini1: ModelInfo = {
    id: 'gemini-2.5-flash',
    name: 'Gemini 2.5 Flash',
    provider: 'gemini',
    capabilities: geminiCap
  };
  models.push(gemini1);
  const gemini2: ModelInfo = {
    id: 'gemini-2.5-pro',
    name: 'Gemini 2.5 Pro',
    provider: 'gemini',
    capabilities: geminiCap
  };
  models.push(gemini2);

  return models;
}

// 获取模型信息
export function getModelInfo(providerId: ProviderId, modelId: string): ModelInfo | undefined {
  const models = getBuiltinModels();
  for (const m of models) {
    if (m.provider === providerId && m.id === modelId) {
      return m;
    }
  }
  return undefined;
}

// 获取服务商的所有模型
export function getProviderModels(providerId: ProviderId): ModelInfo[] {
  const models = getBuiltinModels();
  const result: ModelInfo[] = [];
  for (const m of models) {
    if (m.provider === providerId) {
      result.push(m);
    }
  }
  return result;
}

// 服务商显示名称
export function getProviderName(id: ProviderId): string {
  if (id === 'deepseek') {
    return 'DeepSeek';
  }
  if (id === 'openai') {
    return 'OpenAI GPT';
  }
  if (id === 'mercury') {
    return 'Inception Mercury';
  }
  return 'Google Gemini';
}

// 默认Base URL
export function getDefaultBaseUrl(id: ProviderId): string {
  if (id === 'deepseek') {
    return 'https://api.deepseek.com';
  }
  if (id === 'openai') {
    return 'https://api.openai.com';
  }
  if (id === 'mercury') {
    return 'https://api.inceptionlabs.ai';
  }
  return 'https://generativelanguage.googleapis.com';
}

// 创建默认设置
export function createDefaultSettings(): AppSettings {
  const ds: ProviderSettings = { apiKey: '' };
  const oa: ProviderSettings = { apiKey: '' };
  const me: ProviderSettings = { apiKey: '' };
  const ge: ProviderSettings = { apiKey: '' };
  const providers: ProviderSettingsMap = {
    deepseek: ds,
    openai: oa,
    mercury: me,
    gemini: ge
  };
  const settings: AppSettings = { providers: providers };
  return settings;
}

// 创建默认模型配置
export function createDefaultModelConfig(): ModelConfig {
  const config: ModelConfig = {
    providerId: 'deepseek',
    modelId: 'deepseek-chat',
    thinkingEnabled: false,
    thinkingEffort: 'none',
    diffusionEnabled: true
  };
  return config;
}

// 生成唯一ID
export function generateId(prefix: string): string {
  return `${prefix}_${Date.now()}_${Math.floor(Math.random() * 1000000)}`;
}
