/**
 * Main chat screen: header, message list, composer, and the three sheets.
 */
import { common } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { defaultOptionsFor, Msg, Session, SessionOptions, PHASE_IDLE } from '../services/Types';
import { SessionStore } from '../services/SessionStore';
import { ChatEngine } from '../services/ChatEngine';
import { ToolRunner } from '../services/Tools';
import { modelInfo, providerInfo } from '../services/Providers';
import { MessageView } from '../view/MessageView';
import { ModelSheetView, SessionsSheetView, SettingsSheetView } from '../view/Sheets';
import { confirmDialog, showToast } from '../common/Ui';
import {
  COLOR_BORDER, COLOR_ERR, COLOR_PRIMARY, COLOR_PRIMARY_SOFT,
  COLOR_SURFACE, COLOR_SURFACE_SOFT, COLOR_TEXT, COLOR_TEXT_2, COLOR_TEXT_3,
  GRAD_PRIMARY, FONT_SMALL
} from '../view/Theme';
import {
  IconChevron, IconMenu, IconSend, IconSliders, IconSparkle, IconStop, IconWarn
} from '../view/Icons';
import { newId } from '../common/Util';

const ENGINE: ChatEngine = new ChatEngine();

function phaseLabel(p: string): string {
  if (p === 'requesting') {
    return '正在请求…';
  }
  if (p === 'thinking') {
    return '思考中…';
  }
  if (p === 'tool') {
    return '正在执行工具…';
  }
  if (p === 'answering') {
    return '正在回答…';
  }
  if (p === 'done') {
    return '完成';
  }
  if (p === 'stopped') {
    return '已停止';
  }
  if (p === 'error') {
    return '失败';
  }
  return '';
}

function isActivePhase(p: string): boolean {
  return p === 'requesting' || p === 'thinking' || p === 'tool' || p === 'answering';
}

@Entry
@Component
struct Index {
  @State sessions: Session[] = [];
  @State currentId: string = '';
  @State msgs: Msg[] = [];
  @State phase: string = PHASE_IDLE;
  @State inputText: string = '';
  @State headerModel: string = '';
  @State headerTitle: string = '新会话';
  @State toolsReady: boolean = false;
  @State atBottom: boolean = true;
  @State showSessions: boolean = false;
  @State showModel: boolean = false;
  @State showSettings: boolean = false;

  private scroller: ListScroller = new ListScroller();
  private lastCount: number = -1;
  private curSession: Session = new Session();

  aboutToAppear(): void {
    try {
      let filesDir: string = '';
      try {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        filesDir = ctx.filesDir;
      } catch (e1) {
        const ctx = getContext(this) as common.UIAbilityContext;
        filesDir = ctx.filesDir;
      }
      SessionStore.init(filesDir);
      ENGINE.loadCredentials().then(() => {
        this.toolsReady = ToolRunner.available(ENGINE.getKey('deepseek'));
      });
      this.sessions = SessionStore.loadAll();
    const settings: Record<string, Object> = SessionStore.loadSettings();
    const lastId: Object | undefined = settings['lastSessionId'];
    let picked: string = '';
    if (lastId !== undefined && lastId !== null && typeof lastId === 'string') {
      picked = lastId as string;
    }
    let found: Session | null = null;
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === picked) {
        found = this.sessions[i];
      }
    }
    if (found === null && this.sessions.length > 0) {
      found = this.sessions[0];
    }
    if (found === null) {
      const s: Session = this.makeSession();
      this.sessions = [s];
      found = s;
      SessionStore.save(s);
    }
    this.currentId = found.id;
    this.refresh();

