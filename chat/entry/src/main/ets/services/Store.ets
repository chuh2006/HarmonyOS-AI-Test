import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
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
  createDefaultModelConfig,
  createDefaultSettings,
  generateId,
  setProviderSettings
} from '../types/Types';
import { recordOrNull, stringField } from './Json';

const STORE_NAME: string = 'chat_store';
const SETTINGS_KEY: string = 'app_settings';
const CURRENT_SESSION_KEY: string = 'current_session_id';
const INDEX_FILE: string = 'chat_index.json';
const MESSAGE_FILE_PREFIX: string = 'chat_messages_';
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

// 会话元信息(不含消息)。
// preferences 单个 value 上限是 8192 字符，一次搜索结果就不止这个量，
// 所以历史消息只能落文件：索引存元信息，每个会话的消息单独一个文件。
interface SessionMeta {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  modelConfig: ModelConfig;
}

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

function metaToSession(meta: SessionMeta): Session {
  const session: Session = {
    id: meta.id,
    title: meta.title,
    createdAt: meta.createdAt,
    updatedAt: meta.updatedAt,
    messages: [],
    modelConfig: meta.modelConfig
  };
  return session;
}

function parseSettings(data: string): AppSettings {
  const settings: AppSettings = createDefaultSettings();
  if (data.length === 0) {
    return settings;
  }
  try {
    const parsed: Object = JSON.parse(data) as Object;
    const root: Record<string, Object> | null = recordOrNull(parsed);
    if (root === null) {
      return settings;
    }

    const providers: Record<string, Object> | null = recordOrNull(root['providers']);
    if (providers !== null) {
      settings.providers.deepseek = readProviderSettings(providers, 'deepseek');
      settings.providers.openai = readProviderSettings(providers, 'openai');
      settings.providers.mercury = readProviderSettings(providers, 'mercury');
      settings.providers.gemini = readProviderSettings(providers, 'gemini');
    }

    const defaultProvider: string = stringField(root, 'defaultProvider');
    if (defaultProvider.length > 0) {
      settings.defaultProvider = defaultProvider as ProviderId;
    }
    const defaultModel: string = stringField(root, 'defaultModel');
    if (defaultModel.length > 0) {
      settings.defaultModel = defaultModel;
    }
  } catch (error) {
    return createDefaultSettings();
  }
  return settings;
}

function readProviderSettings(root: Record<string, Object>, key: string): ProviderSettings {
  const record: Record<string, Object> | null = recordOrNull(root[key]);
  if (record === null) {
    const empty: ProviderSettings = { apiKey: '' };
    return empty;
  }
  const baseUrl: string = stringField(record, 'baseUrl');
  const settings: ProviderSettings = {
    apiKey: stringField(record, 'apiKey'),
    baseUrl: baseUrl.length > 0 ? baseUrl : undefined
  };
  return settings;
}

