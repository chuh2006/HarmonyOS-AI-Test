/**
 * Bottom sheets: conversation list, model & options, API settings.
 */
import { Session, SessionOptions, defaultOptionsFor } from '../services/Types';
import {
  ModelInfo, PROVIDERS, ProviderInfo, defaultModelOf, modelInfo, providerInfo
} from '../services/Providers';
import { formatDayTime } from '../common/Util';
import {
  COLOR_BORDER, COLOR_PRIMARY, COLOR_PRIMARY_SOFT,
  COLOR_SURFACE, COLOR_SURFACE_SOFT, COLOR_TEXT, COLOR_TEXT_2, COLOR_TEXT_3,
  FONT_SMALL, FONT_TITLE
} from './Theme';
import { IconChat, IconClose, IconPlus, IconTrash, IconWarn } from './Icons';

const BRAND_COLORS: string[] = ['#4D6BFE', '#10A37F', '#E8734A', '#4A8CF7'];

function brandColor(providerId: string): string {
  for (let i = 0; i < PROVIDERS.length; i++) {
    if (PROVIDERS[i].id === providerId) {
      return BRAND_COLORS[i];
    }
  }
  return BRAND_COLORS[0];
}

@Component
struct SegPills {
  labels: string[] = [];
  values: string[] = [];
  selected: string = '';
  onPick: (v: string) => void = (v: string) => {
  };

  build() {
    Row({ space: 5 }) {
      ForEach(this.labels, (label: string, idx: number) => {
        Text(label)
          .fontSize(12.5)
          .fontColor(this.selected === this.values[idx] ? '#FFFFFF' : COLOR_TEXT_2)
          .fontWeight(this.selected === this.values[idx] ? FontWeight.Medium : FontWeight.Regular)
          .padding({ left: 11, right: 11, top: 6, bottom: 6 })
          .borderRadius(999)
          .backgroundColor(this.selected === this.values[idx] ? COLOR_PRIMARY : COLOR_SURFACE_SOFT)
          .onClick(() => {
            this.onPick(this.values[idx]);
          })
      }, (label: string, idx: number) => label + '_' + idx.toString())
    }
    .width('100%')
  }
}

@Component
struct ToggleRow {
  label: string = '';
  caption: string = '';
  on: boolean = false;
  onChange: (v: boolean) => void = (v: boolean) => {
  };

  build() {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(this.label)
          .fontSize(14)
          .fontColor(COLOR_TEXT)
        if (this.caption.length > 0) {
          Text(this.caption)
            .fontSize(11)
            .fontColor(COLOR_TEXT_3)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.on })
        .selectedColor(COLOR_PRIMARY)
        .switchPointColor('#FFFFFF')
        .onChange((v: boolean) => {
          this.onChange(v);
        })
    }
    .width('100%')
    .padding(13)
    .borderRadius(13)
    .backgroundColor(COLOR_SURFACE)
    .border({ width: 1, color: COLOR_BORDER })
  }
}

@Component
struct SegRow {
  label: string = '';
  labels: string[] = [];
  values: string[] = [];
  selected: string = '';
  onPick: (v: string) => void = (v: string) => {
  };

  build() {
    Column({ space: 9 }) {
      Text(this.label)
        .fontSize(12.5)
        .fontColor(COLOR_TEXT_2)
        .width('100%')
      SegPills({
        labels: this.labels,
        values: this.values,
        selected: this.selected,
        onPick: (v: string) => {
          this.onPick(v);
        }
      })
    }
    .width('100%')
    .padding(13)
    .borderRadius(13)
    .backgroundColor(COLOR_SURFACE)
    .border({ width: 1, color: COLOR_BORDER })
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
struct KeyCard {
  title: string = '';
  hint: string = '';
  keyValue: string = '';
  url: string = '';
  configured: boolean = false;
  showKey: boolean = false;
  onKey: (v: string) => void = (v: string) => {
  };
  onUrl: (v: string) => void = (v: string) => {
  };
  onSave: () => void = () => {
  };

  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Circle().width(8).height(8).fill(this.configured ? '#1F9D63' : '#C9C9D4')
        Text(this.title)
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_TEXT)
        Text(this.configured ? '已配置' : '未配置')
          .fontSize(11)
          .fontColor(this.configured ? '#1F9D63' : COLOR_TEXT_3)
      }
      .width('100%')

