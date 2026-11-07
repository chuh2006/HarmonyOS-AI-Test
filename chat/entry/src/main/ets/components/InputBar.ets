import { AppStore } from '../viewmodel/AppStore';
import { Theme } from '../common/Theme';
import { AppIcon } from '../common/AppIcon';

@ComponentV2
export struct InputBar {
  @Param store: AppStore = AppStore.getInstance();
  @Event onOptions: () => void = () => {};
  @Local text: string = '';

  private canSend(): boolean {
    return this.text.trim().length > 0 && !this.store.generating;
  }

  private send(): void {
    if (!this.canSend()) {
      return;
    }
    const t = this.text;
    this.text = '';
    this.store.send(t);
  }

  build() {
    Row() {
      Row() {
        AppIcon({ name: 'sliders', iconSize: 19, color: Theme.ink2 })
      }
      .width(38)
      .height(38)
      .borderRadius(19)
      .justifyContent(FlexAlign.Center)
      .onClick(() => this.onOptions())

      TextArea({ text: this.text, placeholder: '输入消息…' })
        .fontSize(16)
        .fontColor(Theme.ink)
        .placeholderColor(Theme.ink3)
        .placeholderFont({ size: 16 })
        .backgroundColor(Color.Transparent)
        .padding({ left: 4, right: 4, top: 8, bottom: 8 })
        .constraintSize({ minHeight: 40, maxHeight: 110 })
        .layoutWeight(1)
        .enterKeyType(EnterKeyType.Send)
        .onChange((value: string) => {
          this.text = value;
        })
        .onSubmit(() => {
          this.send();
        })

      Row() {
        AppIcon({
          name: this.store.generating ? 'stop' : 'send',
          iconSize: 18,
          color: this.store.generating || this.canSend() ? '#FFFFFF' : Theme.ink3
        })
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .backgroundColor(this.store.generating ? Theme.accentDeep : (this.canSend() ? Theme.accent : Theme.accentSoft))
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        if (this.store.generating) {
          this.store.stopGeneration();
        } else {
          this.send();
        }
      })
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 5, bottom: 5 })
    .backgroundColor(Theme.surface)
    .borderRadius(24)
    .border({ width: 1, color: Theme.line })
    .shadow({ radius: 12, color: 'rgba(0,0,0,0.05)', offsetY: 3 })
    .alignItems(VerticalAlign.Bottom)
  }
}