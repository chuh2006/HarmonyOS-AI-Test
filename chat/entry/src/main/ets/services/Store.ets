import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import {
  AppSettings,
  Message,
  MessageStatus,
  ModelConfig,
  ProtocolData,
  ProviderId,
  ProviderSettings,
  Session,
  ToolCall,
  createDefaultSettings,
  generateId,
  setProviderSettings
} from '../types/Types';

const STORE_NAME: string = 'chat_store';
const SETTINGS_KEY: string = 'app_settings';
const SESSIONS_KEY: string = 'chat_sessions';
const CURRENT_SESSION_KEY: string = 'current_session_id';
const MAX_SESSIONS: number = 50;
const DEFAULT_TITLE: string = '新对话';

// 消息增量更新字段
export interface MessagePatch {
  content?: string;
  thinking?: string;
  status?: MessageStatus;
  toolCalls?: ToolCall[];
  error?: string;
  protocolData?: ProtocolData;
}

// 会话增量更新字段
export interface SessionPatch {
  title?: string;
  messages?: Message[];
  modelConfig?: ModelConfig;
}

// ProviderSettingsMap 的读写helper在 Types 中，这里直接复用
function toError(value: Object | Error, fallback: string): Error {
  if (value instanceof Error) {
    return value;
  }
  return new Error(fallback);
}

function cloneMessage(message: Message): Message {
  const copy: Message = {
    id: message.id,
    role: message.role,
    content: message.content,
    thinking: message.thinking,
    status: message.status,
    toolCalls: message.toolCalls,
    timestamp: message.timestamp,
    error: message.error,
    protocolData: message.protocolData
  };
  return copy;
}

export function applyMessagePatch(message: Message, patch: MessagePatch): Message {
  const copy: Message = cloneMessage(message);
  if (patch.content !== undefined) {
    copy.content = patch.content;
  }
  if (patch.thinking !== undefined) {
    copy.thinking = patch.thinking;
  }
  if (patch.status !== undefined) {
    copy.status = patch.status;
  }
  if (patch.toolCalls !== undefined) {
    copy.toolCalls = patch.toolCalls;
  }
  if (patch.error !== undefined) {
    copy.error = patch.error;
  }
  if (patch.protocolData !== undefined) {
    copy.protocolData = patch.protocolData;
  }
  return copy;
}

function cloneSession(session: Session): Session {
  const copy: Session = {
    id: session.id,
    title: session.title,
    createdAt: session.createdAt,
    updatedAt: session.updatedAt,
    messages: session.messages,
    modelConfig: session.modelConfig
  };
  return copy;
}

function applySessionPatch(session: Session, patch: SessionPatch): Session {
  const copy: Session = cloneSession(session);
  if (patch.title !== undefined) {
    copy.title = patch.title;
  }
  if (patch.messages !== undefined) {
    copy.messages = patch.messages;
  }
  if (patch.modelConfig !== undefined) {
    copy.modelConfig = patch.modelConfig;
  }
  copy.updatedAt = Date.now();
  return copy;
}

function readProviderSettings(root: Record<string, Object>, key: string): ProviderSettings {
  const empty: ProviderSettings = { apiKey: '' };
  const value: Object | undefined = root[key];
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return empty;
  }
  const record: Record<string, Object> = value as Record<string, Object>;
  const keyValue: Object | undefined = record['apiKey'];
  const baseUrlValue: Object | undefined = record['baseUrl'];
  const settings: ProviderSettings = {
    apiKey: keyValue !== undefined && typeof keyValue === 'string' ? keyValue as string : '',
    baseUrl: baseUrlValue !== undefined && typeof baseUrlValue === 'string' ? baseUrlValue as string : undefined
  };
  return settings;
}

