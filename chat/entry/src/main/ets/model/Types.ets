export enum ProviderId {
  DEEPSEEK = 'deepseek',
  OPENAI = 'openai',
  MERCURY = 'mercury',
  GEMINI = 'gemini'
}

export enum Role {
  USER = 'user',
  ASSISTANT = 'assistant'
}

export enum BlockKind {
  THINKING = 'thinking',
  TEXT = 'text',
  TOOL = 'tool'
}

export enum ToolStatus {
  NONE = 'none',
  STREAMING = 'streaming',
  WAITING = 'waiting',
  RUNNING = 'running',
  DONE = 'done',
  ERROR = 'error',
  STOPPED = 'stopped'
}

export enum MsgStatus {
  REQUESTING = 'requesting',
  THINKING = 'thinking',
  TOOL = 'tool',
  ANSWERING = 'answering',
  DONE = 'done',
  STOPPED = 'stopped',
  FAILED = 'failed'
}

export interface BlockData {
  kind: string;
  text: string;
  collapsed: boolean;
  toolId: string;
  toolName: string;
  toolArgs: string;
  toolStatus: string;
  toolResult: string;
  toolDisplay: string;
  toolError: string;
}

@ObservedV2
export class MessageBlock {
  id: string = '';
  @Trace kind: BlockKind = BlockKind.TEXT;
  @Trace text: string = '';
  @Trace collapsed: boolean = false;
  @Trace toolId: string = '';
  @Trace toolName: string = '';
  @Trace toolArgs: string = '';
  @Trace toolStatus: ToolStatus = ToolStatus.NONE;
  @Trace toolResult: string = '';
  @Trace toolDisplay: string = '';
  @Trace toolError: string = '';

  constructor(kind: BlockKind, id: string) {
    this.kind = kind;
    this.id = id;
  }

  toData(): BlockData {
    return {
      kind: this.kind as string,
      text: this.text,
      collapsed: this.collapsed,
      toolId: this.toolId,
      toolName: this.toolName,
      toolArgs: this.toolArgs,
      toolStatus: this.toolStatus as string,
      toolResult: this.toolResult,
      toolDisplay: this.toolDisplay,
      toolError: this.toolError
    };
  }

  static fromData(d: BlockData, id: string): MessageBlock {
    const b = new MessageBlock(d.kind as BlockKind, id);
    b.text = d.text;
    b.collapsed = d.collapsed;
    b.toolId = d.toolId;
    b.toolName = d.toolName;
    b.toolArgs = d.toolArgs;
    b.toolStatus = d.toolStatus as ToolStatus;
    b.toolResult = d.toolResult;
    b.toolDisplay = d.toolDisplay;
    b.toolError = d.toolError;
    return b;
  }
}

export interface MessageData {
  id: string;
  role: string;
  blocks: BlockData[];
  status: string;
  error: string;
  phases: string[];
  createdAt: number;
  usageText: string;
}

@ObservedV2
export class ChatMessage {
  @Trace id: string = '';
  @Trace role: Role = Role.ASSISTANT;
  @Trace blocks: MessageBlock[] = [];
  @Trace status: MsgStatus = MsgStatus.REQUESTING;
  @Trace error: string = '';
  @Trace phases: string[] = [];
  @Trace createdAt: number = 0;
  @Trace usageText: string = '';

  constructor(id: string, role: Role) {
    this.id = id;
    this.role = role;
    this.createdAt = Date.now();
  }

  textContent(): string {
    let out = '';
    for (const b of this.blocks) {
      if (b.kind === BlockKind.TEXT) {
        out += b.text;
      }
    }
    return out;
  }

  toolBlocks(): MessageBlock[] {
    const out: MessageBlock[] = [];
    for (const b of this.blocks) {
      if (b.kind === BlockKind.TOOL) {
        out.push(b);
      }
    }
    return out;
  }

  findToolBlock(toolId: string): MessageBlock | null {
    for (const b of this.blocks) {
      if (b.kind === BlockKind.TOOL && b.toolId === toolId) {
        return b;
      }
    }
    return null;
  }

  toData(): MessageData {
    const blocks: BlockData[] = [];
    for (const b of this.blocks) {
      blocks.push(b.toData());
    }
    return {
      id: this.id,
      role: this.role as string,
      blocks: blocks,
      status: this.status as string,
      error: this.error,
      phases: this.phases,
      createdAt: this.createdAt,
      usageText: this.usageText
    };
  }

