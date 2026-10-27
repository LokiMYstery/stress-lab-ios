# Stress Lab 研究说明

状态：V0 实验模型，2026-09-23 更新。本文只约束 Stress Lab 验证 App 的实验方法，不代表已经还原 StressWatch 私有算法，也不构成医疗或健康诊断。

## 结论摘要

- HRV 看板应以 `RMSSD` 为主。StressWatch 明确说其 HRV 使用 RMSSD，而 Apple 健康展示的 HRV 是 `SDNN`，两者数值不应直接对齐。
- 实时压力只能先做“可解释的 V0 拟合”。StressWatch 公开了“心率 + HRV 历史分布拟合”的方向和 1-100% 分段，但没有公开权重、标准化方法、异常过滤和百分比映射公式。
- 6 分钟只能定义为我们的图表与回算时间格，不应承诺 iPhone App 或 Apple Watch 后台一定每 6 分钟产生新数据。
- HealthKit 读权限本身不可被 App 精确判断；空数据不能被写成“用户拒绝授权”。
- 不建议在产品或文档中引导用户开启房颤历史来提高 HRV 频率。StressWatch 文档提到该路径，但它涉及地区可用性、耗电和健康功能边界；Stress Lab 只读取用户已有数据。

## 公开证据 - 实现假设 - 待验证点

| 主题 | 公开证据 | V0 实现假设 | 待验证点 |
| --- | --- | --- | --- |
| RMSSD vs SDNN | StressWatch 文档称其 HRV 为 RMSSD，Apple Health 为 SDNN；Frontiers 综述定义 RMSSD 为相邻 RR 间期差的均方根，SDNN 为 NN 间期标准差。 | HRV 图只画我们由 heartbeat series 算出的 RMSSD；Apple SDNN 仅作诊断参考，不混进 RMSSD 曲线。 | 同一次 Apple Watch 记录下，我们的 RMSSD 是否与 StressWatch 同时刻 HRV 接近。 |
| 实时压力来源 | StressWatch 称实时压力结合心率与 HRV 历史分布拟合，范围 1%-100%，数值越大身体压力越大。 | 用个人历史分布做稳健标准化：`ln(RMSSD)` 下降、近期心率升高都推高压力分；这里的心率是 HealthKit 单次心率样本，不是 Apple 的静息心率汇总值。分数是实验指数，不是概率。 | StressWatch 是否还用了呼吸、近期趋势、年龄、性别、睡眠债、恢复时间或私有异常过滤。 |
| 白天分段 | StressWatch 公开白天映射：优秀 1-20，正常 21-60，注意压力 61-80，压力过载 81-100；睡眠标准不同。 | 图表颜色采用相同白天分段；睡眠使用独立基线但暂用同色段，并标注为实验规则。 | 夜间分段是否需要完全独立阈值或展示样式。 |
| HRV 更新频率 | StressWatch 称 Apple Watch HRV 通常约 2-5 小时一次，实时压力通常 6 分钟一次；Apple Watch 的 HRV 频率开发者不能直接调整。 | App 打开、回前台、手动刷新、前台观察数据变化时增量读取；6 分钟只是 pressure bin，不承诺后台采样频率。 | 真机上 heartbeat series、SDNN、heart rate 到 iPhone 的实际延迟和缺失模式。 |
| 逐拍数据与 gap | Apple WWDC19 说明 `HKHeartbeatSeriesSample` 存心跳时间戳，`precededByGap` 用来标记传感器数据断点，避免把断点解释成真实长 RR。 | RMSSD 不跨 `precededByGap`、删除点或不同 series 计算相邻差；保留 raw/gap-aware 与 filtered 两套诊断值。 | Apple Watch 自动 HRV 样本是否总能读到对应 heartbeat series；不同系统版本和设备是否一致。 |
| 心率活动上下文 | Apple 文档称 heart rate sample 可带 `HKMetadataKeyHeartRateMotionContext`；未能判断时可能缺失，应视作 `notSet`。 | 优先使用明确 sedentary 的心率；没有该标记且无已知运动冲突时，unknown 作为低置信度输入并显式标记。仅 Apple Watch 的 active 标记触发默认频繁移动排除。 | 真机历史样本中的 motion context 覆盖率，以及 unknown 输入和 StressWatch 的偏差。 |
| 运动与手动测量 | StressWatch 称走动、运动、高速移动、佩戴不稳、低电量等状态会影响监测；手动 HRV 建议安静、自然呼吸，运动后等待恢复。 | workout 期间及结束后 30 分钟排除；mindful/breathe 可查看但默认不进入日常基线。 | 正念触发的 HRV 是更接近 StressWatch 还是应单独分桶。 |
| 呼吸与实验质量 | Frontiers 建议 HRV 研究报告采集、分析、呼吸等条件；RMSSD 相比 HF 更少受呼吸频率影响，但仍不是完全无关。 | V0 不读取呼吸，先把采样来源、过滤原因和测量场景展示清楚。 | 后续是否需要接入呼吸频率、正念会话类型或手动测量标签。 |
| 异常点处理 | Frontiers 综述强调单个 artifact 也可能显著影响 HRV。 | 初始只设 RR 范围 300-2000 ms、最小片段 30 秒、至少 20 组相邻差；所有阈值放进参数页。 | 需要用真机数据对比 StressWatch 后再调异常过滤，不把 V0 阈值说成论文结论。 |
| HealthKit 权限与空数据 | Apple 文档称 App 不知道用户是否授予 HealthKit 读权限；被拒读时查询看起来像没有匹配数据。 | 空数据状态写成“没有可读样本或权限/历史范围不足”，不直接判断“拒绝授权”。 | 有限历史授权时每种数据类型最早可读日期如何展示。 |