// 读出的 JSON 可能缺字段，逐字段补齐后再返回
function parseSettings(data: string): AppSettings {
  const settings: AppSettings = createDefaultSettings();
  if (data.length === 0) {
    return settings;
  }
  try {
    const parsed: Object = JSON.parse(data) as Object;
    const root: Record<string, Object> = parsed as Record<string, Object>;

    const providersValue: Object | undefined = root['providers'];
    if (providersValue !== undefined && providersValue !== null && typeof providersValue === 'object'
      && !Array.isArray(providersValue)) {
      const providers: Record<string, Object> = providersValue as Record<string, Object>;
      settings.providers.deepseek = readProviderSettings(providers, 'deepseek');
      settings.providers.openai = readProviderSettings(providers, 'openai');
      settings.providers.mercury = readProviderSettings(providers, 'mercury');
      settings.providers.gemini = readProviderSettings(providers, 'gemini');
    }

    const defaultProvider: Object | undefined = root['defaultProvider'];
    if (defaultProvider !== undefined && typeof defaultProvider === 'string') {
      settings.defaultProvider = defaultProvider as ProviderId;
    }
    const defaultModel: Object | undefined = root['defaultModel'];
    if (defaultModel !== undefined && typeof defaultModel === 'string') {
      settings.defaultModel = defaultModel as string;
    }
  } catch (error) {
    return createDefaultSettings();
  }
  return settings;
}

