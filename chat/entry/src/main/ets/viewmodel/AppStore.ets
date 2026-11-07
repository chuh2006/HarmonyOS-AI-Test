import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Conversation, ChatMessage, MessageBlock, BlockKind, Role, MsgStatus, ProviderId } from '../model/Types';
import { modelInfo, defaultModelOf } from '../model/Catalog';
import { SettingsStore } from '../data/SettingsStore';
import { ConversationFiles } from '../data/ConversationFiles';
import { ChatEngine, EngineHost } from '../engine/ChatEngine';

@ObservedV2
export class AppStore {
  private static instance: AppStore | null = null;
  @Trace ready: boolean = false;
  @Trace conversations: Conversation[] = [];
  @Trace currentId: string = '';
  @Trace generating: boolean = false;
  @Trace scrollTick: number = 0;
  settings: SettingsStore = SettingsStore.getInstance();
  private files: ConversationFiles = new ConversationFiles();
  private engine: ChatEngine = new ChatEngine();
  private context: common.UIAbilityContext | null = null;

  static getInstance(): AppStore {
    if (AppStore.instance === null) {
      AppStore.instance = new AppStore();
    }
    return AppStore.instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.ready) {
      return;
    }
    this.context = context;
    await this.settings.init(context);
    this.files.init(context);
    const loaded = this.files.loadAll();
    for (const c of loaded) {
      this.conversations.push(c);
    }
    const savedId = this.settings.getCurrentConversationId();
    let found = false;
    for (const c of this.conversations) {
      if (c.id === savedId) {
        found = true;
        break;
      }
    }
    if (found) {
      this.currentId = savedId;
    } else if (this.conversations.length > 0) {
      this.currentId = this.conversations[0].id;
    } else {
      this.createConversation(this.settings.getLastProvider(), this.settings.getLastModel());
    }
    this.ready = true;
  }

  current(): Conversation | null {
    for (const c of this.conversations) {
      if (c.id === this.currentId) {
        return c;
      }
    }
    return null;
  }

  createConversation(provider: ProviderId, model: string): Conversation {
    const conv = new Conversation(util.generateRandomUUID(), provider, model);
    this.conversations.unshift(conv);
    this.currentId = conv.id;
    this.files.save(conv);
    this.settings.setCurrentConversationId(conv.id);
    this.settings.setLast(provider, model);
    return conv;
  }

  newChat(): void {
    if (this.generating) {
      this.stopGeneration();
    }
    const cur = this.current();
    if (cur !== null && cur.messages.length === 0) {
      return;
    }
    this.createConversation(this.settings.getLastProvider(), this.settings.getLastModel());
    this.scrollTick++;
  }

  switchTo(id: string): void {
    if (id === this.currentId) {
      return;
    }
    if (this.generating) {
      this.stopGeneration();
    }
    this.currentId = id;
    this.settings.setCurrentConversationId(id);
    this.scrollTick++;
  }

  deleteConversation(id: string): void {
    if (this.generating && this.currentId === id) {
      this.stopGeneration();
    }
    let idx = -1;
    for (let i = 0; i < this.conversations.length; i++) {
      if (this.conversations[i].id === id) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      return;
    }
    this.conversations.splice(idx, 1);
    this.files.delete(id);
    if (this.currentId === id) {
      if (this.conversations.length > 0) {
        this.currentId = this.conversations[0].id;
        this.settings.setCurrentConversationId(this.currentId);
      } else {
        this.createConversation(this.settings.getLastProvider(), this.settings.getLastModel());
      }
    }
    this.scrollTick++;
  }

  setModel(provider: ProviderId, model: string): void {
    const cur = this.current();
    if (cur !== null && cur.messages.length === 0) {
      cur.provider = provider;
      cur.model = model;
      this.clampOptions(cur);
      this.files.save(cur);
    } else if (cur === null || cur.provider !== provider || cur.model !== model) {
      if (this.generating) {
        this.stopGeneration();
      }
      this.createConversation(provider, model);
    }
    this.settings.setLast(provider, model);
    this.scrollTick++;
  }

  private clampOptions(conv: Conversation): void {
    const info = modelInfo(conv.model);
    if (!info.canDisableThinking && conv.options.oaiEffort === 'none') {
      conv.options.oaiEffort = 'medium';
    }
    if (!info.supportsUltrafast && conv.options.oaiTier === 'ultrafast') {
      conv.options.oaiTier = 'standard';
    }
    if (!info.supportsFast && conv.options.oaiTier === 'fast') {
      conv.options.oaiTier = 'standard';
    }
    if (!info.supportsProMode) {
      conv.options.oaiMode = 'standard';
    }
  }

  saveCurrent(): void {
    const cur = this.current();
    if (cur !== null) {
      this.files.save(cur);
    }
  }

  saveAll(): void {
    for (const c of this.conversations) {
      this.files.save(c);
    }
  }

  async send(text: string): Promise<void> {
    const trimmed = text.trim();
    if (trimmed.length === 0 || this.generating || !this.ready) {
      return;
    }
    let conv = this.current();
    if (conv === null) {
      conv = this.createConversation(this.settings.getLastProvider(), this.settings.getLastModel());
    }
    const userMsg = new ChatMessage(util.generateRandomUUID(), Role.USER);
    const ub = new MessageBlock(BlockKind.TEXT, `${userMsg.id}_t`);
    ub.text = trimmed;
    userMsg.blocks.push(ub);
    userMsg.status = MsgStatus.DONE;
    conv.messages.push(userMsg);
    if (conv.title === '新会话') {
      conv.title = trimmed.length > 24 ? `${trimmed.substring(0, 24)}…` : trimmed;
    }
    conv.updatedAt = Date.now();
    this.sortConversations();
    const assistant = new ChatMessage(util.generateRandomUUID(), Role.ASSISTANT);
    conv.messages.push(assistant);
    this.files.save(conv);
    this.generating = true;
    this.scrollTick++;
    await this.engine.run(conv, assistant, this.buildHost());
    this.generating = this.engine.isRunning();
    this.scrollTick++;
  }

  async retry(): Promise<void> {
    const conv = this.current();
    if (conv === null || this.generating) {
      return;
    }
    const last = conv.lastAssistant();
    if (last === null || last.status !== MsgStatus.FAILED) {
      return;
    }
    const idx = conv.messages.indexOf(last);
    if (idx >= 0) {
      conv.messages.splice(idx, 1);
    }
    const assistant = new ChatMessage(util.generateRandomUUID(), Role.ASSISTANT);
    conv.messages.push(assistant);
    this.files.save(conv);
    this.generating = true;
    this.scrollTick++;
    await this.engine.run(conv, assistant, this.buildHost());
    this.generating = this.engine.isRunning();
    this.scrollTick++;
  }

  stopGeneration(): void {
    this.engine.stop();
    this.generating = false;
    this.scrollTick++;
  }

  onBackground(): void {
    this.saveAll();
  }

  private sortConversations(): void {
    this.conversations.sort((a: Conversation, b: Conversation) => b.updatedAt - a.updatedAt);
  }

  private buildHost(): EngineHost {
    return {
      getKey: (p: ProviderId): Promise<string> => this.settings.getKey(p),
      getBaseUrl: (p: ProviderId): string => this.settings.getBaseUrl(p),
      persist: (conv: Conversation): void => {
        this.files.save(conv);
      },
      onChanged: (): void => {
        this.generating = this.engine.isRunning();
        this.scrollTick++;
      }
    };
  }
}