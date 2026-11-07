import { common } from '@kit.AbilityKit';
import { Archive, defaultProviders, MODELS, ModelSpec, modelSpec, normalizeOptions, Options, ProviderConfig, Session, Turn } from '../core/Models';
import { safeError } from '../core/Json';
import { Store, Vault } from '../services/Store';
import { ChatEngine } from '../services/ChatEngine';
import { validateBaseUrl } from '../services/Network';
import { TurnView } from '../components/TurnView';

@Entry
@Component
struct Index {
  @State current: Session = new Session();
  @State sessions: Session[] = [];
  @State input: string = '';
  @State busy: boolean = false;
  @State ready: boolean = false;
  @State banner: string = '';
  @State showSheet: boolean = false;
  @State sheet: string = 'history';
  @State draftOptions: Options = new Options();
  @State selectedProvider: string = 'deepseek';
  @State draftKey: string = '';
  @State draftUrl: string = 'https://api.deepseek.com/anthropic';
  @State settingsBusy: boolean = false;
  @State settingsError: string = '';
  @State configured: string[] = [];
  @State follow: boolean = true;
  private archive: Archive = new Archive();
  private store?: Store;
  private vault: Vault = new Vault();
  private engine?: ChatEngine;
  private scroller: Scroller = new Scroller();
  private saveTimer: number = 0;
  private renderTimer: number = 0;
  private storeFailed: boolean = false;
  private settingsGeneration: number = 0;