// 会话id只由 generateId 产生，这里再兜底过滤掉不能进文件名的字符
function safeFileName(sessionId: string): string {
  let name: string = '';
  for (let i = 0; i < sessionId.length; i++) {
    const char: string = sessionId.charAt(i);
    const isSafe: boolean = (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z')
      || (char >= '0' && char <= '9') || char === '_' || char === '-';
    name += isSafe ? char : '_';
  }
  return name.length > 0 ? name : 'unknown';
}

export class Store {
  private prefs: preferences.Preferences | null = null;
  private context: common.Context;
  // 所有写操作都是读-改-写，并发写会互相覆盖(丢掉的可能正是工具结果消息，
  // 之后每次请求都会被服务端以 tool_use 缺少 tool_result 拒绝)，所以串行化
  private writeChain: Promise<void> = Promise.resolve();

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

  private serialized<T>(task: () => Promise<T>): Promise<T> {
    const run: Promise<T> = this.writeChain.then((): Promise<T> => task());
    this.writeChain = run.then((): void => {
    }).catch((): void => {
    });
    return run;
  }

  // === 文件读写 ===

  private indexPath(): string {
    return `${this.context.filesDir}/${INDEX_FILE}`;
  }

  private messagesPath(sessionId: string): string {
    return `${this.context.filesDir}/${MESSAGE_FILE_PREFIX}${safeFileName(sessionId)}.json`;
  }

  private readTextFile(path: string): string {
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      return fileIo.readTextSync(path);
    } catch (error) {
      console.error(`读取历史失败: ${toError(error as Object, '未知错误').message}`);
      return '';
    }
  }

  private writeTextFile(path: string, text: string): void {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
    } catch (error) {
      throw toError(error as Object, '保存历史失败');
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (error) {
          // 忽略关闭失败
        }
      }
    }
  }

  private removeFile(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (error) {
      console.error(`删除历史失败: ${toError(error as Object, '未知错误').message}`);
    }
  }

  private readIndex(): SessionMeta[] {
    const text: string = this.readTextFile(this.indexPath());
    if (text.length === 0) {
      return [];
    }
    try {
      const parsed: Object = JSON.parse(text) as Object;
      if (!Array.isArray(parsed)) {
        return [];
      }
      const items: Object[] = parsed as Object[];
      const metas: SessionMeta[] = [];
      for (const item of items) {
        const record: Record<string, Object> | null = recordOrNull(item);
        if (record === null || stringField(record, 'id').length === 0) {
          continue;
        }
        const configValue: Record<string, Object> | null = recordOrNull(record['modelConfig']);
        const meta: SessionMeta = {
          id: stringField(record, 'id'),
          title: stringField(record, 'title'),
          createdAt: 0,
          updatedAt: 0,
          modelConfig: configValue !== null
            ? record['modelConfig'] as ModelConfig
            : createDefaultModelConfig()
        };
        const createdAt: Object | undefined = record['createdAt'];
        const updatedAt: Object | undefined = record['updatedAt'];
        if (createdAt !== undefined && createdAt !== null && typeof createdAt === 'number') {
          meta.createdAt = createdAt as number;
        }
        if (updatedAt !== undefined && updatedAt !== null && typeof updatedAt === 'number') {
          meta.updatedAt = updatedAt as number;
        }
        metas.push(meta);
      }
      return metas;
    } catch (error) {
      console.error(`解析会话索引失败: ${toError(error as Object, '未知错误').message}`);
      return [];
    }
  }

  private writeIndex(metas: SessionMeta[]): void {
    this.writeTextFile(this.indexPath(), JSON.stringify(metas));
  }

  private readMessages(sessionId: string): Message[] {
    const text: string = this.readTextFile(this.messagesPath(sessionId));
    if (text.length === 0) {
      return [];
    }
    try {
      const parsed: Object = JSON.parse(text) as Object;
      if (!Array.isArray(parsed)) {
        return [];
      }
      return parsed as Message[];
    } catch (error) {
      console.error(`解析会话消息失败: ${toError(error as Object, '未知错误').message}`);
      return [];
    }
  }

  // 写消息同时刷新索引里的 updatedAt，避免两次读-改-写
  private saveMessages(sessionId: string, messages: Message[]): void {
    const metas: SessionMeta[] = this.readIndex();
    let found: boolean = false;
    for (const meta of metas) {
      if (meta.id === sessionId) {
        meta.updatedAt = Date.now();
        found = true;
        break;
      }
    }
    if (!found) {
      throw new Error(`会话不存在: ${sessionId}`);
    }
    this.writeIndex(metas);
    this.writeTextFile(this.messagesPath(sessionId), JSON.stringify(messages));
  }

  // === 设置(数据量小，继续用 preferences) ===

  private ensurePrefs(): preferences.Preferences {
    if (this.prefs === null) {
      throw new Error('Store 未初始化，请先调用 init()');
    }
    return this.prefs;
  }

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

  private async writePreference(key: string, value: string): Promise<void> {
    const prefs: preferences.Preferences = this.ensurePrefs();
    try {
      await prefs.put(key, value);
      await prefs.flush();
    } catch (error) {
      throw toError(error as Object, `写入本地存储失败: ${key}`);
    }
  }

  async saveSettings(settings: AppSettings): Promise<void> {
    await this.writePreference(SETTINGS_KEY, JSON.stringify(settings));
  }

  async updateProviderSettings(providerId: ProviderId, settings: ProviderSettings): Promise<void> {
    const appSettings: AppSettings = await this.getSettings();
    setProviderSettings(appSettings.providers, providerId, settings);
    await this.saveSettings(appSettings);
  }

  // === 会话 ===

  // 列表用的轻量数据，不含消息正文；要消息请用 getSession
  async getSessions(): Promise<Session[]> {
    const metas: SessionMeta[] = this.readIndex();
    const sessions: Session[] = [];
    for (const meta of metas) {
      sessions.push(metaToSession(meta));
    }
    sessions.sort((a: Session, b: Session) => b.updatedAt - a.updatedAt);
    return sessions;
  }

  async getSession(sessionId: string): Promise<Session | null> {
    const metas: SessionMeta[] = this.readIndex();
    for (const meta of metas) {
      if (meta.id === sessionId) {
        const session: Session = metaToSession(meta);
        session.messages = this.readMessages(sessionId);
        return session;
      }
    }
    return null;
  }

  async createSession(modelConfig: ModelConfig, title?: string): Promise<Session> {
    return this.serialized(async (): Promise<Session> => {
      const metas: SessionMeta[] = this.readIndex();
      const now: number = Date.now();
      const meta: SessionMeta = {
        id: generateId('session'),
        title: title !== undefined && title.length > 0 ? title : DEFAULT_TITLE,
        createdAt: now,
        updatedAt: now,
        modelConfig: modelConfig
      };
      metas.unshift(meta);
      while (metas.length > MAX_SESSIONS) {
        const removed: SessionMeta | undefined = metas.pop();
        if (removed !== undefined) {
          this.removeFile(this.messagesPath(removed.id));
        }
      }
      this.writeIndex(metas);
      this.writeTextFile(this.messagesPath(meta.id), '[]');
      return metaToSession(meta);
    });
  }

  async updateSession(sessionId: string, patch: SessionPatch): Promise<void> {
    return this.serialized((): Promise<void> => this.patchSession(sessionId, patch));
  }

  // 内部读-改-写，调用方必须已经在 serialized 中
  private async patchSession(sessionId: string, patch: SessionPatch): Promise<void> {
    const metas: SessionMeta[] = this.readIndex();
    let target: SessionMeta | null = null;
    for (const meta of metas) {
      if (meta.id === sessionId) {
        target = meta;
        break;
      }
    }
    if (target === null) {
      throw new Error(`会话不存在: ${sessionId}`);
    }
    if (patch.title !== undefined) {
      target.title = patch.title;
    }
    if (patch.modelConfig !== undefined) {
      target.modelConfig = patch.modelConfig;
    }
    target.updatedAt = Date.now();
    this.writeIndex(metas);

    if (patch.messages !== undefined) {
      this.writeTextFile(this.messagesPath(sessionId), JSON.stringify(patch.messages));
    }
  }

  async deleteSession(sessionId: string): Promise<void> {
    await this.serialized(async (): Promise<void> => {
      const metas: SessionMeta[] = this.readIndex();
      const kept: SessionMeta[] = [];
      for (const meta of metas) {
        if (meta.id !== sessionId) {
          kept.push(meta);
        }
      }
      this.writeIndex(kept);
      this.removeFile(this.messagesPath(sessionId));
    });

    const currentId: string | null = await this.getCurrentSessionId();
    if (currentId === sessionId) {
      await this.clearCurrentSessionId();
    }
  }

  // === 消息 ===

  async addMessage(sessionId: string, message: Message): Promise<void> {
    return this.serialized(async (): Promise<void> => {
      const messages: Message[] = this.readMessages(sessionId);
      messages.push(message);
      this.saveMessages(sessionId, messages);
    });
  }

  async updateMessage(sessionId: string, messageId: string, patch: MessagePatch): Promise<void> {
    return this.serialized(async (): Promise<void> => {
      const messages: Message[] = this.readMessages(sessionId);
      let found: boolean = false;
      const updated: Message[] = [];
      for (const message of messages) {
        if (message.id === messageId) {
          updated.push(applyMessagePatch(message, patch));
          found = true;
        } else {
          updated.push(message);
        }
      }
      if (!found) {
        throw new Error(`消息不存在: ${messageId}`);
      }
      this.saveMessages(sessionId, updated);
    });
  }

  async deleteMessage(sessionId: string, messageId: string): Promise<void> {
    return this.serialized(async (): Promise<void> => {
      const messages: Message[] = this.readMessages(sessionId);
      const kept: Message[] = [];
      for (const message of messages) {
        if (message.id !== messageId) {
          kept.push(message);
        }
      }
      this.saveMessages(sessionId, kept);
    });
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
    await this.writePreference(CURRENT_SESSION_KEY, sessionId);
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
    await this.serialized(async (): Promise<void> => {
      const metas: SessionMeta[] = this.readIndex();
      let target: SessionMeta | null = null;
      for (const meta of metas) {
        if (meta.id === sessionId) {
          target = meta;
          break;
        }
      }
      if (target === null || (target.title.length > 0 && target.title !== DEFAULT_TITLE)) {
        return;
      }
      for (const message of this.readMessages(sessionId)) {
        if (message.role === 'user' && message.content.trim().length > 0) {
          const text: string = message.content.trim();
          target.title = text.length > 20 ? `${text.substring(0, 20)}...` : text;
          this.writeIndex(metas);
          return;
        }
      }
    });
  }

  async cleanupOldSessions(keepCount: number = MAX_SESSIONS): Promise<void> {
    return this.serialized(async (): Promise<void> => {
      const metas: SessionMeta[] = this.readIndex();
      if (metas.length <= keepCount) {
        return;
      }
      const sorted: SessionMeta[] = metas.slice();
      sorted.sort((a: SessionMeta, b: SessionMeta) => b.updatedAt - a.updatedAt);
      const kept: SessionMeta[] = sorted.slice(0, keepCount);
      for (let i = keepCount; i < sorted.length; i++) {
        this.removeFile(this.messagesPath(sorted[i].id));
      }
      this.writeIndex(kept);
    });
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