export class Store {
  private prefs: preferences.Preferences | null = null;
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  async init(): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(this.context, STORE_NAME);
    } catch (error) {
      throw toError(error as Object, '初始化本地存储失败');
    }
  }

  private ensurePrefs(): preferences.Preferences {
    if (this.prefs === null) {
      throw new Error('Store 未初始化，请先调用 init()');
    }
    return this.prefs;
  }

  // === 设置 ===

  async getSettings(): Promise<AppSettings> {
    const prefs: preferences.Preferences = this.ensurePrefs();
    try {
      const data: string = await prefs.get(SETTINGS_KEY, '') as string;
      return parseSettings(data);
    } catch (error) {
      console.error(`读取设置失败: ${toError(error as Object, '未知错误').message}`);
      return createDefaultSettings();
    }
  }

  private async writeValue(key: string, value: string): Promise<void> {
    const prefs: preferences.Preferences = this.ensurePrefs();
    try {
      await prefs.put(key, value);
      await prefs.flush();
    } catch (error) {
      throw toError(error as Object, `写入本地存储失败: ${key}`);
    }
  }

  async saveSettings(settings: AppSettings): Promise<void> {
    await this.writeValue(SETTINGS_KEY, JSON.stringify(settings));
  }

  async updateProviderSettings(providerId: ProviderId, settings: ProviderSettings): Promise<void> {
    const appSettings: AppSettings = await this.getSettings();
    setProviderSettings(appSettings.providers, providerId, settings);
    await this.saveSettings(appSettings);
  }

  // === 会话 ===

  async getSessions(): Promise<Session[]> {
    const prefs: preferences.Preferences = this.ensurePrefs();
    try {
      const data: string = await prefs.get(SESSIONS_KEY, '[]') as string;
      const sessions: Session[] = JSON.parse(data) as Session[];
      sessions.sort((a: Session, b: Session) => b.updatedAt - a.updatedAt);
      return sessions;
    } catch (error) {
      console.error(`读取会话失败: ${toError(error as Object, '未知错误').message}`);
      return [];
    }
  }

  private async saveSessions(sessions: Session[]): Promise<void> {
    await this.writeValue(SESSIONS_KEY, JSON.stringify(sessions));
  }

  async getSession(sessionId: string): Promise<Session | null> {
    const sessions: Session[] = await this.getSessions();
    for (const session of sessions) {
      if (session.id === sessionId) {
        return session;
      }
    }
    return null;
  }

  async createSession(modelConfig: ModelConfig, title?: string): Promise<Session> {
    const sessions: Session[] = await this.getSessions();
    const now: number = Date.now();
    const session: Session = {
      id: generateId('session'),
      title: title !== undefined && title.length > 0 ? title : DEFAULT_TITLE,
      createdAt: now,
      updatedAt: now,
      messages: [],
      modelConfig: modelConfig
    };
    sessions.unshift(session);
    await this.saveSessions(sessions);
    return session;
  }

  async updateSession(sessionId: string, patch: SessionPatch): Promise<void> {
    const sessions: Session[] = await this.getSessions();
    for (let i = 0; i < sessions.length; i++) {
      if (sessions[i].id === sessionId) {
        sessions[i] = applySessionPatch(sessions[i], patch);
        await this.saveSessions(sessions);
        return;
      }
    }
    throw new Error(`会话不存在: ${sessionId}`);
  }

  async deleteSession(sessionId: string): Promise<void> {
    const sessions: Session[] = await this.getSessions();
    const kept: Session[] = [];
    for (const session of sessions) {
      if (session.id !== sessionId) {
        kept.push(session);
      }
    }
    await this.saveSessions(kept);

    const currentId: string | null = await this.getCurrentSessionId();
    if (currentId === sessionId) {
      await this.clearCurrentSessionId();
    }
  }

  // === 消息 ===

  async addMessage(sessionId: string, message: Message): Promise<void> {
    const session: Session | null = await this.getSession(sessionId);
    if (session === null) {
      throw new Error(`会话不存在: ${sessionId}`);
    }
    const messages: Message[] = [];
    for (const m of session.messages) {
      messages.push(m);
    }
    messages.push(message);
    await this.updateSession(sessionId, { messages: messages });
  }

  async updateMessage(sessionId: string, messageId: string, patch: MessagePatch): Promise<void> {
    const session: Session | null = await this.getSession(sessionId);
    if (session === null) {
      throw new Error(`会话不存在: ${sessionId}`);
    }
    let found: boolean = false;
    const messages: Message[] = [];
    for (const message of session.messages) {
      if (message.id === messageId) {
        messages.push(applyMessagePatch(message, patch));
        found = true;
      } else {
        messages.push(message);
      }
    }
    if (!found) {
      throw new Error(`消息不存在: ${messageId}`);
    }
    await this.updateSession(sessionId, { messages: messages });
  }

  async deleteMessage(sessionId: string, messageId: string): Promise<void> {
    const session: Session | null = await this.getSession(sessionId);
    if (session === null) {
      throw new Error(`会话不存在: ${sessionId}`);
    }
    const messages: Message[] = [];
    for (const message of session.messages) {
      if (message.id !== messageId) {
        messages.push(message);
      }
    }
    await this.updateSession(sessionId, { messages: messages });
  }

  // === 当前会话 ===

  async getCurrentSessionId(): Promise<string | null> {
    const prefs: preferences.Preferences = this.ensurePrefs();
    try {
      const id: string = await prefs.get(CURRENT_SESSION_KEY, '') as string;
      return id.length > 0 ? id : null;
    } catch (error) {
      console.error(`读取当前会话失败: ${toError(error as Object, '未知错误').message}`);
      return null;
    }
  }

  async setCurrentSessionId(sessionId: string): Promise<void> {
    await this.writeValue(CURRENT_SESSION_KEY, sessionId);
  }

  async clearCurrentSessionId(): Promise<void> {
    const prefs: preferences.Preferences = this.ensurePrefs();
    try {
      await prefs.delete(CURRENT_SESSION_KEY);
      await prefs.flush();
    } catch (error) {
      console.error(`清除当前会话失败: ${toError(error as Object, '未知错误').message}`);
    }
  }

  // === 辅助 ===

  // 用第一条用户消息作为会话标题
  async generateSessionTitle(sessionId: string): Promise<void> {
    const session: Session | null = await this.getSession(sessionId);
    if (session === null) {
      return;
    }
    if (session.title.length > 0 && session.title !== DEFAULT_TITLE) {
      return;
    }
    for (const message of session.messages) {
      if (message.role === 'user' && message.content.trim().length > 0) {
        const text: string = message.content.trim();
        const title: string = text.length > 20 ? `${text.substring(0, 20)}...` : text;
        await this.updateSession(sessionId, { title: title });
        return;
      }
    }
  }

  async cleanupOldSessions(keepCount: number = MAX_SESSIONS): Promise<void> {
    const sessions: Session[] = await this.getSessions();
    if (sessions.length > keepCount) {
      await this.saveSessions(sessions.slice(0, keepCount));
    }
  }
}

let globalStore: Store | null = null;

export function initGlobalStore(context: common.Context): Promise<void> {
  globalStore = new Store(context);
  return globalStore.init();
}

export function getStore(): Store {
  if (globalStore === null) {
    throw new Error('Store 未初始化，请先调用 initGlobalStore()');
  }
  return globalStore;
}
