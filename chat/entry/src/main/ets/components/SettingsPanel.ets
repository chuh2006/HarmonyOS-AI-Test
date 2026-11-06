import {
  AppSettings,
  ModelConfig,
  ModelInfo,
  OpenAIReasoningMode,
  OpenAISpeedMode,
  ProviderId,
  ProviderSettings,
  ThinkingEffort,
  getDefaultBaseUrl,
  getModelInfo,
  getProviderModels,
  getProviderName,
  getProviderSettings,
  setProviderSettings
} from '../types/Types';

@Component
export struct SettingsPanel {
  @Link settings: AppSettings;
  @Link modelConfig: ModelConfig;
  onClose: () => void = () => {
  };
  onSave: () => void = () => {
  };

  @State selectedProvider: ProviderId = 'deepseek';
  @State selectedModel: string = 'deepseek-flash';

  aboutToAppear(): void {
    this.selectedProvider = this.modelConfig.providerId;
    this.selectedModel = this.modelConfig.modelId;
  }

  build() {
    Column() {
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

      Scroll() {
        Column({ space: 16 }) {
          this.ModelSelector()
          this.ApiSettings()
          this.ModelParameters()
        }
        .width('100%')
        .padding(16)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  @Builder
  ModelSelector() {
    Column({ space: 12 }) {
      Text('模型')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)

      // 4个服务商标签长度不一，必须换行，否则最后一个会被挤出屏幕
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.providerIds(), (provider: ProviderId) => {
          Button(this.providerLabel(provider))
            .fontSize(12)
            .height(32)
            .margin({ right: 6, bottom: 6 })
            .backgroundColor(this.selectedProvider === provider ? '#007AFF' : '#E5E5E5')
            .fontColor(this.selectedProvider === provider ? '#FFFFFF' : '#000000')
            .onClick(() => {
              this.selectProvider(provider);
            })
        }, (provider: ProviderId) => provider)
      }
      .width('100%')

      Select(this.modelOptions())
        .selected(this.selectedModelIndex())
        .value(this.selectedModelName())
        .font({ size: 14 })
        .onSelect((index: number) => {
          this.selectModelIndex(index);
        })
        .width('100%')
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F8F8F8')
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ApiSettings() {
    Column({ space: 12 }) {
      Text('API')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)

      Column({ space: 6 }) {
        Text(`${getProviderName(this.selectedProvider)} API Key`)
          .fontSize(13)
          .fontColor('#666666')

        TextInput({ placeholder: '输入 API Key', text: this.currentApiKey() })
          .type(InputType.Password)
          .fontSize(14)
          .onChange((value: string) => {
            this.updateApiKey(value);
          })
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 6 }) {
        Text('接口地址（可选）')
          .fontSize(13)
          .fontColor('#666666')

        TextInput({ placeholder: getDefaultBaseUrl(this.selectedProvider), text: this.currentBaseUrl() })
          .fontSize(14)
          .onChange((value: string) => {
            this.updateBaseUrl(value);
          })
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F8F8F8')
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ModelParameters() {
    Column({ space: 12 }) {
      Text('参数')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)

      if (this.supportsThinking()) {
        Row() {
          Text('思考')
            .fontSize(14)
            .fontColor('#333333')
          Blank()
          Toggle({ type: ToggleType.Switch, isOn: this.modelConfig.thinkingEnabled })
            .onChange((isOn: boolean) => {
              this.setThinkingEnabled(isOn);
            })
        }
        .width('100%')

        if (this.modelConfig.thinkingEnabled) {
          Column({ space: 6 }) {
            Text('思考强度')
              .fontSize(13)
              .fontColor('#999999')

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.efforts(), (effort: ThinkingEffort) => {
                Button(this.effortLabel(effort))
                  .fontSize(11)
                  .height(28)
                  .margin({ right: 6, bottom: 6 })
                  .backgroundColor(this.modelConfig.thinkingEffort === effort ? '#007AFF' : '#E5E5E5')
                  .fontColor(this.modelConfig.thinkingEffort === effort ? '#FFFFFF' : '#000000')
                  .onClick(() => {
                    this.setThinkingEffort(effort);
                  })
              }, (effort: ThinkingEffort) => effort)
            }
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
      }

      if (this.supportsDiffusion()) {
        Row() {
          Column({ space: 4 }) {
            Text('扩散输出')
              .fontSize(14)
              .fontColor('#333333')
            Text('实时展示文本修订过程')
              .fontSize(11)
              .fontColor('#999999')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.modelConfig.diffusionEnabled !== false })
            .onChange((isOn: boolean) => {
              this.setDiffusionEnabled(isOn);
            })
        }
        .width('100%')
      }

      if (this.supportsReasoningMode()) {
        Column({ space: 6 }) {
          Text('推理模式')
            .fontSize(13)
            .fontColor('#999999')

          Row({ space: 6 }) {
            ForEach(this.reasoningModes(), (mode: OpenAIReasoningMode) => {
              Button(this.reasoningModeLabel(mode))
                .fontSize(11)
                .height(28)
                .backgroundColor(this.modelConfig.reasoningMode === mode ? '#007AFF' : '#E5E5E5')
                .fontColor(this.modelConfig.reasoningMode === mode ? '#FFFFFF' : '#000000')
                .onClick(() => {
                  this.setReasoningMode(mode);
                })
            }, (mode: OpenAIReasoningMode) => mode)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      if (this.supportsSpeedMode()) {
        Column({ space: 6 }) {
          Text('速度模式')
            .fontSize(13)
            .fontColor('#999999')

          Row({ space: 6 }) {
            ForEach(this.speedModes(), (mode: OpenAISpeedMode) => {
              Button(this.speedLabel(mode))
                .fontSize(11)
                .height(28)
                .backgroundColor(this.modelConfig.speedMode === mode ? '#007AFF' : '#E5E5E5')
                .fontColor(this.modelConfig.speedMode === mode ? '#FFFFFF' : '#000000')
                .onClick(() => {
                  this.setSpeedMode(mode);
                })
            }, (mode: OpenAISpeedMode) => mode)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor('#F8F8F8')
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
  }

  private providerIds(): ProviderId[] {
    return ['deepseek', 'openai', 'mercury', 'gemini'];
  }

  // 按钮里用短名，避免一行放不下
  private providerLabel(provider: ProviderId): string {
    if (provider === 'openai') {
      return 'OpenAI';
    }
    if (provider === 'mercury') {
      return 'Mercury';
    }
    if (provider === 'gemini') {
      return 'Gemini';
    }
    return 'DeepSeek';
  }

  private currentModel(): ModelInfo | undefined {
    return getModelInfo(this.selectedProvider, this.selectedModel);
  }

  private modelOptions(): SelectOption[] {
    const models: ModelInfo[] = getProviderModels(this.selectedProvider);
    const options: SelectOption[] = [];
    for (const model of models) {
      const option: SelectOption = { value: model.name };
      options.push(option);
    }
    return options;
  }

  private selectedModelIndex(): number {
    const models: ModelInfo[] = getProviderModels(this.selectedProvider);
    for (let i = 0; i < models.length; i++) {
      if (models[i].id === this.selectedModel) {
        return i;
      }
    }
    return 0;
  }

  private selectedModelName(): string {
    const info: ModelInfo | undefined = this.currentModel();
    return info !== undefined ? info.name : '';
  }

  private selectProvider(provider: ProviderId): void {
    const models: ModelInfo[] = getProviderModels(provider);
    if (models.length === 0) {
      return;
    }
    this.applyModel(provider, models[0].id);
  }

  private selectModelIndex(index: number): void {
    const models: ModelInfo[] = getProviderModels(this.selectedProvider);
    if (index < 0 || index >= models.length) {
      return;
    }
    this.applyModel(this.selectedProvider, models[index].id);
  }

  // 换模型时按能力重置该模型的选项
  private applyModel(providerId: ProviderId, modelId: string): void {
    this.selectedProvider = providerId;
    this.selectedModel = modelId;

    const info: ModelInfo | undefined = getModelInfo(providerId, modelId);
    const hasReasoningModes: boolean = info !== undefined && info.capabilities.reasoningModes !== undefined;
    const hasSpeedModes: boolean = info !== undefined && info.capabilities.speedModes !== undefined;
    const hasDiffusion: boolean = info !== undefined && info.capabilities.supportsDiffusion === true;

    const config: ModelConfig = {
      providerId: providerId,
      modelId: modelId,
      thinkingEnabled: false,
      thinkingEffort: 'none',
      reasoningMode: hasReasoningModes ? 'standard' : undefined,
      speedMode: hasSpeedModes ? 'normal' : undefined,
      diffusionEnabled: hasDiffusion
    };
    this.modelConfig = config;
  }

  private currentApiKey(): string {
    return getProviderSettings(this.settings.providers, this.selectedProvider).apiKey;
  }

  private currentBaseUrl(): string {
    const settings: ProviderSettings = getProviderSettings(this.settings.providers, this.selectedProvider);
    return settings.baseUrl !== undefined ? settings.baseUrl : '';
  }

  private updateApiKey(value: string): void {
    const current: ProviderSettings = getProviderSettings(this.settings.providers, this.selectedProvider);
    const updated: ProviderSettings = { apiKey: value, baseUrl: current.baseUrl };
    setProviderSettings(this.settings.providers, this.selectedProvider, updated);
  }

  private updateBaseUrl(value: string): void {
    const current: ProviderSettings = getProviderSettings(this.settings.providers, this.selectedProvider);
    const updated: ProviderSettings = {
      apiKey: current.apiKey,
      baseUrl: value.length > 0 ? value : undefined
    };
    setProviderSettings(this.settings.providers, this.selectedProvider, updated);
  }

  private supportsThinking(): boolean {
    const info: ModelInfo | undefined = this.currentModel();
    return info !== undefined && info.capabilities.supportsThinking;
  }

  private supportsDiffusion(): boolean {
    const info: ModelInfo | undefined = this.currentModel();
    return info !== undefined && info.capabilities.supportsDiffusion === true;
  }

  private supportsReasoningMode(): boolean {
    return this.reasoningModes().length > 0;
  }

  private supportsSpeedMode(): boolean {
    return this.speedModes().length > 0;
  }

  private efforts(): ThinkingEffort[] {
    const info: ModelInfo | undefined = this.currentModel();
    if (info === undefined || info.capabilities.thinkingEfforts === undefined) {
      return [];
    }
    return info.capabilities.thinkingEfforts;
  }

  private reasoningModes(): OpenAIReasoningMode[] {
    const info: ModelInfo | undefined = this.currentModel();
    if (info === undefined || info.capabilities.reasoningModes === undefined) {
      return [];
    }
    return info.capabilities.reasoningModes;
  }

  private speedModes(): OpenAISpeedMode[] {
    const info: ModelInfo | undefined = this.currentModel();
    if (info === undefined || info.capabilities.speedModes === undefined) {
      return [];
    }
    return info.capabilities.speedModes;
  }

  // @Link 的对象内部字段变化不会触发刷新，改完后整体重新赋值
  private setThinkingEnabled(isOn: boolean): void {
    const config: ModelConfig = this.cloneConfig();
    config.thinkingEnabled = isOn;
    if (!isOn) {
      config.thinkingEffort = 'none';
    } else if (config.thinkingEffort === 'none') {
      config.thinkingEffort = this.defaultEffort();
    }
    this.modelConfig = config;
  }

  private setThinkingEffort(effort: ThinkingEffort): void {
    const config: ModelConfig = this.cloneConfig();
    config.thinkingEffort = effort;
    config.thinkingEnabled = effort !== 'none';
    this.modelConfig = config;
  }

  private setDiffusionEnabled(isOn: boolean): void {
    const config: ModelConfig = this.cloneConfig();
    config.diffusionEnabled = isOn;
    this.modelConfig = config;
  }

  private setReasoningMode(mode: OpenAIReasoningMode): void {
    const config: ModelConfig = this.cloneConfig();
    config.reasoningMode = mode;
    this.modelConfig = config;
  }

  private setSpeedMode(mode: OpenAISpeedMode): void {
    const config: ModelConfig = this.cloneConfig();
    config.speedMode = mode;
    this.modelConfig = config;
  }

  private cloneConfig(): ModelConfig {
    const config: ModelConfig = {
      providerId: this.modelConfig.providerId,
      modelId: this.modelConfig.modelId,
      thinkingEnabled: this.modelConfig.thinkingEnabled,
      thinkingEffort: this.modelConfig.thinkingEffort,
      reasoningMode: this.modelConfig.reasoningMode,
      speedMode: this.modelConfig.speedMode,
      diffusionEnabled: this.modelConfig.diffusionEnabled,
      maxTokens: this.modelConfig.maxTokens
    };
    return config;
  }

  private defaultEffort(): ThinkingEffort {
    const efforts: ThinkingEffort[] = this.efforts();
    for (const effort of efforts) {
      if (effort !== 'none') {
        return effort;
      }
    }
    return 'low';
  }

  private effortLabel(effort: ThinkingEffort): string {
    if (effort === 'none') {
      return '关闭';
    }
    if (effort === 'low') {
      return '低';
    }
    if (effort === 'medium') {
      return '中';
    }
    if (effort === 'high') {
      return '高';
    }
    if (effort === 'xhigh') {
      return '极高';
    }
    return '最大';
  }

  private reasoningModeLabel(mode: OpenAIReasoningMode): string {
    return mode === 'standard' ? '标准' : 'Pro';
  }

  private speedLabel(mode: OpenAISpeedMode): string {
    if (mode === 'fast') {
      return '快速';
    }
    if (mode === 'ultrafast') {
      return '极速';
    }
    return '普通';
  }
}