## V0 算法边界

### RMSSD

输入为同一 `HKHeartbeatSeriesSample` 内保持采集顺序的心跳时间戳；不通过重新排序“修复”倒序数据。相邻心跳时间戳相减得到 RR 间期，单位 ms。对相邻有效 RR 间期差求平方、平均、开方：

```text
RMSSD = sqrt(mean((RR[i] - RR[i-1])^2))
```

V0 只在有效连续片段累计不少于 30 秒、至少 20 组相邻 RR 差、RR 位于 300-2000 ms 时生成默认 RMSSD。跨 gap、跨 series、被过滤 RR 两侧都不拼接。

### 实时压力实验分：保留 V0，试验 V1

目标不是复刻私有公式，而是生成可回放、可解释、可调参的对照曲线。

```text
lnHRV_z = (baselineMedianLnRMSSD - currentLnRMSSD) / max(1.4826 * baselineMADLnRMSSD, 0.15)
hr_z    = (currentHR - baselineMedianHR) / max(1.4826 * baselineMADHR, 3)
z       = weightedMean(lnHRV_z, hr_z)
score   = clamp(round(center + slope * z), 1, 100)
```

V0 保留 `center=50、slope=20、HRV 权重 3 小时衰减、HRV 尺度下限 0.15、心率尺度下限 3 bpm`，方便前后对照。

V1 是根据用户提供的 2026-09-21 至 23 日成对截图提出的校准候选：心率尺度下限 8 bpm、RMSSD 对数尺度下限 0.25、HRV 权重 1.5 小时衰减；当 `z≥0` 用斜率 8，当 `z<0` 用斜率 15，中心值仍为 50。若选定来源有最近 36 小时的静息心率和此前完整日的静息心率基线，V1 将当下静止心率偏差与静息心率偏差按 35%/65% 合并；只存在一个信号时用该信号并标明来源。V0 不使用此新分支。例如 `z=+2` 时 V0=90、V1=66，`z=+4` 时 V1=82。红色仍对应 81–100 分，但须有更大的偏离。历史参数版本保持可选。

V2 延续 V1 的连续分数，默认关闭可调的 RMSSD 质量门槛，以对照过去被时长、组数或 RR 范围排除的逐拍记录。仍然不得跨 Apple 标记的缺口、倒序和非正时间间隔计算。对于连续压力图，只有原始参考分达到红区、之前 30 分钟至少有两个有效格、比这些格的中位数高至少 20 分、比最近有效格高至少 15 分，且距离上一次红色至少 45 分钟，才标红；其他高分上限展示为橙色 80 分。这是根据 9 月 21、22 日截图提出的“突变才标红”假设，既不是 StressWatch 公布的规则，也未经逐格数值拟合。

V3 使用用户提供的 HRV 点开压力分数，保持 V2 的原始 RMSSD 展示和红色突变规则。先按 V2 计算 HRV 偏离的基础分 `s`，再以单调曲线 `4 + 96/(1+exp(-0.155×(s−50)))` 得到 HRV 点分。它在可可靠配对的 12 个点上平均绝对误差约 2.6 分、最大约 8 分；样本只来自 3 天，不能当作已验证模型。9 月 21 日第 3、5 个 RMSSD 点的读数差距明显，未作为“仅分数映射误差”的训练点，仍需核对采样时间和逐拍序列。