      TextInput({ text: this.keyValue, placeholder: 'API Key' })
        .type(this.showKey ? InputType.Normal : InputType.Password)
        .fontSize(13.5)
        .height(42)
        .backgroundColor(COLOR_SURFACE_SOFT)
        .borderRadius(11)
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.onKey(v);
        })

      TextInput({ text: this.url, placeholder: 'Base URL' })
        .type(InputType.Normal)
        .fontSize(13.5)
        .height(42)
        .backgroundColor(COLOR_SURFACE_SOFT)
        .borderRadius(11)
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.onUrl(v);
        })

      Row({ space: 10 }) {
        Text(this.hint)
          .fontSize(10.5)
          .fontColor(COLOR_TEXT_3)
          .layoutWeight(1)
        Text('保存')
          .fontSize(12.5)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)
          .padding({ left: 16, right: 16, top: 7, bottom: 7 })
          .borderRadius(999)
          .backgroundColor(COLOR_PRIMARY)
          .onClick(() => {
            this.onSave();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .borderRadius(15)
    .backgroundColor(COLOR_SURFACE)
    .border({ width: 1, color: COLOR_BORDER })
    .alignItems(HorizontalAlign.Start)
  }
}

/** ---------------- Conversation list ---------------- */

@Component
export struct SessionsSheetView {
  sessions: Session[] = [];
  currentId: string = '';
  onSelect: (id: string) => void = (id: string) => {
  };
  onDelete: (id: string) => void = (id: string) => {
  };
  onNew: () => void = () => {
  };

  build() {
    Column({ space: 0 }) {
      Row() {
        Text('对话记录')
          .fontSize(FONT_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)
        Blank()
        Row({ space: 5 }) {
          IconPlus(COLOR_PRIMARY, 15)
          Text('新会话').fontSize(13).fontColor(COLOR_PRIMARY).fontWeight(FontWeight.Medium)
        }
        .padding({ left: 12, right: 12, top: 7, bottom: 7 })
        .borderRadius(999)
        .backgroundColor(COLOR_PRIMARY_SOFT)
        .onClick(() => {
          this.onNew();
        })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 6, bottom: 12 })

      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.sessions, (s: Session) => {
            Row({ space: 10 }) {
              Column() {
                IconChat(s.id === this.currentId ? COLOR_PRIMARY : COLOR_TEXT_3, 18)
              }
              .width(34).height(34)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .borderRadius(17)
              .backgroundColor(s.id === this.currentId ? COLOR_PRIMARY_SOFT : COLOR_SURFACE_SOFT)

              Column({ space: 2 }) {
                Text(s.title.length > 0 ? s.title : '新会话')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(COLOR_TEXT)
                  .maxLines(1)
                  .width('100%')
                Text(modelInfo(s.providerId, s.modelId).label + ' · ' + formatDayTime(s.updatedAt))
                  .fontSize(11)
                  .fontColor(COLOR_TEXT_3)
                  .maxLines(1)
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Row() {
                IconTrash(COLOR_TEXT_3, 17)
              }
              .width(32).height(32)
              .justifyContent(FlexAlign.Center)
              .onClick(() => {
                this.onDelete(s.id);
              })
            }
            .width('100%')
            .padding(10)
            .borderRadius(14)
            .backgroundColor(s.id === this.currentId ? COLOR_PRIMARY_SOFT : COLOR_SURFACE)
            .border({
              width: 1,
              color: s.id === this.currentId ? '#CFCFF4' : COLOR_BORDER
            })
            .onClick(() => {
              this.onSelect(s.id);
            })
          }, (s: Session) => s.id + '_' + s.updatedAt.toString())
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8F8FB')
  }
}

/** ---------------- Model & options ---------------- */

@Component
export struct ModelSheetView {
  session: Session = new Session();
  toolsReady: boolean = true;
  onChanged: (s: Session) => void = (s: Session) => {
  };
  onOpenSettings: () => void = () => {
  };
  onClose: () => void = () => {
  };

