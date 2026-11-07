import { promptAction } from '@kit.ArkUI';
import { AppStore } from '../viewmodel/AppStore';
import { ProviderId, ChatOptions } from '../model/Types';
import { PROVIDERS, ProviderInfo, ModelInfo, modelsOf, modelInfo, effortLabel, providerInfo } from '../model/Catalog';
import { Theme } from '../common/Theme';
import { AppIcon } from '../common/AppIcon';

@ComponentV2
struct Chip {
  @Param label: string = '';
  @Param selected: boolean = false;
  @Event onTap: () => void = () => {};

  build() {
    Text(this.label)
      .fontSize(13)
      .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.selected ? Color.White : Theme.ink2)
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .backgroundColor(this.selected ? Theme.accent : Theme.surface)
      .borderRadius(16)
      .border({ width: 1, color: this.selected ? Theme.accent : Theme.line })
      .onClick(() => this.onTap())
  }
}

@ComponentV2
struct SectionTitle {
  @Param title: string = '';

  build() {
    Text(this.title)
      .fontSize(12.5)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.ink3)
      .margin({ top: 18, bottom: 8 })
  }
}

@ComponentV2
export struct SettingsSheet {
  @Param store: AppStore = AppStore.getInstance();
  @Event onClose: () => void = () => {};
  @Local provider: ProviderId = ProviderId.DEEPSEEK;
  @Local keyText: string = '';
  @Local urlText: string = '';
  @Local showKey: boolean = false;
  @Local loading: boolean = false;

  aboutToAppear(): void {
    const cur = this.store.current();
    if (cur !== null) {
      this.provider = cur.provider;
    }
    this.load();
  }

  private async load(): Promise<void> {
    this.loading = true;
    this.keyText = await this.store.settings.getKey(this.provider);
    this.urlText = this.store.settings.getBaseUrl(this.provider);
    this.showKey = false;
    this.loading = false;
  }

  private async save(): Promise<void> {
    try {
      await this.store.settings.setKey(this.provider, this.keyText);
      await this.store.settings.setBaseUrl(this.provider, this.urlText);
      promptAction.showToast({ message: '已保存', duration: 1200 });
    } catch (e) {
      promptAction.showToast({ message: '保存失败，请重试', duration: 1500 });
    }
  }

