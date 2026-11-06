import { common } from '@kit.AbilityKit';
import {
  Session,
  Message,
  ModelConfig,
  AppSettings,
  ToolCall,
  getModelInfo,
  PROVIDER_NAMES
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
  @State messages: Message[] = [];
  @State inputText: string = '';
  @State isGenerating: boolean = false;
  @State showSettings: boolean = false;
  @State showSessionList: boolean = false;
  @State sessions: Session[] = [];
  @State settings: AppSettings = {
    providers: {
      deepseek: { apiKey: '' },
      openai: { apiKey: '' },
      mercury: { apiKey: '' },
      gemini: { apiKey: '' }
    }
  };
  @State modelConfig: ModelConfig = {
    providerId: 'deepseek',
    modelId: 'deepseek-flash',
    thinkingEnabled: false,
    thinkingEffort: 'none'
  };
  
  private store: Store | null = null;
  private chatEngine: ChatEngine | null = null;
  private scroller: Scroller = new Scroller();
  
  async aboutToAppear() {
    try {
      // 初始化存储
      const context = getContext(this) as common.UIAbilityContext;
      await initGlobalStore(context);
      this.store = getStore();
      
      // 加载设置
      this.settings = await this.store.getSettings();
      
      // 加载会话列表
      this.sessions = await this.store.getSessions();
      
      // 加载当前会话或创建新会话
      const currentId = await this.store.getCurrentSessionId();
      if (currentId) {
        this.currentSession = await this.store.getSession(currentId);
      }
      
      if (!this.currentSession) {
        await this.createNewSession();
      } else {
        this.messages = this.currentSession.messages;
        this.modelConfig = this.currentSession.modelConfig;
      }
      
      // 初始化聊天引擎
      this.chatEngine = new ChatEngine(this.store, this.settings);
      
    } catch (error) {
      console.error('Failed to initialize:', error);
    }
  }
  
  build() {
    Stack() {
      // 主界面
      Column() {
        // 顶部栏
        this.Header()
        
        // 消息列表
        if (this.messages.length === 0) {
          this.EmptyState()
        } else {
          List({ scroller: this.scroller, space: 12 }) {
            ForEach(this.messages, (message: Message) => {
              ListItem() {
                MessageBubble({ message })
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ top: 8, bottom: 8 })
        }
        
        // 输入区域
        this.InputArea()
      }
      .width('100%')
      .height('100%')
      
      // 设置面板(覆盖层)
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
        .backgroundColor('rgba(0, 0, 0, 0.3)')
        .onClick(() => {
          this.showSettings = false;
        })
      }
      
      // 会话列表(覆盖层)
      if (this.showSessionList) {
        Column() {
          SessionList({
            sessions: $sessions,
            currentSessionId: this.currentSession?.id || null,
            onSelectSession: (id: string) => {
              this.selectSession(id);
            },
            onNewSession: () => {
              this.createNewSession();
              this.showSessionList = false;
            },
            onDeleteSession: (id: string) => {
              this.deleteSession(id);
            },
            onClose: () => {
              this.showSessionList = false;
            }
          })
            .width('90%')
            .height('80%')
            .borderRadius(16)
            .shadow({ radius: 20, color: 'rgba(0, 0, 0, 0.3)' })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.5)')
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
      // 会话列表按钮
      Button('☰')
        .fontSize(18)
        .width(40)
        .height(40)
        .backgroundColor('#F0F0F0')
        .onClick(() => {
          this.showSessionList = true;
        })
      
      // 标题
      Column({ space: 2 }) {
        Text(this.currentSession?.title || '新对话')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        
        Text(`${PROVIDER_NAMES[this.modelConfig.providerId]} · ${this.modelConfig.modelId}`)
          .fontSize(11)
          .fontColor('#999999')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      
      // 设置按钮
      Button('⚙')
        .fontSize(18)
        .width(40)
        .height(40)
        .backgroundColor('#F0F0F0')
        .onClick(() => {
          this.showSettings = true;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor('#FFFFFF')
    .border({ width: { bottom: 1 }, color: '#E5E5E5' })
  }
  
  @Builder
  EmptyState() {
    Column({ space: 16 }) {
      Blank()
      
      Text('👋')
        .fontSize(64)
      
      Text('开始新对话')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
      
      Text('在下方输入消息开始对话')
        .fontSize(14)
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
      // 生成状态指示器
      if (this.isGenerating && this.chatEngine) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color('#007AFF')
          
          Text(this.getPhaseText())
            .fontSize(13)
            .fontColor('#666666')
          
          Blank()
          
          Button('停止')
            .fontSize(12)
            .height(28)
            .backgroundColor('#FF3B30')
            .onClick(() => {
              this.stopGeneration();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      
      // 输入框
      Row({ space: 8 }) {
        TextInput({
          placeholder: '输入消息...',
          text: $$this.inputText
        })
          .layoutWeight(1)
          .height(40)
          .enabled(!this.isGenerating)
          .onSubmit(() => {
            this.sendMessage();
          })
        
        Button(this.isGenerating ? '...' : '发送')
          .fontSize(14)
          .width(60)
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
    .backgroundColor('#FFFFFF')
    .border({ width: { top: 1 }, color: '#E5E5E5' })
  }
  
  private getPhaseText(): string {
    if (!this.chatEngine) return '';
    
    const phase = this.chatEngine.getPhase();
    switch (phase) {
      case 'requesting':
        return '请求中...';
      case 'thinking':
        return '思考中...';
      case 'tool_calling':
        return '调用工具...';
      case 'answering':
        return '生成回答...';
      default:
        return '处理中...';
    }
  }
  
  private async createNewSession() {
    if (!this.store) return;
    
    try {
      const session = await this.store.createSession(this.modelConfig);
      this.currentSession = session;
      this.messages = [];
      
      // 更新会话列表
      this.sessions = await this.store.getSessions();
      
      // 设置为当前会话
      await this.store.setCurrentSessionId(session.id);
      
    } catch (error) {
      console.error('Failed to create session:', error);
    }
  }
  
  private async selectSession(sessionId: string) {
    if (!this.store) return;
    
    try {
      const session = await this.store.getSession(sessionId);
      if (session) {
        this.currentSession = session;
        this.messages = session.messages;
        this.modelConfig = session.modelConfig;
        
        await this.store.setCurrentSessionId(sessionId);
        this.showSessionList = false;
        
        // 滚动到底部
        setTimeout(() => {
          this.scroller.scrollEdge(Edge.Bottom);
        }, 100);
      }
      
    } catch (error) {
      console.error('Failed to select session:', error);
    }
  }
  
  private async deleteSession(sessionId: string) {
    if (!this.store) return;
    
    try {
      await this.store.deleteSession(sessionId);
      this.sessions = await this.store.getSessions();
      
      // 如果删除的是当前会话，创建新会话
      if (this.currentSession?.id === sessionId) {
        await this.createNewSession();
      }
      
    } catch (error) {
      console.error('Failed to delete session:', error);
    }
  }
  
  private async saveSettings() {
    if (!this.store) return;
    
    try {
      // 保存设置
      await this.store.saveSettings(this.settings);
      
      // 更新聊天引擎的设置
      if (this.chatEngine) {
        this.chatEngine.updateSettings(this.settings);
      }
      
      // 如果当前会话存在，更新模型配置
      if (this.currentSession) {
        await this.store.updateSession(this.currentSession.id, {
          modelConfig: this.modelConfig
        });
        this.currentSession.modelConfig = this.modelConfig;
      }
      
    } catch (error) {
      console.error('Failed to save settings:', error);
    }
  }
  
  private async sendMessage() {
    if (!this.store || !this.chatEngine || !this.currentSession) return;
    
    const content = this.inputText.trim();
    if (!content || this.isGenerating) return;
    
    this.inputText = '';
    this.isGenerating = true;
    
    // 滚动到底部
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 100);
    
    const callbacks: ChatCallbacks = {
      onMessageUpdate: (message: Message) => {
        const index = this.messages.findIndex(m => m.id === message.id);
        if (index !== -1) {
          this.messages[index] = message;
        } else {
          this.messages.push(message);
        }
        
        // 滚动到底部
        setTimeout(() => {
          this.scroller.scrollEdge(Edge.Bottom);
        }, 50);
      },
      
      onToolCallUpdate: (messageId: string, toolCall: ToolCall) => {
        const message = this.messages.find(m => m.id === messageId);
        if (message && message.toolCalls) {
          const tcIndex = message.toolCalls.findIndex(tc => tc.id === toolCall.id);
          if (tcIndex !== -1) {
            message.toolCalls[tcIndex] = toolCall;
          }
        }
      },
      
      onError: (error: Error) => {
        console.error('Chat error:', error);
        this.isGenerating = false;
      },
      
      onComplete: (message: Message) => {
        this.isGenerating = false;
        
        // 自动生成会话标题
        if (this.store && this.currentSession) {
          this.store.generateSessionTitle(this.currentSession.id).then(() => {
            // 更新会话列表
            this.store!.getSessions().then(sessions => {
              this.sessions = sessions;
              
              // 更新当前会话
              if (this.currentSession) {
                this.store!.getSession(this.currentSession.id).then(session => {
                  if (session) {
                    this.currentSession = session;
                  }
                });
              }
            });
          });
        }
      }
    };
    
    try {
      await this.chatEngine.sendMessage(
        this.currentSession.id,
        content,
        this.modelConfig,
        callbacks
      );
    } catch (error) {
      console.error('Failed to send message:', error);
      this.isGenerating = false;
    }
  }
  
  private stopGeneration() {
    if (this.chatEngine) {
      this.chatEngine.stop();
      this.isGenerating = false;
    }
  }
}