  aboutToAppear(): void { this.initialize(); }
  aboutToDisappear(): void {
    this.engine?.stopAll(); this.persist(true); clearTimeout(this.saveTimer); clearTimeout(this.renderTimer);
  }
  onPageHide(): void { this.persist(true); }
  private initialize(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.store = new Store(context.filesDir); this.archive = this.store.load();
      this.banner = this.store.recoveryNotice;
      if (this.archive.sessions.length === 0) { const s = new Session(); this.archive.sessions.push(s); this.archive.active = s.id; }
      if (!this.archive.sessions.some((s: Session) => s.id === this.archive.active)) { this.archive.active = this.archive.sessions[0].id; }
      this.engine = new ChatEngine(() => this.scheduleRefresh(), (immediate: boolean) => this.persist(immediate));
      this.ready = true; this.refresh(); this.loadConfigured();
    } catch (error) { this.banner = safeError(error as Error); this.storeFailed = true; }
  }
  private async loadConfigured(): Promise<void> {
    const available: string[] = [];
    for (const provider of defaultProviders()) {
      try { if ((await this.vault.read(provider.id)).length > 0) { available.push(provider.id); } }
      catch (error) { this.banner = safeError(error as Error); }
    }
    this.configured = available;
  }
  private source(): Session { return this.archive.sessions.find((s: Session) => s.id === this.archive.active) || this.archive.sessions[0]; }
  private persist(immediate: boolean): void {
    if (!this.ready || !this.store || this.storeFailed) { return; }
    if (!immediate) {
      if (this.saveTimer === 0) { this.saveTimer = setTimeout(() => { this.saveTimer = 0; this.persist(true); }, 750); }
      return;
    }
    clearTimeout(this.saveTimer); this.saveTimer = 0;
    try { this.store.save(this.archive); }
    catch (_) { this.banner = '历史保存失败，请检查存储空间；当前对话保留在本次运行中'; }
  }
  private scheduleRefresh(): void {
    if (this.renderTimer !== 0) { return; }
    this.renderTimer = setTimeout(() => { this.renderTimer = 0; this.refresh(); }, 40);
  }
  private refresh(): void {
    if (!this.ready) { return; }
    this.current = JSON.parse(JSON.stringify(this.source())) as Session;
    this.sessions = this.archive.sessions.slice().sort((a: Session, b: Session) => b.updated - a.updated);
    this.busy = this.engine?.busy(this.source()) || false;
    if (this.follow && this.current.turns.length > 0) { setTimeout(() => { this.scroller.scrollEdge(Edge.Bottom); }, 40); }
  }
  private newSession(options?: Options): void {
    const session = new Session();
    session.options = JSON.parse(JSON.stringify(options || this.current.options)) as Options;
    this.archive.sessions.push(session); this.archive.active = session.id; this.input = ''; this.follow = true;
    this.showSheet = false; this.refresh(); this.persist(true);
  }
  private activate(id: string): void {
    this.archive.active = id; this.input = ''; this.follow = true; this.showSheet = false; this.refresh(); this.persist(true);
  }
  private remove(id: string): void {
    this.getUIContext().getPromptAction().showDialog({ title: '删除这段对话？', message: '删除后将无法恢复。',
      buttons: [{ text: '取消', color: '#617268' }, { text: '删除', color: '#A65B40' }]
    }).then((result) => {
      if (result.index !== 1) { return; }
      const session = this.archive.sessions.find((s: Session) => s.id === id);
      if (session) { this.engine?.stop(session); }
      this.archive.sessions = this.archive.sessions.filter((s: Session) => s.id !== id);
      if (this.archive.sessions.length === 0) { this.newSession(); }
      else if (this.archive.active === id) { this.activate(this.archive.sessions[0].id); }
      this.refresh(); this.persist(true);
    }).catch(() => {});
  }
  private send(): void {
    if (!this.ready || this.busy || !this.input.trim()) { return; }
    const value = this.input; this.input = ''; this.follow = true;
    this.engine?.send(this.archive, this.source(), value); this.refresh();
  }
  private retry(): void { this.follow = true; this.engine?.send(this.archive, this.source(), '', true); this.refresh(); }
  private openModels(): void { this.draftOptions = JSON.parse(JSON.stringify(this.current.options)) as Options; this.sheet = 'models'; this.showSheet = true; }
  private chooseModel(model: ModelSpec): void {
    const options = JSON.parse(JSON.stringify(this.draftOptions)) as Options;
    options.model = model.id; this.draftOptions = normalizeOptions(options);
  }
  private setOption(field: string, value: string): void {
    const options = JSON.parse(JSON.stringify(this.draftOptions)) as Options;
    if (field === 'effort') { options.effort = value; }
    else if (field === 'mode') { options.mode = value; }
    else { options.tier = value; }
    this.draftOptions = options;
  }
  private applyModels(): void {
    this.draftOptions = normalizeOptions(this.draftOptions);
    this.showSheet = false;
    if (this.current.options.model !== this.draftOptions.model && this.current.turns.length > 0) { this.newSession(this.draftOptions); }
    else { this.source().options = this.draftOptions; this.refresh(); this.persist(true); }
  }
  private async openProvider(id: string): Promise<void> {
    const generation = ++this.settingsGeneration;
    this.selectedProvider = id; this.draftKey = ''; this.settingsError = ''; this.settingsBusy = true;
    this.draftUrl = this.archive.providers.find((p: ProviderConfig) => p.id === id)?.baseUrl || '';
    try { const key = await this.vault.read(id); if (generation === this.settingsGeneration) { this.draftKey = key; } }
    catch (error) { if (generation === this.settingsGeneration) { this.settingsError = safeError(error as Error); } }
    finally { if (generation === this.settingsGeneration) { this.settingsBusy = false; } }
  }
  private openSettings(): void { this.sheet = 'settings'; this.showSheet = true; this.openProvider(modelSpec(this.current.options.model).provider); }
  private async saveSettings(): Promise<void> {
    if (this.settingsBusy) { return; }
    this.settingsBusy = true; this.settingsError = '';
    const provider = this.selectedProvider; const generation = this.settingsGeneration;
    try {
      const url = validateBaseUrl(this.draftUrl); const key = this.draftKey.trim();
      if (/[\r\n]/.test(key)) { throw new Error('密钥中包含换行，请检查后重试'); }
      await this.vault.write(provider, key);
      const config = this.archive.providers.find((p: ProviderConfig) => p.id === provider);
      if (config) { config.baseUrl = url; }
      this.store?.save(this.archive);
      this.configured = this.configured.filter((id: string) => id !== provider);
      if (key) { this.configured = this.configured.concat(provider); }
      if (generation === this.settingsGeneration) { this.draftKey = ''; this.showSheet = false; }
      this.getUIContext().getPromptAction().showToast({ message: '服务设置已保存' });
    } catch (error) { if (generation === this.settingsGeneration) { this.settingsError = safeError(error as Error, [this.draftKey]); } }
    finally { if (generation === this.settingsGeneration) { this.settingsBusy = false; } }
  }

  @Builder
  header() {
    Row() {
      Button('☰', { type: ButtonType.Normal }).fontSize(20).fontColor('#486451').backgroundColor(Color.Transparent)
        .width(44).height(44).padding(0).enabled(this.ready).onClick(() => { this.sheet = 'history'; this.showSheet = true; }).accessibilityText('历史对话').id('historyButton')
      Blank()
      Column({ space: 2 }) {
        Text('MiniChat').fontFamily('serif').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#284B3A')
        Text(modelSpec(this.current.options.model).name + '  ⌄').fontSize(11).fontColor('#829180')
      }.onClick(() => this.openModels()).accessibilityText('选择模型').id('modelButton')
      Blank()
      Button('+', { type: ButtonType.Normal }).fontSize(27).fontColor('#486451').backgroundColor(Color.Transparent)
        .width(44).height(44).padding(0).enabled(this.ready).onClick(() => this.newSession()).accessibilityText('新建对话').id('newChatButton')
    }.width('100%').height(68).padding({ left: 12, right: 12 })
  }
  @Builder
  suggestion(icon: string, title: string, prompt: string) {
    Row({ space: 12 }) {
      Text(icon).fontSize(18).fontColor('#7C8D64').width(24)
      Text(title).fontSize(14).fontColor('#56674D').layoutWeight(1)
      Text('↗').fontSize(15).fontColor('#A4AF98')
    }.width('100%').padding(17).borderRadius(16).border({ width: 1, color: '#E1E6D9' })
      .backgroundColor('#FAFBF5').onClick(() => this.input = prompt)
  }
  @Builder
  welcome() {
    Column({ space: 20 }) {
      Stack() {
        Circle().width(94).height(94).fill('#E8EDE1')
        Text('m').fontFamily('serif').fontSize(58).fontColor('#3B6046').margin({ bottom: 8 })
        Text('✦').fontSize(20).fontColor('#95A66E').translate({ x: 37, y: -32 })
      }.margin({ top: 36, bottom: 10 })
      Text('给想法一点空间').fontSize(27).fontWeight(FontWeight.Medium).fontColor('#2C4435')
      Text('一个问题，一次灵感。\n从你正在想的事情开始。').fontSize(14).fontColor('#84907E').lineHeight(24).textAlign(TextAlign.Center)
      Column({ space: 10 }) {
        this.suggestion('✧', '想清楚一件事', '帮我把一个复杂问题拆成几个容易理解的步骤。')
        this.suggestion('↗', '发现新的视角', '给我三个适合周末尝试的新鲜创意。')
        this.suggestion('⌘', '一起写点代码', '请用简单的例子解释异步编程。')
      }.width('100%').margin({ top: 16 })
      if (!this.configured.includes(modelSpec(this.current.options.model).provider)) {
        Button('连接服务  →', { type: ButtonType.Normal }).fontSize(13).fontColor('#3C7055')
          .backgroundColor(Color.Transparent).onClick(() => this.openSettings()).id('connectButton')
      }
    }.width('100%').padding({ left: 12, right: 12, bottom: 24 })
  }
  @Builder
  composer() {
    Column({ space: 8 }) {
      if (!this.follow && this.busy) {
        Button('↓ 回到最新消息').fontSize(12).height(30).fontColor('#3B7056').backgroundColor('#E5ECDF')
          .onClick(() => { this.follow = true; this.scroller.scrollEdge(Edge.Bottom); })
      }
      Column({ space: 6 }) {
        TextArea({ placeholder: '写下你的问题…', text: this.input }).fontSize(16).fontColor('#294331')
          .placeholderColor('#A0AA99').backgroundColor(Color.Transparent).constraintSize({ minHeight: 48, maxHeight: 140 }).maxLines(5)
          .padding({ top: 12, left: 12, right: 12, bottom: 3 }).onChange((value: string) => this.input = value)
          .enabled(this.ready).id('messageInput').accessibilityText('消息输入框')
        Row({ space: 4 }) {
          Button(this.current.options.tools ? '◎ 联网' : '◎ 联网已关', { type: ButtonType.Normal })
            .fontSize(12).height(32).fontColor(this.current.options.tools ? '#366F50' : '#8A9685')
            .backgroundColor(this.current.options.tools ? '#ECF2E7' : Color.Transparent).borderRadius(10)
            .onClick(() => { this.source().options.tools = !this.source().options.tools; this.refresh(); this.persist(true); })
            .enabled(this.ready).id('toolsToggle')
          Button('调节', { type: ButtonType.Normal }).fontSize(12).fontColor('#88937D').backgroundColor(Color.Transparent)
            .height(32).onClick(() => this.openModels()).enabled(this.ready)
          Blank()
          Button(this.busy ? '■' : '↑', { type: ButtonType.Circle }).width(39).height(39).fontSize(this.busy ? 15 : 24)
            .fontColor('#FFFFFF').backgroundColor(this.busy || this.input.trim().length > 0 ? '#315F43' : '#B7C2AC')
            .enabled(this.ready && (this.busy || this.input.trim().length > 0))
            .onClick(() => { if (this.busy) { this.engine?.stop(this.source()); this.refresh(); } else { this.send(); } })
            .accessibilityText(this.busy ? '停止生成' : '发送消息').id('sendButton')
        }.width('100%').padding({ left: 9, right: 9, bottom: 8 })
      }.width('100%').backgroundColor('#FFFFFF').borderRadius(24).border({ width: 1, color: '#E0E5D8' })
      Row() {
        Text('留一点好奇，给每一次对话').fontSize(10).fontColor('#A0AB96')
        Blank()
        Text('服务设置').fontSize(11).fontColor('#819178').onClick(() => this.openSettings()).id('settingsButton')
      }.width('100%').padding({ left: 8, right: 8 })
    }.width('100%').padding({ left: 18, right: 18, top: 8, bottom: 12 }).backgroundColor('#F6F7EF')
  }
  @Builder
  historySheet() {
    Column({ space: 18 }) {
      Row() {
        Text('你的对话').fontSize(25).fontWeight(FontWeight.Medium).fontColor('#2B4938')
        Blank()
        Button('＋ 新对话').fontSize(13).height(36).fontColor('#FFFFFF').backgroundColor('#315F43').onClick(() => this.newSession())
      }.width('100%')
      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.sessions, (session: Session) => {
            Row({ space: 12 }) {
              Column({ space: 7 }) {
                Text(session.title).fontSize(15).fontColor('#334B3B').maxLines(2)
                Text(modelSpec(session.options.model).name + ' · ' + session.turns.length + ' 轮对话').fontSize(11).fontColor('#87927E')
              }.layoutWeight(1).alignItems(HorizontalAlign.Start).onClick(() => this.activate(session.id))
              Button('删除', { type: ButtonType.Normal }).fontSize(11).fontColor('#9A8E7A').backgroundColor(Color.Transparent)
                .height(36).onClick(() => this.remove(session.id))
            }.padding(16).width('100%').borderRadius(16).backgroundColor(session.id === this.current.id ? '#E9EFDF' : '#FFFFFF')
          }, (session: Session) => session.id)
        }.width('100%')
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }.width('100%').height('100%').padding(24).backgroundColor('#F6F7EF')
  }
  @Builder
  modelSheet() {
    Column({ space: 16 }) {
      Row() {
        Text('这次，如何思考').fontSize(23).fontWeight(FontWeight.Medium).fontColor('#2B4938')
        Blank()
        Button('取消').height(34).fontSize(12).fontColor('#7E8C72').backgroundColor(Color.Transparent).onClick(() => this.showSheet = false)
        Button('完成').height(34).fontSize(13).backgroundColor('#315F43').onClick(() => this.applyModels()).id('applyModelButton')
      }.width('100%')
      Scroll() {
        Column({ space: 18 }) {
          Column({ space: 6 }) {
            ForEach(MODELS, (model: ModelSpec) => {
              Row() {
                Text(model.name).fontSize(14).fontColor('#3D513D').layoutWeight(1)
                Text(this.draftOptions.model === model.id ? '●' : '○').fontColor(this.draftOptions.model === model.id ? '#3D7652' : '#C2CBB9')
              }.width('100%').padding(13).borderRadius(12).backgroundColor(this.draftOptions.model === model.id ? '#E8EEDD' : '#FFFFFF')
                .onClick(() => this.chooseModel(model)).id('model_' + model.id)
            }, (model: ModelSpec) => model.id)
          }.width('100%')
          Text('思考强度').fontSize(13).fontColor('#7E8C72').width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(modelSpec(this.draftOptions.model).efforts, (value: string) => {
                Button(value === 'none' ? '关闭' : value === 'standard' ? '标准' : value, { type: ButtonType.Normal })
                  .fontSize(12).height(34).borderRadius(10).fontColor(this.draftOptions.effort === value ? '#FFFFFF' : '#69805C')
                  .backgroundColor(this.draftOptions.effort === value ? '#527344' : '#EAF0E1').margin({ right: 8, bottom: 8 })
                  .onClick(() => this.setOption('effort', value))
              }, (value: string) => value)
            }.width('100%')
          if (modelSpec(this.draftOptions.model).provider === 'openai') {
            Text('推理模式').fontSize(13).fontColor('#7E8C72').width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(['standard', 'pro'], (value: string) => {
                Button(value === 'none' ? '关闭' : value === 'standard' ? '标准' : value, { type: ButtonType.Normal })
                  .fontSize(12).height(34).borderRadius(10).fontColor(this.draftOptions.mode === value ? '#FFFFFF' : '#69805C')
                  .backgroundColor(this.draftOptions.mode === value ? '#527344' : '#EAF0E1').margin({ right: 8, bottom: 8 })
                  .onClick(() => this.setOption('mode', value))
              }, (value: string) => value)
            }.width('100%')
            Text('响应速度').fontSize(13).fontColor('#7E8C72').width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(modelSpec(this.draftOptions.model).tiers, (value: string) => {
                Button(value === 'none' ? '关闭' : value === 'standard' ? '标准' : value, { type: ButtonType.Normal })
                  .fontSize(12).height(34).borderRadius(10).fontColor(this.draftOptions.tier === value ? '#FFFFFF' : '#69805C')
                  .backgroundColor(this.draftOptions.tier === value ? '#527344' : '#EAF0E1').margin({ right: 8, bottom: 8 })
                  .onClick(() => this.setOption('tier', value))
              }, (value: string) => value)
            }.width('100%')
            Text('Pro 会增加推理用量；加速模式按服务商对应费率计费。').fontSize(11).fontColor('#99A18D').width('100%').lineHeight(18)
          }
          if (modelSpec(this.draftOptions.model).provider === 'mercury') {
            Row() {
              Column({ space: 5 }) {
                Text('扩散输出').fontSize(14).fontColor('#3D513D')
                Text('观看文字逐步修订成形').fontSize(11).fontColor('#87927E')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.draftOptions.diffusing }).selectedColor('#527344')
                .onChange((value: boolean) => { const o = JSON.parse(JSON.stringify(this.draftOptions)) as Options; o.diffusing = value; this.draftOptions = o; })
            }.width('100%')
          }
          if (this.current.turns.length > 0 && this.current.options.model !== this.draftOptions.model) {
            Text('切换模型将开启一段新对话。').fontSize(12).fontColor('#8D977D').width('100%')
          }
        }.width('100%').padding({ bottom: 24 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }.width('100%').height('100%').padding(24).backgroundColor('#F6F7EF')
  }
  @Builder
  settingsSheet() {
    Column({ space: 20 }) {
      Text('连接你的 AI').fontSize(25).fontWeight(FontWeight.Medium).fontColor('#2B4938').width('100%')
      Text('密钥安全保存在这台设备上。').fontSize(13).fontColor('#8D977D').width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(defaultProviders(), (provider: ProviderConfig) => {
          Button(provider.name, { type: ButtonType.Normal }).height(36).fontSize(12).borderRadius(12)
            .backgroundColor(this.selectedProvider === provider.id ? '#527344' : '#EAF0E1')
            .fontColor(this.selectedProvider === provider.id ? '#FFFFFF' : '#69805C').margin({ right: 8, bottom: 8 })
            .enabled(!this.settingsBusy).onClick(() => this.openProvider(provider.id)).id('provider_' + provider.id)
        })
      }.width('100%')
      Scroll() {
        Column({ space: 12 }) {
          Text('API Key').fontSize(13).fontColor('#6F8063').width('100%')
          TextInput({ text: this.draftKey, placeholder: '填写你的密钥' }).type(InputType.Password).height(50).borderRadius(14)
            .backgroundColor('#FFFFFF').fontSize(14).onChange((value: string) => this.draftKey = value).enabled(!this.settingsBusy).id('apiKeyInput')
          Text('Base URL').fontSize(13).fontColor('#6F8063').width('100%').margin({ top: 8 })
          TextInput({ text: this.draftUrl, placeholder: 'https://' }).height(50).borderRadius(14).backgroundColor('#FFFFFF')
            .fontSize(13).onChange((value: string) => this.draftUrl = value).enabled(!this.settingsBusy).id('baseUrlInput')
          Text('联网搜索和网页读取使用 DeepSeek 密钥。清空密钥并保存即可移除。').fontSize(12).fontColor('#929D86').lineHeight(20).width('100%')
          if (this.settingsError) { Text(this.settingsError).fontSize(13).fontColor('#A65B40').width('100%').lineHeight(20) }
          Button(this.settingsBusy ? '正在处理…' : '保存设置').width('100%').height(48).borderRadius(16).backgroundColor('#315F43')
            .fontSize(15).enabled(!this.settingsBusy).onClick(() => this.saveSettings()).margin({ top: 14 }).id('saveSettingsButton')
        }.width('100%').padding({ bottom: 24 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
    }.width('100%').height('100%').padding(24).backgroundColor('#F6F7EF')
  }
  @Builder
  activeSheet() {
    if (this.sheet === 'history') { this.historySheet() }
    else if (this.sheet === 'models') { this.modelSheet() }
    else { this.settingsSheet() }
  }
  build() {
    Column() {
      this.header()
      if (this.banner) {
        Text(this.banner).fontSize(12).lineHeight(18).fontColor('#A17B50').width('100%').padding({ left: 22, right: 22, bottom: 8 })
      }
      Scroll(this.scroller) {
        Column() {
          if (this.current.turns.length === 0) { this.welcome() }
          else {
            ForEach(this.current.turns, (turn: Turn, index: number) => {
              TurnView({ turn: this.current.turns[index], last: index === this.current.turns.length - 1, onRetry: () => this.retry() })
            }, (turn: Turn) => turn.id)
          }
        }.width('100%').padding({ left: 22, right: 22 })
      }.layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
        .onScrollFrameBegin((offset: number, state: ScrollState) => {
          if (state !== ScrollState.Idle && offset < 0) { this.follow = false; }
          return { offsetRemain: offset };
        }).onReachEnd(() => this.follow = true)
      this.composer()
    }.height('100%').width('100%').backgroundColor('#F6F7EF')
      .bindSheet($$this.showSheet, this.activeSheet(), { height: '90%', showClose: false, backgroundColor: '#F6F7EF',
        onDisappear: () => { this.draftKey = ''; this.settingsGeneration++; } })
  }
}