V3 的六分钟压力不另立一套点分：刚测得 HRV 后的首个六分钟格采用同一 HRV 分数；存在心率通道时，之后由 HRV 分数与心率通道基础分按 HRV 时效权重混合。只有 HRV 而没有心率通道时，在 1.5 小时有效期内持续采用该 HRV 分数。新版频繁移动判定只看 Apple Watch 心率样本是否在此前五分钟明确标记 `active`；步数不参与默认压力计算。运动及恢复仍单独排除。旧参数版本保留旧步数判定，用于复现缓存报告。Apple 的 `notSet` 活动状态表示未知，不直接等同静止或移动；这种缺失可能使真实移动仍被估分。

历史日期的报告按本地日期、时区、来源、参数版本持久化；自动刷新只更新当天报告。更换版本或主动刷新旧日才重新回算。此策略方便稳定对照，但晚同步的 HealthKit 记录不会自动改写已缓存的旧日报告。

只有一种信号可用时标记为单信号估算；两种都不可用时历史图留空。有部分个人历史但样本不足时作临时估算；完全没有个人基线时，以可调产品参照（RMSSD 50 ms、心率 70 bpm，尺度 0.5 和 10 bpm）与真实测量比较，显示默认参照标记。没有当时测量输入的时间格仍留空，当前参考卡返回默认 50。这些默认值不是医学正常值或 StressWatch 参数。

三天截图显示 RMSSD 数值与时间大体接近，但 Stress Lab 压力图存在长段红色；9 月 23 日 13:24 的 97 分来自普通心率估算，而 StressWatch 当天展示的静息心率为 63 bpm，接近其近期平均 62 bpm。V1 缓和短时心率的正向偏离，并在可用时参考静息心率。截图无法提供 StressWatch 的逐格数值，因此不能据此证明数值已对齐。

基线只使用目标时刻之前 30 个完整本地日，清醒和睡眠分开，设备来源分开，禁止未来数据泄漏。HRV 至少 20 份记录，心率至少 100 个有效 6 分钟格，且覆盖至少 7 天，才认为对应基线可用。

## HealthKit 读取约束

- 只申请读取，不写回 HealthKit。
- 需要读取：heartbeat series、heart rate variability SDNN、heart rate、resting heart rate、workout、steps、sleep analysis、mindful session。
- 默认选择最近有 heartbeat series 的 Apple Watch 来源；切换来源后按来源重新计算基线。若 HealthKit 缺少稳定设备 ID，同来源记录可能混用同型号设备，只能作标记了来源不确定的实验估算。
- `HKMetadataKeyHeartRateMotionContext` 缺失时等同 unknown，不自动当 sedentary。
- HRV 图会显示被过滤的逐拍记录、其他手表来源的逐拍记录，以及 Apple SDNN 在当前来源未找到近时逐拍序列的记录。它有助于排查 StressWatch 多出一两次测量的原因，但 SDNN 不能直接换算为 RMSSD，诊断结果也不能证明 StressWatch 的数据来源。
- 读权限不可精确判断；错误、空数据、有限历史和真实无样本需要在 UI 中分开尽量解释，但不能伪造结论。
- 所有健康记录和计算结果留在本机；不上传、不接分析 SDK。

## 不做的事

- 不抓取 StressWatch 数据、不识别截图、不让用户录入竞品值。
- 不承诺与 StressWatch 百分比一致率。
- 不宣称压力分是医学诊断、心理压力、焦虑程度或疾病风险。
- 不引导用户开启房颤历史；若用户自行开启，只把随之出现的 HealthKit 数据作为普通输入读取。
- 不把模拟器 demo 数据混入真实记录或本地真实缓存。

## 参考来源

- StressWatch: [HRV 与实时压力的联系和区别](https://docs.ideation.love/stresswatch/zh_cn/principle/hrv-and-realtimestress.html)
- StressWatch: [自动测量频率与手动测量](https://docs.ideation.love/stresswatch/zh_cn/guide/what-is-the-frequency-of-measurement.html)
- StressWatch: [StressWatch 的 HRV 跟苹果健康为什么不一样](https://docs.ideation.love/stresswatch/zh_cn/principle/why-are-different-from-apple-health.html)
- Apple Developer: [Exploring New Data Representations in HealthKit - WWDC19](https://developer.apple.com/videos/play/wwdc2019/218/)
- Apple Developer: [heartRate](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartrate)
- Apple Developer: [Authorizing access to health data](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- Shaffer & Ginsberg, 2017: [An Overview of Heart Rate Variability Metrics and Norms](https://www.frontiersin.org/journals/public-health/articles/10.3389/fpubh.2017.00258/full)
- Laborde, Mosley & Thayer, 2017: [Heart Rate Variability and Cardiac Vagal Tone in Psychophysiological Research](https://www.frontiersin.org/journals/psychology/articles/10.3389/fpsyg.2017.00213/full)