  @State providerId: string = 'deepseek';
  @State modelId: string = 'deepseek-flash';
  @State thinkingOn: boolean = true;
  @State thinkingLevel: string = 'low';
  @State reasoningMode: string = 'standard';
  @State speedTier: string = 'standard';
  @State diffusing: boolean = true;

  aboutToAppear(): void {
    this.providerId = this.session.providerId;
    this.modelId = this.session.modelId;
    this.thinkingOn = this.session.options.thinkingOn;
    this.thinkingLevel = this.session.options.thinkingLevel;
    this.reasoningMode = this.session.options.reasoningMode;
    this.speedTier = this.session.options.speedTier;
    this.diffusing = this.session.options.diffusing;
    this.normalize();
  }

  curModel(): ModelInfo {
    return modelInfo(this.providerId, this.modelId);
  }

  private normalize(): void {
    const info: ModelInfo = this.curModel();
    let found: boolean = false;
    for (let i = 0; i < info.thinkingLevels.length; i++) {
      if (info.thinkingLevels[i] === this.thinkingLevel) {
        found = true;
      }
    }
    if (!found && info.thinkingLevels.length > 0) {
      this.thinkingLevel = info.thinkingLevels[0];
    }
    if (!info.thinkingToggle) {
      this.thinkingOn = true;
    }
    if (info.speedTiers.indexOf('ultrafast') < 0 && this.speedTier === 'ultrafast') {
      this.speedTier = 'fast';
    }
    if (info.speedTiers.indexOf('fast') < 0 && this.speedTier === 'fast') {
      this.speedTier = 'standard';
    }
    if (info.speedTiers.length === 0) {
      this.speedTier = 'standard';
    }
  }

  private commit(): void {
    this.normalize();
    const s: Session = this.session;
    s.providerId = this.providerId;
    s.modelId = this.modelId;
    s.options.thinkingOn = this.thinkingOn;
    s.options.thinkingLevel = this.thinkingLevel;
    s.options.reasoningMode = this.reasoningMode;
    s.options.speedTier = this.speedTier;
    s.options.diffusing = this.diffusing;
    this.onChanged(s);
  }

  private pickProvider(id: string): void {
    this.providerId = id;
    this.modelId = defaultModelOf(id);
    const o: SessionOptions = defaultOptionsFor(id);
    this.thinkingOn = o.thinkingOn;
    this.thinkingLevel = o.thinkingLevel;
    this.reasoningMode = o.reasoningMode;
    this.speedTier = o.speedTier;
    this.diffusing = o.diffusing;
    this.commit();
  }

  private speedLabels(): string[] {
    const out: string[] = ['标准'];
    const tiers: string[] = this.curModel().speedTiers;
    if (tiers.indexOf('fast') >= 0) {
      out.push('快速');
    }
    if (tiers.indexOf('ultrafast') >= 0) {
      out.push('极速');
    }
    return out;
  }

  private speedValues(): string[] {
    const out: string[] = ['standard'];
    const tiers: string[] = this.curModel().speedTiers;
    if (tiers.indexOf('fast') >= 0) {
      out.push('fast');
    }
    if (tiers.indexOf('ultrafast') >= 0) {
      out.push('ultrafast');
    }
    return out;
  }

  @Builder
  sectionLabel(text: string) {
    Text(text)
      .fontSize(12)
      .fontColor(COLOR_TEXT_3)
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .margin({ top: 18, bottom: 8 })
  }

