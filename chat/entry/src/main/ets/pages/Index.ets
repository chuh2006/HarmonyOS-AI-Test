import { common } from '@kit.AbilityKit';
import { KeyboardAvoidMode } from '@kit.ArkUI';
import { AppStore } from '../viewmodel/AppStore';
import { ChatMessage } from '../model/Types';
import { modelInfo, providerInfo } from '../model/Catalog';
import { Theme } from '../common/Theme';
import { AppIcon } from '../common/AppIcon';
import { MessageView } from '../components/MessageView';
import { InputBar } from '../components/InputBar';
import { SessionDrawer } from '../components/SessionDrawer';
import { SettingsSheet, ModelPickerSheet, OptionsSheet } from '../components/Sheets';

const SUGGESTIONS: string[] = [
  '搜索今天 AI 领域的重要新闻',
  '解释一下扩散语言模型的工作原理',
  '帮我写一封简洁的会议邀请邮件'
];

@Entry
@ComponentV2
struct Index {
  @Local store: AppStore = AppStore.getInstance();
  @Local showDrawer: boolean = false;
  @Local sheet: string = '';
  @Local autoScroll: boolean = true;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.store.init(getContext(this) as common.UIAbilityContext);
  }

  @Monitor('store.scrollTick')
  onScrollTick(): void {
    if (this.autoScroll) {
      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 60);
    }
  }

  @Builder
  sheetBuilder() {
    if (this.sheet === 'settings') {
      SettingsSheet({
        store: this.store,
        onClose: () => {
          this.sheet = '';
        }
      })
    } else if (this.sheet === 'models') {
      ModelPickerSheet({
        store: this.store,
        onClose: () => {
          this.sheet = '';
        }
      })
    } else if (this.sheet === 'options') {
      OptionsSheet({
        store: this.store,
        onClose: () => {
          this.sheet = '';
        }
      })
    }
  }

  @Builder
  emptyState() {
    Column() {
      Row() {
        AppIcon({ name: 'sparkle', iconSize: 26, color: '#FFFFFF' })
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .linearGradient({ angle: 135, colors: [[Theme.accent, 0], ['#8B5CF6', 1]] })
      .justifyContent(FlexAlign.Center)
      .shadow({ radius: 18, color: 'rgba(88,87,214,0.3)', offsetY: 6 })

      Text('有什么可以帮你？')
        .fontSize(21)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.ink)
        .margin({ top: 20 })

      if (this.store.current() !== null && !this.store.settings.hasKey(this.store.current()!.provider)) {
        Column() {
          AppIcon({ name: 'key', iconSize: 22, color: Theme.accent })
          Text(`配置 ${providerInfo(this.store.current()!.provider).label} API Key 开始对话`)
            .fontSize(14)
            .fontColor(Theme.ink2)
            .margin({ top: 10 })
          Button('去设置')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor(Theme.accent)
            .height(38)
            .padding({ left: 26, right: 26 })
            .margin({ top: 14 })
            .onClick(() => {
              this.sheet = 'settings';
            })
        }
        .padding(24)
        .margin({ top: 28 })
        .backgroundColor(Theme.surface)
        .borderRadius(18)
        .border({ width: 1, color: Theme.line })
      } else {
        Column({ space: 10 }) {
          ForEach(SUGGESTIONS, (s: string) => {
            Row() {
              Text(s)
                .fontSize(14)
                .fontColor(Theme.ink2)
                .layoutWeight(1)
              AppIcon({ name: 'send', iconSize: 14, color: Theme.ink3 })
            }
            .width('100%')
            .padding({ left: 16, right: 14, top: 13, bottom: 13 })
            .backgroundColor(Theme.surface)
            .borderRadius(14)
            .border({ width: 1, color: Theme.line })
            .onClick(() => {
              this.autoScroll = true;
              this.store.send(s);
            })
          }, (s: string) => s)
        }
        .width('100%')
        .constraintSize({ maxWidth: 360 })
        .margin({ top: 30 })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 28, right: 28, bottom: 40 })
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Column() {
        Row() {
          Row() {
            AppIcon({ name: 'menu', iconSize: 20, color: Theme.ink })
          }
          .width(40)
          .height(40)
          .borderRadius(20)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.showDrawer = true;
          })

          Column() {
            Text('MiniChat')
              .fontSize(15.5)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.ink)
            Row() {
              Text(this.store.current() !== null ? modelInfo(this.store.current()!.model).label : '')
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.ink2)
              AppIcon({ name: 'chevron', iconSize: 10, color: Theme.ink3 })
                .margin({ left: 3 })
              if (this.store.current() !== null && !this.store.settings.hasKey(this.store.current()!.provider)) {
                Circle({ width: 5, height: 5 })
                  .fill('#E8A33D')
                  .margin({ left: 5 })
              }
            }
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
            .borderRadius(11)
            .backgroundColor(Theme.surface)
            .border({ width: 1, color: Theme.line })
            .margin({ top: 3 })
            .onClick(() => {
              this.sheet = 'models';
            })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)

          Row() {
            AppIcon({ name: 'plus', iconSize: 20, color: Theme.ink })
          }
          .width(40)
          .height(40)
          .borderRadius(20)
          .justifyContent(FlexAlign.Center)
          .onClick(() => {
            this.autoScroll = true;
            this.store.newChat();
          })
        }
        .width('100%')
        .height(58)
        .padding({ left: 8, right: 8 })

        if (!this.store.ready) {
          Column() {
            LoadingProgress().width(30).height(30).color(Theme.accent)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.store.current() === null || this.store.current()!.messages.length === 0) {
          this.emptyState()
        } else {
          List({ scroller: this.scroller }) {
            ForEach(this.store.current()!.messages, (msg: ChatMessage, index: number) => {
              ListItem() {
                MessageView({
                  msg: msg,
                  modelLabel: modelInfo(this.store.current()!.model).label,
                  active: this.store.generating && index === this.store.current()!.messages.length - 1,
                  onRetry: () => {
                    this.autoScroll = true;
                    this.store.retry();
                  },
                  onSetup: () => {
                    this.sheet = 'settings';
                  }
                })
              }
              .padding({ bottom: 22 })
            }, (msg: ChatMessage) => msg.id)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 16, right: 16, top: 14 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Move) {
              this.autoScroll = false;
            }
          })
          .onAppear(() => {
            this.scroller.scrollEdge(Edge.Bottom);
          })
        }

        Column() {
          InputBar({
            store: this.store,
            onOptions: () => {
              this.sheet = 'options';
            }
          })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 12 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.bg)

      if (this.showDrawer) {
        SessionDrawer({
          store: this.store,
          onClose: () => {
            this.showDrawer = false;
          },
          onSettings: () => {
            this.showDrawer = false;
            this.sheet = 'settings';
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.sheet.length > 0, this.sheetBuilder(), {
      height: this.sheet === 'settings' ? SheetSize.LARGE : SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: Theme.bg,
      onDisappear: () => {
        this.sheet = '';
        this.store.saveCurrent();
      }
    })
  }
}