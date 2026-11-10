# MenuScores 2.5.2 模块背景验收

final result: passed

本轮只按用户新要求，把分节比分和球队统计分别放进独立轻背景。沿用2.5.1首屏“比分＋一句总结＋完整技术统计”，没有重新设计球员表或复盘。

实际像素证据：`/tmp/MenuScores-build/ModulesQA/normal-score.png`、`normal-overview-dark.png`、`normal-team-switched.png`与`normal-returned-overview.png`。已实际打开浅色与深色截图，未上传。原生620pt宽，PNG为2x；正常首屏高度见同目录normal-score.json。

- 字体与数据：沿用原字号、字重和横排单行单元格，投篮命中/出手不拆行。所有字段及横向滚动保留；球员表代码和292pt滚动高度未改。
- 布局：两个独立圆角8pt背景，各8pt内边距，模块间10pt；移除原共用背景。左右边界及列对齐保持，纵向自然增加18pt，不加大宽度。
- 色彩：浅色primary 3%、深色5.5%轻底色，深浅色均能辨认模块间隙。无新增粗边、阴影或嵌套卡片；比分保持第一视觉层级。
- 资源与文案：没有改徽标/头像、总结缓存或数据文字，没有生成或搜索调用。

171项既有测试、27套件通过，Release构建成功。最新ModulesQA/interactions.json的正常、前瞻、部分覆盖都通过原生切队、复盘、证据、返回和选中/草稿/滚动恢复。统计表40pt滚动返回保留，窗口数量不变；本机捕获深浅色、长总结及缺数据状态。

CUA仅连接本项目Debug原生验收窗口，实际点击切马刺、进入详细复盘、展开完整文章、返回；马刺仍选中，单节及球队全部数据与七列表格可达。未关闭或操作其他项目窗口。截图只留本机。

无未解决P0/P1/P2。本轮验收不调用API；正式安装保护与费用回读记录在`.local-backups/terra-modules-final-validation.json`。

# MenuScores 2.5.3 通用查询及回答排版验收

final result: passed — 核心修复、原生离线交互与像素验收；额外助手在线样本边界如下。

198项测试、29套件通过，Release构建成功。新查询层从当前比赛的真实逐回合按球员/节次/时钟/类型计算贡献、反超和得分波；正向clutch、加时、时钟更正、重复冲突、部分覆盖、别名、端点、连续追问流程和两步费用均有离线回归。用户原问已从正常候选的两份200回执、实际function_call、确定性查询结果及25事件依据交叉核对，不以截图替代日志。用户调用不计助手E2E测试；本轮助手新增付费调用0。

已实际查看 `/tmp/MenuScores-build/QueryQA/normal-question.png`、`normal-question-dark.png`：用户原文直接回放，首句粗体正常，3段正文保持13pt，原始内容没有重写或调用模型。Markdown根因是原始成对星号夹着中文标点且下一段紧接中文，触发原生CommonMark闭合边界；有限规范化也处理闭合前少量空格。6项新增测试覆盖正常/轻微不规范标记、字面星号/代码、中文数字列表、长链接、原生引用、危险scheme、HTML和远程图片。

已实际查看 `/tmp/MenuScores-build/MarkdownQA/normal-question.png` 和 `normal-question-dark.png`：14pt小标题、粗体/斜体、无序/数字/中文序号、来源链接均保留，图片只显示说明，浅深色正文可读、蓝色发送与链接保持。没有HTML引擎和远程图片加载。原来源和25条查询依据展开入口不变。

`QueryQA/interactions.json` 及 `MarkdownQA/interactions.json` 的正常、前瞻、部分覆盖状态均通过同窗口进入复盘/证据/追问和返回；球队选择、球员表40pt滚动、复盘25pt滚动及草稿恢复。缺数据有明确失败态。首屏仍是620pt双比分卡＋一句总结＋全部原技术统计，分节和球队统计各自轻底色，七列表格未改。另用CUA实际点击正常隔离窗口复盘→Q2证据→原位返回→统计，头部与统计入口保持。四态和前瞻/缺数据截图只在本机验收，未上传。

额外助手在线连续追问及另一球员样本未执行。正常候选在菜单栏面板收起后，CUA getApp返回-10005 timeoutReached；已检查允许的系统菜单栏导航，未能取得目标，不盲点、不修改权限、不加生产调试后门，也不再次要求用户同一点击。父任务明确接受已审计用户真实请求加离线/原生验证作为本次安装依据，取消冗余付费样本门槛。此边界不代表全部线上E2E已完成。

# MenuScores 2.5.4 会话凭据与持久对话验收

final result: passed — 217项测试/31套件，mock凭据与离线多轮；不声称永不授权或全实体线上验证。

凭据根因已证：旧实现每次计数/生成重新取Key，一问两步共4次；显式解锁结果未保留；本地ad-hoc designated requirement为cdhash，重建可导致系统重新确认。新进程会话经条件锁合并读取，拒绝缓存至显式重试，屏幕/用户会话/休眠/Keychain锁定、退出或换Key清理，旧读取返回不能回填。连续两问的mock工作流8次访问只读底层1次；并发、负缓存、用户重试和锁定竞态回归通过。未读取真实Key诊断、未改ACL或系统授权、未创建签名凭据；未付费重复验收密码弹窗。新版本首次或重启/解锁后仍可能需要本人操作。