    ENGINE.onUpdate = (sessionId: string): void => {
      if (sessionId === this.currentId) {
        this.refresh();
      } else {
        // a background conversation produced data; keep the list fresh
        this.sessions = this.sessions.slice();
      }
    };
    ENGINE.onPhase = (sessionId: string, p: string): void => {
      if (sessionId === this.currentId) {
        this.phase = p;
      }
    };
    this.phase = ENGINE.phaseOf(this.currentId);
    } catch (e) {
      // initialization must never leave the page unusable
    }
  }

  private makeSession(): Session {
    const s: Session = new Session();
    s.id = newId('s');
    s.createdAt = Date.now();
    s.updatedAt = Date.now();
    const cur: Session | null = this.current();
    if (cur !== null) {
      s.providerId = cur.providerId;
      s.modelId = cur.modelId;
      const o: SessionOptions = new SessionOptions();
      o.thinkingOn = cur.options.thinkingOn;
      o.thinkingLevel = cur.options.thinkingLevel;
      o.reasoningMode = cur.options.reasoningMode;
      o.speedTier = cur.options.speedTier;
      o.diffusing = cur.options.diffusing;
      s.options = o;
    } else {
      s.providerId = 'deepseek';
      s.modelId = 'deepseek-flash';
      s.options = defaultOptionsFor('deepseek');
    }
    return s;
  }

  private current(): Session | null {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].id === this.currentId) {
        return this.sessions[i];
      }
    }
    return null;
  }

  private refresh(): void {
    const s: Session | null = this.current();
    if (s === null) {
      this.msgs = [];
      return;
    }
    this.curSession = s;
    this.msgs = s.messages.slice();
    this.headerTitle = s.title.length > 0 ? s.title : '新会话';
    this.headerModel = providerInfo(s.providerId).name + ' · ' + modelInfo(s.providerId, s.modelId).label;
    if (this.msgs.length !== this.lastCount) {
      this.lastCount = this.msgs.length;
      if (this.atBottom) {
        this.scrollDown();
      }
    }
    this.sessions = this.sessions.slice();
  }

  private scrollDown(): void {
    setTimeout(() => {
      try {
        this.scroller.scrollToIndex(this.msgs.length + 1);
      } catch (e) {
        // ignore
      }
    }, 60);
  }

  private persistLast(): void {
    const settings: Record<string, Object> = SessionStore.loadSettings();
    settings['lastSessionId'] = this.currentId;
    SessionStore.saveSettings(settings);
  }

  // ---------------- actions ----------------

  private sendNow(): void {
    const s: Session | null = this.current();
    if (s === null) {
      return;
    }
    const text: string = this.inputText.trim();
    if (text.length === 0) {
      return;
    }
    if (ENGINE.isRunning(s.id)) {
      return;
    }
    if (!ToolRunner.available(ENGINE.getKey(s.providerId))) {
      showToast('请先在 API 设置中填写 ' + providerInfo(s.providerId).name + ' 的 API Key');
      this.showSettings = true;
      return;
    }
    this.inputText = '';
    this.atBottom = true;
    ENGINE.send(s, text);
    this.refresh();
  }

  private stopNow(): void {
    ENGINE.stop(this.currentId);
    this.phase = 'stopped';
    showToast('已停止生成');
  }

  private retryNow(): void {
    const s: Session | null = this.current();
    if (s === null) {
      return;
    }
    if (ENGINE.isRunning(s.id)) {
      return;
    }
    if (!ToolRunner.available(ENGINE.getKey(s.providerId))) {
      this.showSettings = true;
      return;
    }
    this.atBottom = true;
    ENGINE.retry(s);
    this.refresh();
  }

  private switchTo(id: string): void {
    this.showSessions = false;
    if (id === this.currentId) {
      return;
    }
    this.currentId = id;
    this.lastCount = -1;
    this.refresh();
    this.phase = ENGINE.phaseOf(id);
    this.persistLast();
  }

  private newSession(): void {
    this.showSessions = false;
    const s: Session = this.makeSession();
    const arr: Session[] = this.sessions.slice();
    arr.unshift(s);
    this.sessions = arr;
    this.currentId = s.id;
    this.lastCount = -1;
    this.phase = PHASE_IDLE;
    this.refresh();
    this.persistLast();
    SessionStore.save(s);
  }

  private deleteSession(id: string): void {
    confirmDialog('删除会话', '删除后无法恢复，确定要删除这个会话吗？', '删除').then((ok: boolean) => {
      if (!ok) {
        return;
      }
      SessionStore.remove(id);
      const arr: Session[] = [];
      for (let i = 0; i < this.sessions.length; i++) {
        if (this.sessions[i].id !== id) {
          arr.push(this.sessions[i]);
        }
      }
      if (arr.length === 0) {
        const s: Session = this.makeSession();
        arr.push(s);
        SessionStore.save(s);
      }
      this.sessions = arr;
      if (this.currentId === id) {
        this.currentId = arr[0].id;
        this.lastCount = -1;
      }
      this.refresh();
      this.persistLast();
    });
  }

  private onSessionChanged(s: Session): void {
    SessionStore.save(s);
    this.refresh();
  }

  private onSettingsSave(id: string, key: string, url: string): void {
    ENGINE.setKey(id, key.trim());
    ENGINE.setBaseUrl(id, url.trim());
    this.toolsReady = ToolRunner.available(ENGINE.getKey('deepseek'));
    showToast('已保存');
    this.refresh();
  }

  // ---------------- builders ----------------

  @Builder
  statusBar() {
    if (phaseLabel(this.phase).length > 0) {
      Row({ space: 7 }) {
        if (isActivePhase(this.phase)) {
          LoadingProgress().width(14).height(14).color(COLOR_PRIMARY)
        } else if (this.phase === 'done') {
          IconSparkle(COLOR_PRIMARY, 13)
        } else if (this.phase === 'stopped') {
          IconStop(COLOR_TEXT_2, 12)
        } else if (this.phase === 'error') {
          IconWarn(COLOR_ERR, 14)
        }
        Text(phaseLabel(this.phase))
          .fontSize(12)
          .fontColor(this.phase === 'error' ? COLOR_ERR :
            (this.phase === 'stopped' ? COLOR_TEXT_2 : COLOR_PRIMARY))
      }
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .borderRadius(999)
      .backgroundColor(this.phase === 'error' ? '#FBE9E8' :
        (this.phase === 'stopped' ? COLOR_SURFACE_SOFT : COLOR_PRIMARY_SOFT))
      .margin({ bottom: 8 })
    }
  }

  @Builder
  emptyState() {
    Column({ space: 16 }) {
      Column() {
        IconSparkle('#FFFFFF', 36)
      }
      .width(76).height(76)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .borderRadius(24)
      .linearGradient({ angle: 135, colors: [[GRAD_PRIMARY[0], 0], [GRAD_PRIMARY[1], 1]] })
      .margin({ top: 60 })

      Column({ space: 6 }) {
        Text('有什么可以帮你的？')
          .fontSize(21)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)
        Text('选择服务商与模型，开始一段新的对话')
          .fontSize(13)
          .fontColor(COLOR_TEXT_3)
      }

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, space: { main: LengthMetrics.vp(8), cross: LengthMetrics.vp(8) } }) {
        ForEach(['帮我写一封得体的请假邮件', '解释一下扩散语言模型', '搜索今天的科技新闻', '用简单的比喻讲讲量子纠缠'],
          (s: string) => {
            Text(s)
              .fontSize(12.5)
              .fontColor(COLOR_TEXT_2)
              .padding({ left: 14, right: 14, top: 9, bottom: 9 })
              .borderRadius(999)
              .backgroundColor(COLOR_SURFACE)
              .border({ width: 1, color: COLOR_BORDER })
              .onClick(() => {
                this.inputText = s;
                this.sendNow();
              })
          }, (s: string) => s)
      }
      .width('86%')
      .margin({ top: 14 })
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  sessionsSheet() {
    SessionsSheetView({
      sessions: this.sessions,
      currentId: this.currentId,
      onSelect: (id: string) => {
        this.switchTo(id);
      },
      onDelete: (id: string) => {
        this.deleteSession(id);
      },
      onNew: () => {
        this.newSession();
      }
    })
  }

  @Builder
  modelSheet() {
    ModelSheetView({
      session: this.curSession,
      toolsReady: this.toolsReady,
      onChanged: (s: Session) => {
        this.onSessionChanged(s);
      },
      onOpenSettings: () => {
        this.showModel = false;
        this.showSettings = true;
      },
      onClose: () => {
        this.showModel = false;
      }
    })
  }

  @Builder
  settingsSheet() {
    SettingsSheetView({
      getKey: (id: string) => {
        return ENGINE.getKey(id);
      },
      getBaseUrl: (id: string, fallback: string) => {
        return ENGINE.getBaseUrl(id, fallback);
      },
      onSave: (id: string, key: string, url: string) => {
        this.onSettingsSave(id, key, url);
      },
      onClose: () => {
        this.showSettings = false;
      }
    })
  }

  build() {
    Stack() {
      Column() {
        // ------- header -------
        Row({ space: 10 }) {
          Row() {
            IconMenu(COLOR_TEXT, 18)
          }
          .width(38).height(38)
          .borderRadius(12)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(COLOR_SURFACE)
          .border({ width: 1, color: COLOR_BORDER })
          .onClick(() => {
            this.showSessions = true;
          })

        Column({ space: 2 }) {
          Text(this.headerTitle)
            .fontSize(FONT_SMALL + 2)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLOR_TEXT)
            .maxLines(1)
            .textAlign(TextAlign.Center)
          Row({ space: 4 }) {
            Text(this.headerModel)
              .fontSize(11)
              .fontColor(COLOR_TEXT_3)
            IconChevron(COLOR_TEXT_3, 11, false)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        .onClick(() => {
          this.showModel = true;
        })

        Row() {
          IconSliders(COLOR_TEXT, 18)
        }
        .width(38).height(38)
        .borderRadius(12)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(COLOR_SURFACE)
        .border({ width: 1, color: COLOR_BORDER })
        .onClick(() => {
          this.showSettings = true;
        })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor('#F8F8FB')

      // ------- messages -------
      if (this.msgs.length === 0) {
        this.emptyState()
      } else {
        List({ space: 22, scroller: this.scroller }) {
          ListItem() {
            Column().width('100%').height(4)
          }
          ForEach(this.msgs, (m: Msg) => {
            ListItem() {
              MessageView({
                msg: m,
                liveLabel: m.status === 'streaming' ? phaseLabel(this.phase) : '',
                onRetry: () => {
                  this.retryNow();
                }
              })
            }
          }, (m: Msg) => m.id)
          ListItem() {
            Column().width('100%').height(4)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onScrollIndex((first: number, last: number) => {
          this.atBottom = last >= this.msgs.length;
        })
      }

      // ------- composer -------
      Column({ space: 0 }) {
        this.statusBar()
        Row({ space: 10 }) {
          TextArea({
            text: this.inputText,
            placeholder: '输入消息…'
          })
            .fontSize(15)
            .fontColor(COLOR_TEXT)
            .placeholderColor(COLOR_TEXT_3)
            .backgroundColor(COLOR_SURFACE)
            .borderRadius(18)
            .border({ width: 1, color: COLOR_BORDER })
            .padding({ left: 15, right: 15, top: 11, bottom: 11 })
            .maxLines(5)
            .constraintSize({ minHeight: 46, maxHeight: 132 })
            .layoutWeight(1)
            .enterKeyType(EnterKeyType.Send)
            .onChange((v: string) => {
              this.inputText = v;
            })
            .onSubmit((): boolean => {
              this.sendNow();
              return true;
            })

          if (ENGINE.isRunning(this.currentId)) {
            Column() {
              IconStop('#FFFFFF', 19)
            }
            .width(46).height(46)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .borderRadius(23)
            .linearGradient({ angle: 135, colors: [[COLOR_ERR, 0], ['#E86A64', 1]] })
            .onClick(() => {
              this.stopNow();
            })
          } else {
            Column() {
              IconSend('#FFFFFF', 21)
            }
            .width(46).height(46)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .borderRadius(23)
            .linearGradient({ angle: 135, colors: [[GRAD_PRIMARY[0], 0], [GRAD_PRIMARY[1], 1]] })
            .opacity(this.inputText.trim().length > 0 ? 1 : 0.45)
            .onClick(() => {
              this.sendNow();
            })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 8, bottom: 16 })
      .backgroundColor('#F8F8FB')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F4F4F7')

      // ------- overlays: conversation list / model options / api settings -------
      if (this.showSessions) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(18,18,28,0.4)')
          .onClick(() => {
            this.showSessions = false;
          })
        Column() {
          this.sessionsSheet()
        }
        .width('100%')
        .height('82%')
        .align(Alignment.Bottom)
        .backgroundColor('#F8F8FB')
        .borderRadius({ topLeft: 20, topRight: 20 })
        .clip(true)
      }

      if (this.showModel) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(18,18,28,0.4)')
          .onClick(() => {
            this.showModel = false;
          })
        Column() {
          this.modelSheet()
        }
        .width('100%')
        .height('88%')
        .align(Alignment.Bottom)
        .backgroundColor('#F8F8FB')
        .borderRadius({ topLeft: 20, topRight: 20 })
        .clip(true)
      }

      if (this.showSettings) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(18,18,28,0.4)')
          .onClick(() => {
            this.showSettings = false;
          })
        Column() {
          this.settingsSheet()
        }
        .width('100%')
        .height('88%')
        .align(Alignment.Bottom)
        .backgroundColor('#F8F8FB')
        .borderRadius({ topLeft: 20, topRight: 20 })
        .clip(true)
      }
    }
    .width('100%')
    .height('100%')
  }
}
