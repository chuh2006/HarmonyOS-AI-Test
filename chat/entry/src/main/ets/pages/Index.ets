import { common } from '@kit.AbilityKit';
import {
  AppSettings,
  ChatError,
  Message,
  ModelConfig,
  Session,
  ToolCall,
  createDefaultModelConfig,
  createDefaultSettings,
  getProviderName
} from '../types/Types';
import { Store, initGlobalStore, getStore } from '../services/Store';
import { ChatEngine, ChatCallbacks } from '../services/ChatEngine';
import { MessageBubble } from '../components/MessageBubble';
import { SettingsPanel } from '../components/SettingsPanel';
import { SessionList } from '../components/SessionList';

@Entry
@Component
struct Index {
  @State currentSession: Session | null = null;
  @State currentSessionId: string = '';
  @State sessionTitle: string = '新对话';
  @State messages: Message[] = [];
  @State sessions: Session[] = [];
  @State inputText: string = '';
  @State isGenerating: boolean = false;
  @State phaseText: string = '';
  @State errorText: string = '';
  @State showSettings: boolean = false;
  @State showSessionList: boolean = false;
  @State settings: AppSettings = createDefaultSettings();
  @State modelConfig: ModelConfig = createDefaultModelConfig();

  private store: Store | null = null;
  private chatEngine: ChatEngine | null = null;
  private scroller: Scroller = new Scroller();

  async aboutToAppear(): Promise<void> {
    try {
      const context: common.Context | undefined = this.getUIContext().getHostContext();
      if (context === undefined) {
        this.errorText = '无法获取应用上下文';
        return;
      }

      await initGlobalStore(context);
      const store: Store = getStore();
      this.store = store;
      this.settings = await store.getSettings();
      this.sessions = await store.getSessions();

      const savedId: string | null = await store.getCurrentSessionId();
      let session: Session | null = null;
      if (savedId !== null) {
        session = await store.getSession(savedId);
      }
      if (session === null) {
        session = await store.createSession(this.modelConfig);
        await store.setCurrentSessionId(session.id);
      }

      this.applySession(session);
      this.chatEngine = new ChatEngine(store, this.settings);
    } catch (error) {
      const err: Error = error instanceof Error ? error : new Error('初始化失败');
      console.error(`初始化失败: ${err.message}`);
      this.errorText = err.message;
    }
  }

