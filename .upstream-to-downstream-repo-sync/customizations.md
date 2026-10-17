<!-- customizations-schema: 1 -->

## 维护约定

当前上下游身份、目标分支与检查策略以 config.yaml 为准。用户本地定制默认全部保留，由 Skill 增量维护；覆盖状态不等于测试通过。

## 初始核查（历史记录）

初次接入时暂无本地定制；此结论已由下方增量清单更新。接入前工作区干净；下游全部四个远端分支（development、main、gh-pages、fix/layout-lockout-parked-divider）逐一与上游同名分支比较，提交 SHA 完全一致。功能修复分支属于上游已有内容，不属于下游独有定制。上次同步仅新增同步配置和本清单，未更改产品行为、应用身份或工作流。

保留 LICENSE、CREDITS.md 和源码署名。没有 Git 子模块或 LFS 属性；Xcode 的 SwiftPM 依赖仍需外部来源，未声明可离线独立构建。远端可见性未通过平台接口核实，因此配置不设可见性预期。

## 初次接入的验证要求与记录（历史）

自动发现采用默认模式，不在配置或清单中固化完整命令列表。已审查共享 Thaw scheme、ThawTests、Xcode Build Phases、CI 和贡献指南。两个 XPC helper 由应用目标依赖构建，其测试位于 ThawTests，无须因辅助 scheme 没有独立测试而认定工程没有测试。

接入仅增加配置与清单，产品构建和行为测试上次同步未执行；与上游 CI 对无代码变更跳过构建的规则一致。后续修改产品或同步源码时，应根据变更运行 macOS 上 Thaw scheme 的测试，并采用 CI 已定义的构建参数，审查运行对用户状态的影响。项目另有 ThawCtl 与 Fuzzing Swift 包，涉及这些目录时须继续审查其入口，不能将静态发现候选视为完整覆盖。

已有 Xcode 27.0；依赖获取、编译、测试及手工菜单栏验收尚未验证。上游发布及主要 CI 作业有 thaw-app/Thaw 身份条件，下游不能期待自动复用上游 CI 成功记录；需要启用下游 CI 时另行适配。

完整 SHA、远端比较和恢复入口保存在 Git 本地元数据中；配置和清单结构校验不代表产品测试通过。

## 上次同步核查（历史记录）

本地目标分支已包含本地安装与 macOS 27 定制提交，原“暂无本地定制”不再代表当前状态。下列覆盖状态指配置指定的本地目标分支；下游远端尚未包含这些本地提交。上次同步候选仅合并上游发布版本与变更日志，未改动产品实现。其他本地分支只有初始化恢复点，其内容是当前分支祖先；本地缓存中的其他下游远端分支与对应上游分支相同，不代表上次同步重新验证了这些非目标远端分支。

### C001：Apple Silicon 本地构建与稳定签名安装

- 行为契约：默认一条命令完成 arm64 构建安装，固定复用 Thaw 专用证书；不使用其他应用证书，不增加必填参数；整包替换且不保留备份，临时文件位于工程目录；仅首次签名迁移处理旧授权。
- 来源与实现证据：本地构建定制提交 0006b76f；当前目标分支已包含，合并上游时保持脚本不变。
- 证据路径：`scripts/install-local.sh`、`scripts/local-signing-identity.sh`
- 目标覆盖状态：已纳入
- 验证要求：脚本语法、arm64 构建；实际安装及权限保留须单独验收，不将安装作为同步检查隐含执行。
- 验证记录：上次同步脚本语法通过；未执行安装、证书创建或授权重置。
- 决策记录：保留用户无备份、工程内暂存和专用签名要求。

### C002：macOS 27 菜单栏发现、隐藏、排序与预览

- 行为契约：保留原三分区界面；使用 AX 项目发现、按应用隐藏、宿主坐标排序与捕获；隐藏项目展开后位于显示项目左侧；失败不得将目标顺序当作实际位置；不再对 macOS 27 显示不支持警告。
- 来源与实现证据：本地定制提交 d4866112；运行时私有隐藏接口仍有通知中心、多显示器和同应用整体隐藏限制，不能扩大为完全适配承诺。
- 证据路径：`Thaw/MenuBar/AccessibilityBackend`、`Thaw/Utilities/ScreenCapture.swift`、`Thaw/Utilities/MacOSCompatibilityWarning.swift`、`ThawTests/MenuBar/Items/AccessibilityOrderTests.swift`、`ThawTests/MenuBar/Items/MenuBarVisibility27Tests.swift`、`docs/MACOS27.md`
- 目标覆盖状态：已纳入
- 验证要求：发现、宿主匹配、区域隐藏、边界与实际顺序测试；系统物理隐藏、两屏排序及预览需实机验收。
- 验证记录：上次同步隔离候选的 3343 项测试、378 个套件全部通过；历史实机结果见适配文档，不冒充上次同步验收。
- 决策记录：默认保留实验性实现和已知限制，不替换成应用列表界面。

### C003：简繁中文国际化校验

- 行为契约：保留布局、触发器、显示器等中文补全，以及占位符和翻译状态校验；维护新增提示的简繁中文。
- 来源与实现证据：本地定制提交 d4866112 的字符串目录、检查工具及界面提示。
- 证据路径：`Thaw/Resources/Localizable.xcstrings`、`scripts/check-localizations.py`
- 目标覆盖状态：已纳入
- 验证要求：翻译状态、参数类型和位置校验；新增文案需按编译器提取结果复核。
- 验证记录：上次同步 1484 条字符串检查通过。
- 决策记录：中文为本地说明主体语言，保留其他语言资源。

### C004：配置页面空间与图标展示

