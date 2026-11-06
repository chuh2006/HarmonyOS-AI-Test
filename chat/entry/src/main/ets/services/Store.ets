import dataPreferences from '@ohos.data.preferences';
import { common } from '@kit.AbilityKit';
import {
  Session,
  Message,
  AppSettings,
  ModelConfig,
  ProviderSettings,
  ProviderId
} from '../types/Types';

// 存储键
const STORAGE_KEYS = {
  SETTINGS: 'app_settings',
  SESSIONS: 'chat_sessions',
  CURRENT_SESSION: 'current_session_id'
};

export class Store {
  private preferences: dataPreferences.Preferences | null = null;
  private context: common.UIAbilityContext;
  
  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }
  
  // 初始化存储
  async init(): Promise<void> {
    try {
      this.preferences = await dataPreferences.getPreferences(this.context, 'chat_store');
    } catch (error) {
      console.error('Failed to init preferences:', error);
      throw error;
    }
  }
  
  // 确保已初始化
  private ensureInit(): void {
    if (!this.preferences) {
      throw new Error('Store not initialized. Call init() first.');
    }
  }
  
  // === 设置相关 ===
  
  // 获取应用设置
  async getSettings(): Promise<AppSettings> {
    this.ensureInit();
    
    try {
      const data = await this.preferences!.get(STORAGE_KEYS.SETTINGS, '{}') as string;
      const settings = JSON.parse(data) as AppSettings;
      
      // 确保所有provider都有设置
      if (!settings.providers) {
        settings.providers = {} as Record<ProviderId, ProviderSettings>;
      }
      
      const providers: ProviderId[] = ['deepseek', 'openai', 'mercury', 'gemini'];
      for (const provider of providers) {
        if (!settings.providers[provider]) {
          settings.providers[provider] = { apiKey: '' };
        }
      }
      
      return settings;
      
    } catch (error) {
      console.error('Failed to get settings:', error);
      return {
        providers: {
          deepseek: { apiKey: '' },
          openai: { apiKey: '' },
          mercury: { apiKey: '' },
          gemini: { apiKey: '' }
        }
      };
    }
  }
  
  // 保存应用设置
  async saveSettings(settings: AppSettings): Promise<void> {
    this.ensureInit();
    
    try {
      await this.preferences!.put(STORAGE_KEYS.SETTINGS, JSON.stringify(settings));
      await this.preferences!.flush();
    } catch (error) {
      console.error('Failed to save settings:', error);
      throw error;
    }
  }
  
  // 更新单个Provider设置
  async updateProviderSettings(providerId: ProviderId, settings: ProviderSettings): Promise<void> {
    const appSettings = await this.getSettings();
    appSettings.providers[providerId] = settings;
    await this.saveSettings(appSettings);
  }
  
  // === 会话相关 ===
  
  // 获取所有会话
  async getSessions(): Promise<Session[]> {
    this.ensureInit();
    
    try {
      const data = await this.preferences!.get(STORAGE_KEYS.SESSIONS, '[]') as string;
      const sessions = JSON.parse(data) as Session[];
      
      // 按更新时间排序
      return sessions.sort((a, b) => b.updatedAt - a.updatedAt);
      
    } catch (error) {
      console.error('Failed to get sessions:', error);
      return [];
    }
  }
  
  // 保存所有会话
  private async saveSessions(sessions: Session[]): Promise<void> {
    this.ensureInit();
    
    try {
      await this.preferences!.put(STORAGE_KEYS.SESSIONS, JSON.stringify(sessions));
      await this.preferences!.flush();
    } catch (error) {
      console.error('Failed to save sessions:', error);
      throw error;
    }
  }
  
  // 获取单个会话
  async getSession(sessionId: string): Promise<Session | null> {
    const sessions = await this.getSessions();
    return sessions.find(s => s.id === sessionId) || null;
  }
  
  // 创建新会话
  async createSession(modelConfig: ModelConfig, title?: string): Promise<Session> {
    const sessions = await this.getSessions();
    
    const newSession: Session = {
      id: `session_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
      title: title || '新对话',
      createdAt: Date.now(),
      updatedAt: Date.now(),
      messages: [],
      modelConfig
    };
    
    sessions.unshift(newSession);
    await this.saveSessions(sessions);
    
    return newSession;
  }
  
  // 更新会话
  async updateSession(sessionId: string, updates: Partial<Session>): Promise<void> {
    const sessions = await this.getSessions();
    const index = sessions.findIndex(s => s.id === sessionId);
    
    if (index === -1) {
      throw new Error(`Session not found: ${sessionId}`);
    }
    
    sessions[index] = {
      ...sessions[index],
      ...updates,
      updatedAt: Date.now()
    };
    
    await this.saveSessions(sessions);
  }
  
  // 删除会话
  async deleteSession(sessionId: string): Promise<void> {
    const sessions = await this.getSessions();
    const filtered = sessions.filter(s => s.id !== sessionId);
    
    await this.saveSessions(filtered);
    
    // 如果删除的是当前会话，清除当前会话ID
    const currentId = await this.getCurrentSessionId();
    if (currentId === sessionId) {
      await this.clearCurrentSessionId();
    }
  }
  
  // === 消息相关 ===
  
  // 添加消息到会话
  async addMessage(sessionId: string, message: Message): Promise<void> {
    const session = await this.getSession(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }
    
    session.messages.push(message);
    await this.updateSession(sessionId, { messages: session.messages });
  }
  
  // 更新消息
  async updateMessage(sessionId: string, messageId: string, updates: Partial<Message>): Promise<void> {
    const session = await this.getSession(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }
    
    const index = session.messages.findIndex(m => m.id === messageId);
    if (index === -1) {
      throw new Error(`Message not found: ${messageId}`);
    }
    
    session.messages[index] = {
      ...session.messages[index],
      ...updates
    };
    
    await this.updateSession(sessionId, { messages: session.messages });
  }
  
  // 删除消息
  async deleteMessage(sessionId: string, messageId: string): Promise<void> {
    const session = await this.getSession(sessionId);
    if (!session) {
      throw new Error(`Session not found: ${sessionId}`);
    }
    
    const filtered = session.messages.filter(m => m.id !== messageId);
    await this.updateSession(sessionId, { messages: filtered });
  }
  
  // === 当前会话 ===
  
  // 获取当前会话ID
  async getCurrentSessionId(): Promise<string | null> {
    this.ensureInit();
    
    try {
      const id = await this.preferences!.get(STORAGE_KEYS.CURRENT_SESSION, '') as string;
      return id || null;
    } catch (error) {
      console.error('Failed to get current session id:', error);
      return null;
    }
  }
  
  // 设置当前会话ID
  async setCurrentSessionId(sessionId: string): Promise<void> {
    this.ensureInit();
    
    try {
      await this.preferences!.put(STORAGE_KEYS.CURRENT_SESSION, sessionId);
      await this.preferences!.flush();
    } catch (error) {
      console.error('Failed to set current session id:', error);
      throw error;
    }
  }
  
  // 清除当前会话ID
  async clearCurrentSessionId(): Promise<void> {
    this.ensureInit();
    
    try {
      await this.preferences!.delete(STORAGE_KEYS.CURRENT_SESSION);
      await this.preferences!.flush();
    } catch (error) {
      console.error('Failed to clear current session id:', error);
    }
  }
  
  // === 辅助方法 ===
  
  // 自动生成会话标题(基于第一条用户消息)
  async generateSessionTitle(sessionId: string): Promise<void> {
    const session = await this.getSession(sessionId);
    if (!session) return;
    
    // 如果已经有标题且不是默认标题，不修改
    if (session.title && session.title !== '新对话') {
      return;
    }
    
    // 查找第一条用户消息
    const firstUserMessage = session.messages.find(m => m.role === 'user');
    if (!firstUserMessage || !firstUserMessage.content) {
      return;
    }
    
    // 使用消息的前20个字符作为标题
    let title = firstUserMessage.content.trim();
    if (title.length > 20) {
      title = title.substring(0, 20) + '...';
    }
    
    await this.updateSession(sessionId, { title });
  }
  
  // 清理旧会话(保留最近N个)
  async cleanupOldSessions(keepCount: number = 50): Promise<void> {
    const sessions = await this.getSessions();
    
    if (sessions.length > keepCount) {
      const toKeep = sessions.slice(0, keepCount);
      await this.saveSessions(toKeep);
    }
  }
}

// 全局Store实例(需要在应用启动时初始化)
let globalStore: Store | null = null;

export function initGlobalStore(context: common.UIAbilityContext): Promise<void> {
  globalStore = new Store(context);
  return globalStore.init();
}

export function getStore(): Store {
  if (!globalStore) {
    throw new Error('Store not initialized. Call initGlobalStore() first.');
  }
  return globalStore;
}