  static fromData(d: MessageData): ChatMessage {
    const m = new ChatMessage(d.id, d.role as Role);
    m.status = d.status as MsgStatus;
    m.error = d.error;
    m.phases = d.phases;
    m.createdAt = d.createdAt;
    m.usageText = d.usageText;
    let i = 0;
    for (const bd of d.blocks) {
      m.blocks.push(MessageBlock.fromData(bd, `${d.id}_b${i}`));
      i++;
    }
    return m;
  }
}

export interface OptionsData {
  dsThinking: boolean;
  dsEffort: string;
  oaiEffort: string;
  oaiMode: string;
  oaiTier: string;
  mercDiffusing: boolean;
  mercEffort: string;
  gemLevel: string;
}

@ObservedV2
export class ChatOptions {
  @Trace dsThinking: boolean = true;
  @Trace dsEffort: string = 'high';
  @Trace oaiEffort: string = 'medium';
  @Trace oaiMode: string = 'standard';
  @Trace oaiTier: string = 'standard';
  @Trace mercDiffusing: boolean = true;
  @Trace mercEffort: string = 'low';
  @Trace gemLevel: string = 'medium';

  toData(): OptionsData {
    return {
      dsThinking: this.dsThinking,
      dsEffort: this.dsEffort,
      oaiEffort: this.oaiEffort,
      oaiMode: this.oaiMode,
      oaiTier: this.oaiTier,
      mercDiffusing: this.mercDiffusing,
      mercEffort: this.mercEffort,
      gemLevel: this.gemLevel
    };
  }

  static fromData(d: OptionsData): ChatOptions {
    const o = new ChatOptions();
    o.dsThinking = d.dsThinking;
    o.dsEffort = d.dsEffort;
    o.oaiEffort = d.oaiEffort;
    o.oaiMode = d.oaiMode;
    o.oaiTier = d.oaiTier;
    o.mercDiffusing = d.mercDiffusing;
    o.mercEffort = d.mercEffort;
    o.gemLevel = d.gemLevel;
    return o;
  }
}

export interface ConversationData {
  id: string;
  title: string;
  provider: string;
  model: string;
  options: OptionsData;
  messages: MessageData[];
  createdAt: number;
  updatedAt: number;
}

@ObservedV2
export class Conversation {
  @Trace id: string = '';
  @Trace title: string = '';
  @Trace provider: ProviderId = ProviderId.DEEPSEEK;
  @Trace model: string = '';
  @Trace options: ChatOptions = new ChatOptions();
  @Trace messages: ChatMessage[] = [];
  @Trace createdAt: number = 0;
  @Trace updatedAt: number = 0;

  constructor(id: string, provider: ProviderId, model: string) {
    this.id = id;
    this.provider = provider;
    this.model = model;
    this.createdAt = Date.now();
    this.updatedAt = this.createdAt;
    this.title = '新会话';
  }

  lastAssistant(): ChatMessage | null {
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === Role.ASSISTANT) {
        return this.messages[i];
      }
    }
    return null;
  }

  toData(): ConversationData {
    const msgs: MessageData[] = [];
    for (const m of this.messages) {
      msgs.push(m.toData());
    }
    return {
      id: this.id,
      title: this.title,
      provider: this.provider as string,
      model: this.model,
      options: this.options.toData(),
      messages: msgs,
      createdAt: this.createdAt,
      updatedAt: this.updatedAt
    };
  }

  static fromData(d: ConversationData): Conversation {
    const c = new Conversation(d.id, d.provider as ProviderId, d.model);
    c.title = d.title;
    c.options = ChatOptions.fromData(d.options);
    c.createdAt = d.createdAt;
    c.updatedAt = d.updatedAt;
    for (const md of d.messages) {
      const m = ChatMessage.fromData(md);
      if (m.role === Role.ASSISTANT &&
        (m.status === MsgStatus.REQUESTING || m.status === MsgStatus.THINKING ||
          m.status === MsgStatus.TOOL || m.status === MsgStatus.ANSWERING)) {
        m.status = MsgStatus.STOPPED;
      }
      c.messages.push(m);
    }
    return c;
  }
}