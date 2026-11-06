import {
  AppSettings,
  ModelConfig,
  ProviderId,
  PROVIDER_NAMES,
  DEFAULT_BASE_URLS,
  getModelInfo,
  getProviderModels,
  ModelInfo,
  ThinkingEffort
} from '../types/Types';

@Component
export struct SettingsPanel {
  @Link settings: AppSettings;
  @Link modelConfig: ModelConfig;
  onClose: () => void = () => {};
  onSave: () => void = () => {};
  
  @State selectedProvider: ProviderId = 'deepseek';
  @State selectedModel: string = 'deepseek-flash';
  
  build() {
    Column() {
      // 标题栏
      Row() {
        Text('设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
        
        Blank()
        
        Button('完成')
          .fontSize(14)
          .height(32)
          .onClick(() => {
            this.onSave();
            this.onClose();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor('#F8F8F8')
      
      // 内容区域
      Scroll() {
        Column({ space: 20 }) {
          // 模型选择
          this.ModelSelector()
          
          // API设置
          this.ApiSettings()
          
          // 模型参数
          this.ModelParameters()
        }
        .width('100%')
        .padding(16)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
  
  @Builder
  ModelSelector() {
    Column({ space: 12 }) {
      Text('模型选择')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
      
      // 服务商选择
      Column({ space: 8 }) {
        Text('服务商')
          .fontSize(14)
          .fontColor('#666666')
        
        Row({ space: 8 }) {
          ForEach(['deepseek', 'openai', 'mercury', 'gemini'] as ProviderId[], (provider: ProviderId) => {
            Button(PROVIDER_NAMES[provider])
              .fontSize(12)
              .height(32)
              .backgroundColor(this.selectedProvider === provider ? '#007AFF' : '#E5E5E5')
              .fontColor(this.selectedProvider === provider ? '#FFFFFF' : '#000000')
              .onClick(() => {
                this.selectedProvider = provider;
                // 自动选择该服务商的第一个模型
                const models = getProviderModels(provider);
                if (models.length > 0) {
                  this.selectedModel = models[0].id;
                }
              })
          })
        }
      }
      
      // 模型选择
      Column({ space: 8 }) {
        Text('模型')
          .fontSize(14)
          .fontColor('#666666')
        
        Select(getProviderModels(this.selectedProvider).map((m: ModelInfo) => {
          return { value: m.name } as SelectOption;
        }))
          .selected(getProviderModels(this.selectedProvider).findIndex(m => m.id === this.selectedModel))
          .value(getModelInfo(this.selectedProvider, this.selectedModel)?.name || '')
          .onSelect((index: number) => {
            const models = getProviderModels(this.selectedProvider);
            if (models[index]) {
              this.selectedModel = models[index].id;
            }
          })
          .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F8F8F8')
    .borderRadius(12)
  }
  
  @Builder
  ApiSettings() {
    Column({ space: 12 }) {
      Text('API 设置')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
      
      // API Key
      Column({ space: 8 }) {
        Text('API Key')
          .fontSize(14)
          .fontColor('#666666')
        
        TextInput({ 
          placeholder: '输入 API Key',
          text: this.settings.providers[this.selectedProvider]?.apiKey || ''
        })
          .type(InputType.Password)
          .onChange((value: string) => {
            if (!this.settings.providers[this.selectedProvider]) {
              this.settings.providers[this.selectedProvider] = { apiKey: '' };
            }
            this.settings.providers[this.selectedProvider].apiKey = value;
          })
          .width('100%')
      }
      
      // Base URL (可选)
      Column({ space: 8 }) {
        Text('Base URL (可选)')
          .fontSize(14)
          .fontColor('#666666')
        
        TextInput({
          placeholder: DEFAULT_BASE_URLS[this.selectedProvider],
          text: this.settings.providers[this.selectedProvider]?.baseUrl || ''
        })
          .onChange((value: string) => {
            if (!this.settings.providers[this.selectedProvider]) {
              this.settings.providers[this.selectedProvider] = { apiKey: '' };
            }
            this.settings.providers[this.selectedProvider].baseUrl = value;
          })
          .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F8F8F8')
    .borderRadius(12)
  }
  
  @Builder
  ModelParameters() {
    const modelInfo = getModelInfo(this.selectedProvider, this.selectedModel);
    if (!modelInfo) return;
    
    Column({ space: 12 }) {
      Text('模型参数')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
      
      // 思考模式
      if (modelInfo.capabilities.supportsThinking) {
        Column({ space: 8 }) {
          Row() {
            Text('启用思考')
              .fontSize(14)
              .fontColor('#666666')
            
            Blank()
            
            Toggle({ type: ToggleType.Switch, isOn: this.modelConfig.thinkingEnabled })
              .onChange((isOn: boolean) => {
                this.modelConfig.thinkingEnabled = isOn;
              })
          }
          .width('100%')
          
          // 思考强度
          if (this.modelConfig.thinkingEnabled && modelInfo.capabilities.thinkingEfforts) {
            Column({ space: 6 }) {
              Text('思考强度')
                .fontSize(13)
                .fontColor('#999999')
              
              Row({ space: 6 }) {
                ForEach(modelInfo.capabilities.thinkingEfforts, (effort: ThinkingEffort) => {
                  Button(this.getEffortLabel(effort))
                    .fontSize(11)
                    .height(28)
                    .backgroundColor(this.modelConfig.thinkingEffort === effort ? '#007AFF' : '#E5E5E5')
                    .fontColor(this.modelConfig.thinkingEffort === effort ? '#FFFFFF' : '#000000')
                    .onClick(() => {
                      this.modelConfig.thinkingEffort = effort;
                    })
                })
              }
            }
            .width('100%')
          }
        }
      }
      
      // Mercury扩散模式
      if (modelInfo.capabilities.supportsDiffusion) {
        Row() {
          Column({ space: 4 }) {
            Text('扩散输出')
              .fontSize(14)
              .fontColor('#666666')
            
            Text('实时展示文本修订过程')
              .fontSize(11)
              .fontColor('#999999')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          
          Toggle({ 
            type: ToggleType.Switch, 
            isOn: this.modelConfig.diffusionEnabled !== false 
          })
            .onChange((isOn: boolean) => {
              this.modelConfig.diffusionEnabled = isOn;
            })
        }
        .width('100%')
      }
      
      // OpenAI Reasoning Mode
      if (modelInfo.capabilities.reasoningModes) {
        Column({ space: 6 }) {
          Text('推理模式')
            .fontSize(13)
            .fontColor('#999999')
          
          Row({ space: 6 }) {
            ForEach(modelInfo.capabilities.reasoningModes, (mode: string) => {
              Button(mode === 'standard' ? '标准' : 'Pro')
                .fontSize(11)
                .height(28)
                .backgroundColor(this.modelConfig.reasoningMode === mode ? '#007AFF' : '#E5E5E5')
                .fontColor(this.modelConfig.reasoningMode === mode ? '#FFFFFF' : '#000000')
                .onClick(() => {
                  this.modelConfig.reasoningMode = mode as any;
                })
            })
          }
        }
        .width('100%')
      }
      
      // OpenAI Speed Mode
      if (modelInfo.capabilities.speedModes) {
        Column({ space: 6 }) {
          Text('速度模式')
            .fontSize(13)
            .fontColor('#999999')
          
          Row({ space: 6 }) {
            ForEach(modelInfo.capabilities.speedModes, (mode: string) => {
              Button(this.getSpeedLabel(mode))
                .fontSize(11)
                .height(28)
                .backgroundColor(this.modelConfig.speedMode === mode ? '#007AFF' : '#E5E5E5')
                .fontColor(this.modelConfig.speedMode === mode ? '#FFFFFF' : '#000000')
                .onClick(() => {
                  this.modelConfig.speedMode = mode as any;
                })
            })
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F8F8F8')
    .borderRadius(12)
  }
  
  private getEffortLabel(effort: ThinkingEffort): string {
    const labels: Record<ThinkingEffort, string> = {
      'none': '关闭',
      'low': '低',
      'medium': '中',
      'high': '高',
      'xhigh': '极高',
      'max': '最大'
    };
    return labels[effort] || effort;
  }
  
  private getSpeedLabel(mode: string): string {
    const labels: Record<string, string> = {
      'normal': '普通',
      'fast': '快速',
      'ultrafast': '极速'
    };
    return labels[mode] || mode;
  }
}