持久对话测试包含稳定轮次ID/问题/答案/当时日期/事实指纹/所选时段、跨场隔离、草稿、失败/取消/重启中断无假回答、旧回答原问缺失诚实标注、损坏文件不覆盖、旧快照不删新轮次、敏感凭据样式不落盘、长历史更正与有界摘录。原始历史不自动删，目录700/记录600权限，问题先落盘再付费，存储失败不自动重发。

原生两进程：CredentialQA/conversation-first-process.json PID4222完成原生发送、关闭重开恢复草稿、第二问收到前1轮；第二独立PID4426恢复同两轮UUID和“重启后继续问这场”草稿，model/keychain调用0。已实际看conversation-restored-overview、conversation-restarted与conversation-followup-dark像素，首屏有“对话”文字入口，620pt统计/两模块背景、详细复盘、Markdown、蓝发送与来源仍可读。CUA实际点击首屏“对话2”看完整恢复内容与草稿，再点“技术统计”返回；未发送新问题，不碰其他项目窗口。常规/前瞻/部分覆盖与失败态的interactions.json全项通过，切队/滚动与窗口数量保持。截图仅本机，不上传。

实体前提已有真正数据路径：按当前match名单（DNP含在内）匹配，再查本应用已有公开比赛的带日期身份观察。无唯一匹配/同名先澄清当前双方或场次，停止无谓伤病搜索；历史记录不能当成今天注册名单，不根据无统计断言离队或受伤。无詹姆斯硬编码。DNP、代词/同名/跨场、合法数字队名与日期校验有回归。新实体澄清未付费全面验证；已审计的用户原查询保持有效，满意回答不重写。正式安装保护与费用见.local-backups/terra-conversation-final-validation.json。

# MenuScores 2.5.5 首屏入口对齐

final result: passed

已按Library支持流程下载并实际查看用户红框附件`image(20261101-115438).png`（libfile_a20154d091788191974e3b0e90f3baf8），仅留本项目本机验收。根因：详细复盘原为13pt的Label图标布局，对话原为12pt纯文字，两者处于top对齐行而无共同文字/点击尺寸。

首屏两处改用同一NBAReviewInlineAction：13pt Regular，8pt箭头占位＋5pt文字间隔，24pt相同点击高度，两者都保留轻蓝色和导航箭头，按firstTextBaseline对齐；数字等宽，宽度随计数自然变化。统计字段、横排、列对齐、分节/球队模块、球员表及对话服务未修改。没有新窗口或模型请求。

217项既有测试/31套件与Release构建通过。EntryAlignmentQA/alignment.json实测0、1、4、12、128五种计数×浅深色共10例，所有显示中的两处文字框y=119pt、高16pt，两个按钮框高24pt、中线一致；0计数正确不显示对话。原生点击每入口一次均触发正确回调。实际看count-4-dark.png和count-128-light.png全卡像素，字号/基线/色彩一致，多位数没有挤掉元素；图只在本机，不上传。

EntryRegressionQA/interactions.json中完赛、前瞻、部分覆盖、失败态及完整复盘/证据/返回、切队和滚动保持全部通过，API/Keychain读取0。CUA另实际点击本项目离线首屏“详细复盘”→返回→“对话2”，已有记录/草稿可读，未发送新问题。正式安装签名与保护回读见.local-backups/terra-entry-final-validation.json。

# MenuScores 2.5.6 分析路由与本机配置

final result: passed — 231项测试/33套件与Release构建；真实迁移及在线问答另记录，不能以mock替代。

已实际查看用户125006附件与此前两问的公开回执：planner并未要求外查，执行器因整场部分覆盖强制search，calculator没有网页引用后，应用将模型本已给出的关键球员分析替换成伤病提示。现在当前问题显式分比赛分析/外部事实/混合；impact比较真实候选与胶着事件，回合前分差≤5不限时段，另列严格最后5分钟clutch。混合分析先保留本场判断，外部失败独立说明；媒体与记者原生引用可用且标来源类型/时间，不再官方域名白名单。旧坏提示历史保留，可显式重新分析。

本次用户明确批准项目外明文凭据后，新provider只读Application Support私有文件，700目录/600文件、拒绝symlink及不安全权限。一次迁移由正常app执行且保留原Keychain项；普通读取和重启缺文件/无效文件不会探测或回退Keychain。新增6测试覆盖两问8次读取与新实例、迁移一次、删除后无回退、取消不风暴、损坏文件/权限/symlink、并发；全为假凭据，未读取真实key诊断。安全日志仅计数与状态。

ReasoningFinalQA/interactions.json三场全部原生回归通过，正常、前瞻、部分覆盖及缺数据、复盘证据返回、同窗、草稿/滚动和切队保留，模型/Keychain调用0。已实际查看normal-score、normal-question和dark截图，旧提示与新增重试入口可读；首屏完整统计、两模块背景、七列表格与Markdown保持。CUA另实际切马刺→对话2→技术统计，球队保留；未发送mock外的模型请求。仅本机截图，无上传。最终真实迁移、在线质量及正式安装状态以terra-reasoning-final-validation.json为准。