  build() {
    Stack() {
      Column() {
        this.Header()

        if (this.messages.length === 0) {
          this.EmptyState()
        } else {
          List({ scroller: this.scroller, space: 8 }) {
            ForEach(this.messages, (message: Message) => {
              ListItem() {
                MessageBubble({ message: message })
              }
            }, (message: Message) => this.messageKey(message))
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ top: 8, bottom: 8 })
          .scrollBar(BarState.Off)
        }

        this.InputArea()
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#FFFFFF')

      if (this.showSettings) {
        Column() {
          SettingsPanel({
            settings: $settings,
            modelConfig: $modelConfig,
            onClose: () => {
              this.showSettings = false;
            },
            onSave: () => {
              this.saveSettings();
            }
          })
        }
        .width('100%')
        .height('100%')
      }

      if (this.showSessionList) {
        Column() {
          SessionList({
            sessions: this.sessions,
            currentSessionId: this.currentSessionId,
            onSelectSession: (sessionId: string) => {
              this.selectSession(sessionId);
            },
            onNewSession: () => {
              this.createNewSession();
            },
            onDeleteSession: (sessionId: string) => {
              this.deleteSession(sessionId);
            },
            onClose: () => {
              this.showSessionList = false;
            }
          })
            .width('90%')
            .height('80%')
            .borderRadius(16)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.showSessionList = false;
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  Header() {
    Row({ space: 12 }) {
      Button('会话')
        .fontSize(13)
        .height(34)
        .backgroundColor('#F0F0F0')
        .fontColor('#000000')
        .onClick(() => {
          this.refreshSessions();
          this.showSessionList = true;
        })

      Column({ space: 2 }) {
        Text(this.sessionTitle)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(`${getProviderName(this.modelConfig.providerId)} · ${this.modelConfig.modelId}`)
          .fontSize(11)
          .fontColor('#999999')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button('设置')
        .fontSize(13)
        .height(34)
        .backgroundColor('#F0F0F0')
        .fontColor('#000000')
        .onClick(() => {
          this.showSettings = true;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .border({ width: { bottom: 1 }, color: '#E5E5E5' })
  }

  @Builder
  EmptyState() {
    Column({ space: 12 }) {
      Blank()
      Text('开始新对话')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#333333')
      Text('输入消息，随时切换模型与参数')
        .fontSize(13)
        .fontColor('#999999')
      Blank()
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  InputArea() {
    Column({ space: 8 }) {
      if (this.errorText.length > 0) {
        Row({ space: 12 }) {
          Text(this.errorText)
            .fontSize(12)
            .fontColor('#FF3B30')
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text('重试')
            .fontSize(12)
            .fontColor('#007AFF')
            .onClick(() => {
              this.retryLast();
            })

          Text('忽略')
            .fontSize(12)
            .fontColor('#007AFF')
            .onClick(() => {
              this.errorText = '';
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }

      if (this.isGenerating) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color('#007AFF')

          Text(this.phaseText.length > 0 ? this.phaseText : '生成中...')
            .fontSize(13)
            .fontColor('#666666')

          Blank()

          Button('停止')
            .fontSize(12)
            .height(30)
            .backgroundColor('#FF3B30')
            .onClick(() => {
              this.stopGeneration();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }

      Row({ space: 8 }) {
        TextInput({ placeholder: '输入消息...', text: this.inputText })
          .layoutWeight(1)
          .height(40)
          .fontSize(15)
          .onChange((value: string) => {
            this.inputText = value;
          })
          .onSubmit(() => {
            this.sendMessage();
          })

        Button('发送')
          .fontSize(14)
          .width(64)
          .height(40)
          .enabled(!this.isGenerating && this.inputText.trim().length > 0)
          .onClick(() => {
            this.sendMessage();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .padding({ top: 8 })
    .border({ width: { top: 1 }, color: '#E5E5E5' })
  }

  private messageKey(message: Message): string {
    const thinkingLength: number = message.thinking !== undefined ? message.thinking.length : 0;
    let toolState: string = '';
    if (message.toolCalls !== undefined) {
      for (const toolCall of message.toolCalls) {
        toolState += `${toolCall.id}:${toolCall.status};`;
      }
    }
    return `${message.id}|${message.status}|${message.content.length}|${thinkingLength}|${toolState}`;
  }

  private applySession(session: Session): void {
    this.currentSession = session;
    this.currentSessionId = session.id;
    this.sessionTitle = session.title;
    this.messages = this.visibleMessages(session.messages);
    this.modelConfig = session.modelConfig;
    this.scrollToBottom();
  }

  // 工具结果消息只作为协议上下文存在，界面上由助手消息里的工具卡片展示
  private visibleMessages(messages: Message[]): Message[] {
    const result: Message[] = [];
    for (const message of messages) {
      if (message.role === 'user' || message.role === 'assistant') {
        result.push(message);
      }
    }
    return result;
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 60);
  }

  private refreshSessions(): void {
    const store: Store | null = this.store;
    if (store === null) {
      return;
    }
    store.getSessions().then((sessions: Session[]) => {
      this.sessions = sessions;
    });
  }

  private upsertMessage(message: Message): void {
    if (message.role !== 'user' && message.role !== 'assistant') {
      return;
    }
    const updated: Message[] = [];
    let found: boolean = false;
    for (const item of this.messages) {
      if (item.id === message.id) {
        updated.push(message);
        found = true;
      } else {
        updated.push(item);
      }
    }
    if (!found) {
      updated.push(message);
    }
    this.messages = updated;
    this.scrollToBottom();
  }

  private updateToolCall(messageId: string, toolCall: ToolCall): void {
    const updated: Message[] = [];
    for (const item of this.messages) {
      if (item.id === messageId && item.toolCalls !== undefined) {
        const calls: ToolCall[] = [];
        let replaced: boolean = false;
        for (const existing of item.toolCalls) {
          if (existing.id === toolCall.id) {
            calls.push(toolCall);
            replaced = true;
          } else {
            calls.push(existing);
          }
        }
        if (!replaced) {
          calls.push(toolCall);
        }
        const copy: Message = {
          id: item.id,
          role: item.role,
          content: item.content,
          thinking: item.thinking,
          status: item.status,
          toolCalls: calls,
          timestamp: item.timestamp,
          error: item.error,
          protocolData: item.protocolData
        };
        updated.push(copy);
      } else {
        updated.push(item);
      }
    }
    this.messages = updated;
  }

  private createNewSession(): void {
    const store: Store | null = this.store;
    if (store === null) {
      return;
    }
    store.createSession(this.modelConfig).then((session: Session) => {
      this.applySession(session);
      return store.setCurrentSessionId(session.id);
    }).then(() => {
      this.refreshSessions();
      this.showSessionList = false;
    }).catch((error: Error) => {
      this.errorText = error.message;
    });
  }

  private selectSession(sessionId: string): void {
    const store: Store | null = this.store;
    if (store === null) {
      return;
    }
    store.getSession(sessionId).then((session: Session | null) => {
      if (session === null) {
        return;
      }
      this.applySession(session);
      this.errorText = '';
      return store.setCurrentSessionId(sessionId);
    }).then(() => {
      this.showSessionList = false;
    }).catch((error: Error) => {
      this.errorText = error.message;
    });
  }

  private deleteSession(sessionId: string): void {
    const store: Store | null = this.store;
    if (store === null) {
      return;
    }
    store.deleteSession(sessionId).then(() => {
      this.refreshSessions();
      if (this.currentSessionId === sessionId) {
        this.createNewSession();
      }
    }).catch((error: Error) => {
      this.errorText = error.message;
    });
  }

  private saveSettings(): void {
    const store: Store | null = this.store;
    if (store === null) {
      return;
    }
    store.saveSettings(this.settings).then(() => {
      const engine: ChatEngine | null = this.chatEngine;
      if (engine !== null) {
        engine.updateSettings(this.settings);
      }
      const session: Session | null = this.currentSession;
      if (session === null) {
        return Promise.resolve();
      }
      // 每个会话记住自己选用的服务商/模型/选项
      return store.updateSession(session.id, { modelConfig: this.modelConfig });
    }).then(() => {
      this.refreshSessions();
    }).catch((error: Error) => {
      this.errorText = error.message;
    });
  }

  private buildCallbacks(sessionId: string): ChatCallbacks {
    const store: Store | null = this.store;
    const callbacks: ChatCallbacks = {
      onMessageUpdate: (message: Message) => {
        this.upsertMessage(message);
        const engine: ChatEngine | null = this.chatEngine;
        if (engine !== null) {
          this.syncPhase(engine);
        }
      },
      onToolCallUpdate: (messageId: string, toolCall: ToolCall) => {
        this.updateToolCall(messageId, toolCall);
      },
      onError: (error: ChatError) => {
        this.isGenerating = false;
        this.phaseText = '';
        this.errorText = error.message;
      },
      onComplete: (message: Message) => {
        this.isGenerating = false;
        this.phaseText = '';
        this.upsertMessage(message);
        if (store === null) {
          return;
        }
        store.generateSessionTitle(sessionId).then(() => {
          return store.getSession(sessionId);
        }).then((updated: Session | null) => {
          if (updated !== null && this.currentSessionId === sessionId) {
            this.sessionTitle = updated.title;
            this.currentSession = updated;
          }
          this.refreshSessions();
        }).catch((error: Error) => {
          console.error(`更新会话标题失败: ${error.message}`);
        });
      }
    };
    return callbacks;
  }

  private sendMessage(): void {
    const engine: ChatEngine | null = this.chatEngine;
    const session: Session | null = this.currentSession;
    if (this.store === null || engine === null || session === null) {
      return;
    }

    const content: string = this.inputText.trim();
    if (content.length === 0 || this.isGenerating) {
      return;
    }

    this.inputText = '';
    this.beginGeneration();

    const sessionId: string = session.id;
    engine.sendMessage(sessionId, content, this.modelConfig, this.buildCallbacks(sessionId))
      .then(() => {
        this.endGeneration();
      })
      .catch((error: Error) => {
        this.endGeneration();
        this.errorText = error.message;
      });
  }

  // 失败后重试：引擎会截掉最后一条失败的助手消息并重新生成
  private retryLast(): void {
    const engine: ChatEngine | null = this.chatEngine;
    const session: Session | null = this.currentSession;
    if (engine === null || session === null || this.isGenerating) {
      return;
    }

    this.dropTrailingFailedMessage();
    this.beginGeneration();

    const sessionId: string = session.id;
    engine.retryLastMessage(sessionId, this.modelConfig, this.buildCallbacks(sessionId))
      .then(() => {
        this.endGeneration();
      })
      .catch((error: Error) => {
        this.endGeneration();
        this.errorText = error.message;
      });
  }

  private dropTrailingFailedMessage(): void {
    let cutIndex: number = this.messages.length;
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === 'assistant') {
        cutIndex = i;
        break;
      }
    }
    if (cutIndex < this.messages.length && this.messages[cutIndex].status === 'error') {
      this.messages = this.messages.slice(0, cutIndex);
    }
  }

  private beginGeneration(): void {
    this.errorText = '';
    this.isGenerating = true;
    this.phaseText = '请求中...';
  }

  private endGeneration(): void {
    this.isGenerating = false;
    this.phaseText = '';
    this.refreshSessions();
  }

  private syncPhase(engine: ChatEngine): void {
    const phase: string = engine.getPhase();
    if (phase === 'requesting') {
      this.phaseText = '请求中...';
    } else if (phase === 'thinking') {
      this.phaseText = '思考中...';
    } else if (phase === 'tool_calling') {
      this.phaseText = '调用工具...';
    } else if (phase === 'answering') {
      this.phaseText = '生成中...';
    } else {
      this.phaseText = '';
    }
  }

  private stopGeneration(): void {
    const engine: ChatEngine | null = this.chatEngine;
    if (engine === null) {
      return;
    }
    engine.stop();
    this.isGenerating = false;
    this.phaseText = '';
  }
}
