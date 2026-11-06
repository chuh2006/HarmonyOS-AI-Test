# HramonyOS AI Test

用于测试 AI 开发 ArkTS 的能力

这是由于 ArkUI 以及 ArkTS 的特性与传统 UI 包以及 Typescript 的要求不同，减少刷分对 AI 测试的影响。

> [!NOTE]
> 本测试仅代表模型在特定任务的单次表现，仅能在一定程度上体现模型在当前 Harness 环境，当前任务要求，当前思考档位和当前用户提示下的表现，不能据此直接判断模型的真实能力；也不能根据本测试直接认为某模型强于另一模型。

## 方法

使用 dev 分支为基础分支

```bash
git switch dev
git switch -c $你喜欢的分支名，例如模型名
```

打开对话发送

```text
按TASK.md完成任务
```

即可。