- 行为契约：扩大配置内容区域，减少两侧空白；去除应用图标占位外框，保留拖动范围和原生三分区操作。
- 来源与实现证据：本地定制提交 d4866112；与菜单栏底层适配分开保留。
- 证据路径：`Thaw/Settings/SettingsDetailStyle.swift`、`Thaw/UI/IceUI/IceForm.swift`、`Thaw/MenuBar/LayoutBar/LayoutBarItemView.swift`
- 目标覆盖状态：已纳入
- 验证要求：构建及相关视图回归；不同窗口宽度下的显示与拖放需人工验收。
- 验证记录：上次同步 arm64 Debug 构建及全量回归通过；未进行上次同步界面操作验收。
- 决策记录：保留用户要求的空间利用率和无外框图标。

### C005：新项目定位、配置恢复、布局重置与触发器

- 行为契约：新项目按标记定位，首次迁移不移动已有项目，同应用继承分区；配置恢复分区及可定位项目顺序；重置使用新版分区事务；临时触发器不污染持久布局；图像条件仅用新鲜可见采样，隐藏时不使用缓存预览触发。
- 来源与实现证据：本地定制提交 d4866112；后启动应用的配置补排、右键代执行、自动收起及分隔线仍未完成，不能标为上游已承接或已验收。
- 证据路径：`Thaw/MenuBar/AccessibilityBackend/MenuBarItemManager+AccessibilityNewItems.swift`、`Thaw/MenuBar/MenuBarItems/MenuBarItemManager/MenuBarItemManager+ProfileApply.swift`、`Thaw/MenuBar/MenuBarItems/MenuBarItemManager/MenuBarItemManager+LayoutReset.swift`、`Thaw/MenuBar/MenuBarItems/MenuBarItemManager/MenuBarItemManager+Triggers.swift`、`Thaw/MenuBar/MenuBarItems/MenuBarItemImageCache+Capture.swift`、`ThawTests/MenuBar/Items/AccessibilityNewItemsTests.swift`、`docs/MACOS27.md`
- 目标覆盖状态：已纳入
- 验证要求：迁移、去重、锚点、配置排序、重置过滤与存储隔离测试；实际新项目位置、配置切换、重置目标和图像触发需人工验收。
- 验证记录：上次同步隔离候选的 3343 项测试、378 个套件全部通过；保留适配文档中未完成实机验收范围。
- 决策记录：默认保留；上次同步版本同步不借机补做功能或重置用户布局。

上次同步校验补充：配置结构、定制清单严格校验、SwiftLint 输入清单一致性和差异空白检查通过。未安装 SwiftLint，因此未运行完整规则检查；不能视为完整 CI 通过。沙箱内首次测试因 SwiftPM 缓存写权限失败，经授权在沙箱外重试后成功。配置指定 local 交付，已将通过验证的同步候选安全快进合入配置指定的本地目标分支，定制清单同步进入目标。远端未推送；同步分支、独立工作树及恢复引用保留。


## 本次同步核查

本次以已提交的本地目标为基线同步配置指定的上游分支。所有其他本地分支均为该基线祖先，不含额外待整合定制；工作区干净。上游产品变更集中于无明确所属进程项目的拖动和间距确认，其余主要为版本、文档与 CI。macOS 27 的 AX 移动入口继续优先分流，本地安装、中文资源、配置空间和触发器行为均保留。

本次候选已按用户明确指令安全快进合入本地 development，保留上游合并历史。用户对上游分支配置的未提交编辑逐字节保留，未纳入提交；该配置当前分支为空，下次同步前仍需补全。本次 C001–C006 对应的 arm64 Debug 构建与全量 3363 项测试（379 个套件）、严格 SwiftLint 0.63.3、脚本语法、1484 条中文资源、SwiftLint 输入清单一致性、更新源生成的 10 项测试全部通过。SwiftFormat 已执行；无关文件格式变化已撤回，仅保留定制路径的规范修正。首次沙箱测试因 SwiftPM 缓存权限失败，已在授权后重试。随后按用户要求完成本地 Release 构建安装，签名校验与启动检查通过，复用原证书且未重置权限；真实菜单栏布局未做本次验收。

### C006：macOS 27 稳定身份补全与单项定位

- 行为契约：临时 AX 身份补全稳定标识时保留设置引用；重复标识与多图标应用不误合并；已见应用重启后仍按默认位置处理；单项手动排序优先移动目标项目并保留其他项目相对顺序。
- 来源与实现证据：本地提交 eebb411d 已进入目标分支；同步候选保留全部实现，并以可选值访问替代强制解包，保持已有过滤与排序契约。
- 证据路径：`Thaw/MenuBar/AccessibilityBackend/AccessibilityMenuBarIdentity.swift`、`Thaw/MenuBar/AccessibilityBackend/MenuBarItemManager+AccessibilityNewItems.swift`、`Thaw/MenuBar/AccessibilityBackend/MenuBarItemManager+AccessibilityOrder.swift`、`ThawTests/MenuBar/Items/AccessibilityIdentityTests.swift`、`ThawTests/MenuBar/Items/AccessibilityNewItemsTests.swift`、`ThawTests/MenuBar/Items/AccessibilityOrderTests.swift`、`docs/MACOS27.md`
- 目标覆盖状态：已纳入
- 验证要求：身份唯一性、重启后新项目定位和单项排序回归；真实 AX 拖动和多显示器行为需实机验收。
- 验证记录：本次最终源码的 arm64 Debug 构建、3363 项测试和 379 个套件全部通过；真实 AX 拖动和多显示器未做本次验收。
- 决策记录：默认保留；不将实验性 macOS 27 适配替换成上游 3.x 架构。