  build() {
    Column() {
      Row() {
        Text('设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.ink)
        Blank()
        Row() {
          AppIcon({ name: 'close', iconSize: 18, color: Theme.ink2 })
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .backgroundColor(Theme.bg)
        .justifyContent(FlexAlign.Center)
        .onClick(() => this.onClose())
      }
      .width('100%')
      .margin({ bottom: 16 })

      Row({ space: 8 }) {
        ForEach(PROVIDERS, (p: ProviderInfo) => {
          Row() {
            Text(p.label)
              .fontSize(13)
              .fontWeight(this.provider === p.id ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.provider === p.id ? Color.White : Theme.ink2)
            if (this.store.settings.hasKey(p.id)) {
              Circle({ width: 5, height: 5 })
                .fill(this.provider === p.id ? Color.White : Theme.ok)
                .margin({ left: 5 })
            }
          }
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(this.provider === p.id ? Theme.accent : Theme.surface)
          .borderRadius(16)
          .border({ width: 1, color: this.provider === p.id ? Theme.accent : Theme.line })
          .onClick(() => {
            this.provider = p.id;
            this.load();
          })
        }, (p: ProviderInfo) => p.id as string)
      }

      Scroll() {
        Column() {
          SectionTitle({ title: 'API KEY' })
          Row() {
            TextInput({ text: this.keyText, placeholder: '粘贴 API Key' })
              .type(this.showKey ? InputType.Normal : InputType.Password)
              .fontSize(14)
              .fontColor(Theme.ink)
              .placeholderColor(Theme.ink3)
              .backgroundColor(Color.Transparent)
              .layoutWeight(1)
              .onChange((v: string) => {
                this.keyText = v;
              })
            Text(this.showKey ? '隐藏' : '显示')
              .fontSize(12)
              .fontColor(Theme.accent)
              .padding(6)
              .onClick(() => {
                this.showKey = !this.showKey;
              })
          }
          .width('100%')
          .backgroundColor(Theme.surface)
          .borderRadius(12)
          .border({ width: 1, color: Theme.line })
          .padding({ left: 8, right: 8 })

          SectionTitle({ title: 'BASE URL' })
          TextInput({ text: this.urlText, placeholder: providerInfo(this.provider).defaultBaseUrl })
            .fontSize(14)
            .fontColor(Theme.ink)
            .placeholderColor(Theme.ink3)
            .backgroundColor(Theme.surface)
            .borderRadius(12)
            .border({ width: 1, color: Theme.line })
            .onChange((v: string) => {
              this.urlText = v;
            })

          Button('保存')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor(Theme.accent)
            .width('100%')
            .height(44)
            .margin({ top: 22 })
            .onClick(() => {
              this.save();
            })

          Text('密钥仅保存在本机安全存储中，不会上传。网页搜索与抓取工具统一使用 DeepSeek 的 API Key；未配置时工具会自动降级。')
            .fontSize(12)
            .lineHeight(19)
            .fontColor(Theme.ink3)
            .margin({ top: 16 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 20 })
    .alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
export struct ModelPickerSheet {
  @Param store: AppStore = AppStore.getInstance();
  @Event onClose: () => void = () => {};

  build() {
    Column() {
      Row() {
        Text('选择模型')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.ink)
        Blank()
        Row() {
          AppIcon({ name: 'close', iconSize: 18, color: Theme.ink2 })
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .backgroundColor(Theme.bg)
        .justifyContent(FlexAlign.Center)
        .onClick(() => this.onClose())
      }
      .width('100%')
      .margin({ bottom: 6 })

      Scroll() {
        Column() {
          ForEach(PROVIDERS, (p: ProviderInfo) => {
            Column() {
              Row() {
                Text(p.label)
                  .fontSize(12.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.ink3)
                if (!this.store.settings.hasKey(p.id)) {
                  Text('未配置 Key')
                    .fontSize(11)
                    .fontColor(Theme.ink3)
                    .margin({ left: 8 })
                }
              }
              .width('100%')
              .margin({ top: 16, bottom: 6 })

              ForEach(modelsOf(p.id), (m: ModelInfo) => {
                Row() {
                  Column() {
                    Text(m.label)
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(Theme.ink)
                    Text(m.tagline)
                      .fontSize(12)
                      .fontColor(Theme.ink3)
                      .margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (this.store.current()?.model === m.id) {
                    AppIcon({ name: 'check', iconSize: 18, color: Theme.accent })
                  }
                }
                .width('100%')
                .padding({ left: 14, right: 14, top: 11, bottom: 11 })
                .backgroundColor(this.store.current()?.model === m.id ? Theme.accentSoft : Theme.surface)
                .borderRadius(14)
                .border({ width: 1, color: Theme.line })
                .margin({ bottom: 6 })
                .onClick(() => {
                  this.store.setModel(p.id, m.id);
                  this.onClose();
                })
              }, (m: ModelInfo) => m.id)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }, (p: ProviderInfo) => p.id as string)

          Text('切换服务商或模型将开始新会话，当前会话会保留在历史中。')
            .fontSize(12)
            .fontColor(Theme.ink3)
            .margin({ top: 10, bottom: 8 })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 20 })
    .alignItems(HorizontalAlign.Start)
  }
}

@ComponentV2
export struct OptionsSheet {
  @Param store: AppStore = AppStore.getInstance();
  @Event onClose: () => void = () => {};

  private options(): ChatOptions | null {
    return this.store.current()?.options ?? null;
  }

  build() {
    Column() {
      Row() {
        Text('模型选项')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.ink)
        Blank()
        Row() {
          AppIcon({ name: 'close', iconSize: 18, color: Theme.ink2 })
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .backgroundColor(Theme.bg)
        .justifyContent(FlexAlign.Center)
        .onClick(() => this.onClose())
      }
      .width('100%')
      .margin({ bottom: 4 })

      if (this.store.current() !== null) {
        Text(modelInfo(this.store.current()!.model).label)
          .fontSize(13)
          .fontColor(Theme.ink2)
          .margin({ bottom: 4 })
      }

      Scroll() {
        Column() {
          if (this.options() !== null && this.store.current() !== null) {
            if (this.store.current()!.provider === ProviderId.DEEPSEEK) {
              Row() {
                Text('深度思考')
                  .fontSize(15)
                  .fontColor(Theme.ink)
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.options()!.dsThinking })
                  .selectedColor(Theme.accent)
                  .onChange((on: boolean) => {
                    this.options()!.dsThinking = on;
                  })
              }
              .width('100%')
              .padding({ top: 12, bottom: 4 })

              if (this.options()!.dsThinking) {
                SectionTitle({ title: '思考强度' })
                Row({ space: 8 }) {
                  ForEach(modelInfo(this.store.current()!.model).efforts, (e: string) => {
                    Chip({
                      label: effortLabel(e),
                      selected: this.options()!.dsEffort === e,
                      onTap: () => {
                        this.options()!.dsEffort = e;
                      }
                    })
                  }, (e: string) => e)
                }
              }
            } else if (this.store.current()!.provider === ProviderId.OPENAI) {
              SectionTitle({ title: '思考强度' })
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(modelInfo(this.store.current()!.model).efforts, (e: string) => {
                  Chip({
                    label: effortLabel(e),
                    selected: this.options()!.oaiEffort === e,
                    onTap: () => {
                      this.options()!.oaiEffort = e;
                    }
                  }).margin({ right: 8, bottom: 8 })
                }, (e: string) => e)
              }

              if (this.options()!.oaiEffort !== 'none') {
                SectionTitle({ title: '推理模式' })
                Row({ space: 8 }) {
                  Chip({
                    label: '标准',
                    selected: this.options()!.oaiMode === 'standard',
                    onTap: () => {
                      this.options()!.oaiMode = 'standard';
                    }
                  })
                  Chip({
                    label: 'Pro',
                    selected: this.options()!.oaiMode === 'pro',
                    onTap: () => {
                      this.options()!.oaiMode = 'pro';
                    }
                  })
                }
              }

              SectionTitle({ title: '服务等级' })
              Row({ space: 8 }) {
                Chip({
                  label: '标准',
                  selected: this.options()!.oaiTier === 'standard',
                  onTap: () => {
                    this.options()!.oaiTier = 'standard';
                  }
                })
                if (modelInfo(this.store.current()!.model).supportsFast) {
                  Chip({
                    label: 'Fast',
                    selected: this.options()!.oaiTier === 'fast',
                    onTap: () => {
                      this.options()!.oaiTier = 'fast';
                    }
                  })
                }
                if (modelInfo(this.store.current()!.model).supportsUltrafast) {
                  Chip({
                    label: 'Ultrafast',
                    selected: this.options()!.oaiTier === 'ultrafast',
                    onTap: () => {
                      this.options()!.oaiTier = 'ultrafast';
                    }
                  })
                }
              }
            } else if (this.store.current()!.provider === ProviderId.MERCURY) {
              Row() {
                Column() {
                  Text('扩散输出')
                    .fontSize(15)
                    .fontColor(Theme.ink)
                  Text('实时展示文本去噪修订过程')
                    .fontSize(12)
                    .fontColor(Theme.ink3)
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.options()!.mercDiffusing })
                  .selectedColor(Theme.accent)
                  .onChange((on: boolean) => {
                    this.options()!.mercDiffusing = on;
                  })
              }
              .width('100%')
              .padding({ top: 12, bottom: 4 })

              SectionTitle({ title: '思考强度' })
              Row({ space: 8 }) {
                ForEach(modelInfo(this.store.current()!.model).efforts, (e: string) => {
                  Chip({
                    label: effortLabel(e),
                    selected: this.options()!.mercEffort === e,
                    onTap: () => {
                      this.options()!.mercEffort = e;
                    }
                  })
                }, (e: string) => e)
              }
            } else if (this.store.current()!.provider === ProviderId.GEMINI) {
              SectionTitle({ title: '思考强度' })
              Row({ space: 8 }) {
                ForEach(modelInfo(this.store.current()!.model).efforts, (e: string) => {
                  Chip({
                    label: effortLabel(e),
                    selected: this.options()!.gemLevel === e,
                    onTap: () => {
                      this.options()!.gemLevel = e;
                    }
                  })
                }, (e: string) => e)
              }
              Text('Gemini 4 / 3.8 系列不支持完全关闭思考。')
                .fontSize(12)
                .fontColor(Theme.ink3)
                .margin({ top: 10 })
            }
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 20 })
    .alignItems(HorizontalAlign.Start)
  }
}