# MenuScores 2.5.7 查询体积与球员角色

final result: passed — 236项测试/34套件、Release和本机离线回归；新角色线上问答边界独立列明。

已按Library流程实际看134706/134949/134950三张截图。报错并非持久对话丢比赛：真实planner req_afd4aff84128494c88dc15e3cc40b593已成功返回impact＋全场胶着球员＋Q4胶着球员三个合法查询，执行结果38,364字节越过30,000限制，误用recap.invalidData身份提示。通用共享box表/零metrics省略后29,912字节，全3组、球员及计算结果保留；超限后错误单列，不改事实保护。

真实原始缓存Dylan Harper id5037871 starter=true、didNotPlay=false、MIN39、PTS25；旧问答Athlete结构没有starter。现解析并传入本场首发/替补/未知与DNP，参与指纹，禁止用逐回合缺口覆盖已有首发标记。rotation的换入/换出、全场有界记录区间、首个已记录换入批次各有口径；近期角色从已有公开完赛缓存最多128份、每人6场读取，日期来源和有限样本明确，不把单场首发当赛季第六人结论。

PayloadRoleQA/payload-role-proof.json由新原生代码读取本场真实公开缓存生成，模型/Keychain调用0；interactions.json完赛/前瞻/部分覆盖、失败态、统计切队/滚动、复盘证据返回和草稿全部通过。已实际查看normal-question真实既有模型回答回放像素，Markdown、头部比分、来源和22事件入口保持；原生CUA另确认620pt首屏完整统计及两个模块背景。截图本机，不上传。此回放不冒充新线上验证。

# MenuScores 2.5.8 查询聚合与后台会话候选

final result: offline and native regressions passed; fresh normal-app online validation pending, not a claim of full end-to-end acceptance.

243项测试/36套件通过；Release构建及候选deep strict签名验证通过。测试覆盖三场真实公开fixture（灰熊国王、马刺森林狼、勇士湖人），全场/分节/胶着/换人/出场/重复查询及既有加时、更正、部分数据；不删聚合行。QueryPacket v2把球员、统计、聚合、口径、事件参与者和换人边界按字段表共享，事件细节为明确有界实例，未知与0分开。三场多形态均小于18KB目标，保留24KB硬保护。灰熊原49,971字节→17,757（完整40聚合行、28名球员、12/30事件实例）；马刺38,364→16,591（32聚合行、25球员、24/30实例）。原查询层仍限定1–3组，所有模型/搜索预算保护不变。

App级NBAReviewSessions持有按比赛的模型与任务。onDisappear只保存，数据刷新不会取消冻结输入的问答，完成按原提问资料指纹写入；显式取消即时保存cancelled状态。pending/failed/interrupted/cancelled在对话中可见，首屏入口计入未完成问题。冷启动中断不自动重发，正常关闭/切场后继续只限App仍运行；没有系统守护、新后台权限或自动付费重试。

BackgroundFinalQA/background-lifecycle.json：原生发送→pending先落盘→关闭窗口并移除hosting内容→另一个本项目窗口取得焦点/切场→同App会话后台完成并落盘→重新创建View显示同一结果。一次mock模型调用，API/Keychain0。已实际看background-pending与background-returned像素；回到原生四态时头部、比分、来源、输入、蓝发送保持，原统计模块和七列表格未改。其4场interactions.json（含前瞻/部分/缺数据）全部正常。新窗口首个几何偏差由QA宿主尚未settle导致，已等待布局后重新截取、实际确认头部完整；未改产品布局。截图仅本机。

真实最小全场/Harper/追问尚未助手执行：正常/Applications/MenuScores.app当前CUA返回-10005 timeoutReached，未绕过、未运行独立读key或ReviewLive harness。安装脚本要求真实在线验证证据再替换正式2.5.7，候选在ReviewCandidate待验。日预算最近$0.7365007，助手新增费用0。保留原明文项目外配置、钥匙串0读取及原2.4.9唯一回滚。


# MenuScores 2.5.8 正式安装收口

final result: passed — 用户验收通过并于2026-11-02明确批准安装；不冒称新增助手在线样本。

正式/Applications/MenuScores.app已替换为原已签名并验收的2.5.8 (34)，二进制SHA256仍为c101a0e4fa3462d4ec42a16a0ad4d7f89896b06f376628f8d7549cb86e870597。磁盘版本、deep strict签名与实际单实例进程路径均回读确认，运行来自/Applications而非候选路径。设置、收藏、固定场次及634张既有头像不变；70份文章、14份回答缓存与4份对话目录JSON逐字节保护通过。原2.4.9 (22)唯一回滚保留。新正式进程钥匙串读取0次，明文本机配置保留，未追加付费API测试。依据用户明确验收替代此前等待自动化在线验收的安装门槛，没有伪造assistant测试通过记录。安装/回读证据：.local-backups/terra-background-final-validation.json。