  build() {
    Column({ space: 0 }) {
      Row() {
        Text('对话设置')
          .fontSize(FONT_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)
        Blank()
        Row() {
          IconClose(COLOR_TEXT_3, 17)
        }
        .width(30).height(30)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.onClose();
        })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 6, bottom: 10 })

      Scroll() {
        Column() {
          this.sectionLabel('服务商')
          Row({ space: 6 }) {
            ForEach(PROVIDERS, (p: ProviderInfo) => {
              Column({ space: 5 }) {
                Circle().width(8).height(8).fill(brandColor(p.id))
                Text(p.name)
                  .fontSize(12.5)
                  .fontWeight(this.providerId === p.id ? FontWeight.Medium : FontWeight.Regular)
                  .fontColor(this.providerId === p.id ? COLOR_PRIMARY : COLOR_TEXT_2)
              }
              .padding({ left: 8, right: 8, top: 9, bottom: 9 })
              .borderRadius(12)
              .backgroundColor(this.providerId === p.id ? COLOR_PRIMARY_SOFT : COLOR_SURFACE_SOFT)
              .layoutWeight(1)
              .onClick(() => {
                this.pickProvider(p.id);
              })
            }, (p: ProviderInfo) => p.id)
          }
          .width('100%')

          this.sectionLabel('模型')
          Column({ space: 8 }) {
            ForEach(providerInfo(this.providerId).models, (m: ModelInfo) => {
              Row({ space: 10 }) {
                Circle().width(18).height(18)
                  .stroke(this.modelId === m.id ? COLOR_PRIMARY : '#C9C9D4')
                  .strokeWidth(this.modelId === m.id ? 5.5 : 1.5)
                  .fill(this.modelId === m.id ? COLOR_PRIMARY : '#FFFFFF')
                Column({ space: 2 }) {
                  Text(m.label)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(COLOR_TEXT)
                  Text(m.desc)
                    .fontSize(11.5)
                    .fontColor(COLOR_TEXT_3)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .padding(12)
              .borderRadius(13)
              .backgroundColor(this.modelId === m.id ? COLOR_PRIMARY_SOFT : COLOR_SURFACE)
              .border({
                width: 1,
                color: this.modelId === m.id ? '#CFCFF4' : COLOR_BORDER
              })
              .onClick(() => {
                this.modelId = m.id;
                this.commit();
              })
            }, (m: ModelInfo) => m.id)
          }
          .width('100%')

          this.sectionLabel('模型选项')
          Column({ space: 10 }) {
            if (this.curModel().thinkingToggle) {
              ToggleRow({
                label: '深度思考',
                caption: '让模型先推理再回答',
                on: this.thinkingOn,
                onChange: (v: boolean) => {
                  this.thinkingOn = v;
                  this.commit();
                }
              })
            }
            if (this.curModel().hasThinking && (this.thinkingOn || !this.curModel().thinkingToggle)) {
              SegRow({
                label: '思考强度',
                labels: this.curModel().thinkingLabels,
                values: this.curModel().thinkingLevels,
                selected: this.thinkingLevel,
                onPick: (v: string) => {
                  this.thinkingLevel = v;
                  this.commit();
                }
              })
            }
            if (this.curModel().reasoningMode) {
              SegRow({
                label: '思考模式',
                labels: ['标准', '深度'],
                values: ['standard', 'pro'],
                selected: this.reasoningMode,
                onPick: (v: string) => {
                  this.reasoningMode = v;
                  this.commit();
                }
              })
            }
            if (this.curModel().speedTiers.length > 0) {
              SegRow({
                label: '响应速度',
                labels: this.speedLabels(),
                values: this.speedValues(),
                selected: this.speedTier,
                onPick: (v: string) => {
                  this.speedTier = v;
                  this.commit();
                }
              })
            }
            if (this.curModel().diffusing) {
              ToggleRow({
                label: '扩散输出',
                caption: '实时展示文本去噪修订的过程',
                on: this.diffusing,
                onChange: (v: boolean) => {
                  this.diffusing = v;
                  this.commit();
                }
              })
            }
          }
          .width('100%')

          if (!this.toolsReady) {
            Row({ space: 8 }) {
              IconWarn(COLOR_TEXT_2, 15)
              Text('联网搜索与网页抓取需要 DeepSeek API Key，填写后所有模型都可以使用。')
                .fontSize(11.5)
                .fontColor(COLOR_TEXT_2)
                .lineHeight(17)
                .layoutWeight(1)
              Text('去填写')
                .fontSize(11.5)
                .fontColor(COLOR_PRIMARY)
                .fontWeight(FontWeight.Medium)
                .onClick(() => {
                  this.onOpenSettings();
                })
            }
            .width('100%')
            .padding(11)
            .borderRadius(12)
            .backgroundColor(COLOR_PRIMARY_SOFT)
            .alignItems(VerticalAlign.Top)
            .margin({ top: 16 })
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 30 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8F8FB')
  }
}

/** ---------------- API settings ---------------- */

@Component
export struct SettingsSheetView {
  getKey: (id: string) => string = (id: string) => {
    return '';
  };
  getBaseUrl: (id: string, fallback: string) => string = (id: string, fallback: string) => {
    return fallback;
  };
  onSave: (id: string, key: string, url: string) => void = (id: string, key: string, url: string) => {
  };
  onClose: () => void = () => {
  };

  @State dsKey: string = '';
  @State dsUrl: string = '';
  @State oaKey: string = '';
  @State oaUrl: string = '';
  @State mcKey: string = '';
  @State mcUrl: string = '';
  @State ggKey: string = '';
  @State ggUrl: string = '';
  @State showKeys: boolean = false;

  aboutToAppear(): void {
    this.dsKey = this.getKey('deepseek');
    this.oaKey = this.getKey('openai');
    this.mcKey = this.getKey('mercury');
    this.ggKey = this.getKey('gemini');
    this.dsUrl = this.getBaseUrl('deepseek', providerInfo('deepseek').defaultBaseUrl);
    this.oaUrl = this.getBaseUrl('openai', providerInfo('openai').defaultBaseUrl);
    this.mcUrl = this.getBaseUrl('mercury', providerInfo('mercury').defaultBaseUrl);
    this.ggUrl = this.getBaseUrl('gemini', providerInfo('gemini').defaultBaseUrl);
  }

  private configured(key: string): boolean {
    return key.trim().length > 0;
  }

  build() {
    Column({ space: 0 }) {
      Row() {
        Text('API 设置')
          .fontSize(FONT_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLOR_TEXT)
        Blank()
        Text(this.showKeys ? '隐藏密钥' : '显示密钥')
          .fontSize(12)
          .fontColor(COLOR_PRIMARY)
          .onClick(() => {
            this.showKeys = !this.showKeys;
          })
        Row() {
          IconClose(COLOR_TEXT_3, 17)
        }
        .width(30).height(30)
        .justifyContent(FlexAlign.Center)
        .margin({ left: 6 })
        .onClick(() => {
          this.onClose();
        })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 6, bottom: 10 })

      Scroll() {
        Column({ space: 12 }) {
          KeyCard({
            title: 'DeepSeek',
            hint: '联网搜索与抓取也使用此 Key',
            keyValue: this.dsKey,
            url: this.dsUrl,
            configured: this.configured(this.dsKey),
            showKey: this.showKeys,
            onKey: (v: string) => {
              this.dsKey = v;
            },
            onUrl: (v: string) => {
              this.dsUrl = v;
            },
            onSave: () => {
              this.onSave('deepseek', this.dsKey, this.dsUrl);
            }
          })
          KeyCard({
            title: 'OpenAI',
            hint: 'Responses API 端点',
            keyValue: this.oaKey,
            url: this.oaUrl,
            configured: this.configured(this.oaKey),
            showKey: this.showKeys,
            onKey: (v: string) => {
              this.oaKey = v;
            },
            onUrl: (v: string) => {
              this.oaUrl = v;
            },
            onSave: () => {
              this.onSave('openai', this.oaKey, this.oaUrl);
            }
          })
          KeyCard({
            title: 'Mercury',
            hint: 'Chat Completions 端点',
            keyValue: this.mcKey,
            url: this.mcUrl,
            configured: this.configured(this.mcKey),
            showKey: this.showKeys,
            onKey: (v: string) => {
              this.mcKey = v;
            },
            onUrl: (v: string) => {
              this.mcUrl = v;
            },
            onSave: () => {
              this.onSave('mercury', this.mcKey, this.mcUrl);
            }
          })
          KeyCard({
            title: 'Gemini',
            hint: 'Generate Content 端点',
            keyValue: this.ggKey,
            url: this.ggUrl,
            configured: this.configured(this.ggKey),
            showKey: this.showKeys,
            onKey: (v: string) => {
              this.ggKey = v;
            },
            onUrl: (v: string) => {
              this.ggUrl = v;
            },
            onSave: () => {
              this.onSave('gemini', this.ggKey, this.ggUrl);
            }
          })

          Text('密钥仅保存在本机安全存储中，不会写入日志或上传。')
            .fontSize(11)
            .fontColor(COLOR_TEXT_3)
            .width('100%')
            .margin({ top: 6, bottom: 20 })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F8F8FB')
  }
}
