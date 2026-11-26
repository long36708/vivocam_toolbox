# Changelog

## 6.0.4（当前）

- **新增 SPOOF_PROPS：插件自带附加伪装属性**（S60 移植实战，PD2419 实测启动即崩
  `IllegalArgumentException: the entries is not match the entryValues`）：
  部分相机功能按"产品系列"分支选资源配对（`DeviceUtil.isSSeries/isXSeries` 双源
  OR：系统属性 `ro.vivo.product.series` 或 MEAT 配置的 series）。项目码四属性伪装
  不到它，本机真值(X)与 MEAT(S) 并存 → 两判定同真 → 一拍得闪光灯
  entries/entryValues 3/2 错配。现 `port.conf` 可声明
  `SPOOF_PROPS="ro.vivo.product.series=S"`（构建器从镜像 build.prop 自动推导）；
  `props.sh` 快照/还原覆盖附加键（`SNAP_EXTRA_KEYS`，伪装值不进快照 + 旧快照
  自动迁移补采 + 还原回放），stock↔port 往返属性正确
- **修复库池 first-wins 污染：新插件同名库拿到旧代内容**（S60 初版实测
  libmmkv/libeglImageRender/libvivolog 等 14/48 实体库为 13.x 代内容）：
  `pool_build_from_image` 写 `.names` 后 first-wins 去重，而
  `plugin_build`/`pool_fill`/`plugin_export` 按**名字**反查池 → 跨代重名库被旧内容
  覆盖。names.lst 升级两列 `name md5`（构建时记录镜像内真值），三处物化按插件
  自带 md5 直取内容寻址池体；单列老清单走老路径完全兼容。重建后 96/96 对账全过
- **修复 diagnose 对 `UnsatisfiedLinkError` 的漏判**：原匹配式只认
  `not found`（dlopen 缺库），PD2419 实测 `No implementation found for
  ...Util.extractAlphaNative`（JNI 符号错配/缺库）被误判"未收录"。现按文本
  分流：`dlopen … not found`→库缺失；`No implementation found`→方法无实现
  （缺库或 DEX/so 版本错配，各自给处置，`cam.sh clear` 对后者无效）
- **WebUI 加载提速约 14×（9 插件实测 `cam.sh info` 22.56s → 1.63s）**：
  根因是 `conf_read` 对每个配置行 `printf|grep` fork、`_conf_set` 对每个值
  `printf|sed` fork，叠加 `info` 里 `port_find` 的 O(N²) 重扫，一次刷新产生
  3200+ 次 fork。现白名单 `^(A|B)$` 走零 fork 的 shell case 快路径（其他
  正则形式回退 grep），值不含单引号时直接 eval（含引号仍走 sed 转义，注入
  安全语义不变）；纯 shell 改动，输出逐字段比对无回归
- **diagnose 新增水印 NPE 签名**（FINDINGS §16）：跨机型切换后水印模板缓存
  （MMKV `global_pref_camera_watermark_tmpl_online_state`）无本机型默认模板 →
  `getCurrentTmpl` null → 2s 崩溃循环；归因 + 处置（`cam.sh clear` 重建缓存）
- **WebUI 新增模块版本号显示**：标题旁版本徽标（v6.0.4 · 10）+ 状态卡首行，
  一眼看出用户跑的是哪个版本
- **WebUI 新增「一键移植」**：输入固件解包根（如 `/data/RNA/RNA_S60`）即可在页面
  完成插件全流程——自动推导插件名（RNA_S60→s60）、预检布局/APK/lib64/磁盘余量/
  同名覆盖、`addport` 后台构建（MEAT/版本/库自动扫描）+ 日志轮询（3–8 分钟不冻屏）、
  完成后插件直接出现在切换卡片
- diagnose 补充 MiniVLog DB 降级签名（16.x 移植相机升级库表后回原厂，
  迁移重建同名列失败）

## 6.0.3

- **修复切换后相机闪退、需硬重启才恢复**（真机实测：切到移植包使用后切回原厂，
  原厂相机闪退，硬重启正常）：属性只对"之后新起的进程"生效，原流程只
  `force-stop` 相机 App，未重启常驻的 `camerahalserver`/`cameraserver`——它们
  在伪装态下初始化，切回原厂后与原厂相机/还原属性错位（HAL 侧 SATController
  崩溃同源）。stock/port/apply 切换现在会 kill 这两个服务，由 init 按新属性
  重新拉起，免重启闭环真正闭合
- **切换失败回滚时同步恢复属性**（配套 6.0.2 的 state 回滚）：避免
  state=port 但属性=stock（或反之），导致下次打开相机 MEAT 错位闪退

## 6.0.2

- **修复分享场景 lib=0 / 相机启动闪退**（跨设备实测发现）：`plugin_install` 合并
  自包含插件时只按 md5 拷贝 `.so` 文件体、从未登记 `libpool/.names` 的"名字→md5"
  索引；导出方本机因 `addport` 从镜像建池时已写索引而不受影响，全新接收方
  `.names` 为空 → `pool_fill` 按 names.lst 全查不到 → 一个库都铺不出来 →
  `UnsatisfiedLinkError: dlopen failed: library "libmmkv.so" not found`。
  安装循环改用 `pool_add`（拷体+登记索引）并先 `pool_init`；幂等，重复安装不会
  产生重复映射。已用旧包安装的接收方：刷本版后重新导入同一插件 zip 再切换即可
- **diagnose**：链因含 `UnsatisfiedLinkError ... not found` 时单独归因"native 库缺失"
  并给出处置（重装/apply/手工铺库），不再误报"重启后首开一过性"
- **pool_fill 兼容 CRLF 清单**：Windows 手工打出的 names.lst 行尾 `\r` 会让
  按名查池全落空、铺出 0 个库；循环里剥掉行尾 CR（回归测试覆盖 LF/CRLF 两种）
- **修复回原厂失败 `INSTALL_FAILED_VERSION_DOWNGRADE`**：`pm install -r -d` 的
  `-d` 只放行 debuggable 应用降级，正式签名的系统相机从 16.x 回 13.x 必被拒；
  命中该错误时先 `pm uninstall -k --user 0`（保留数据、卸载用户级更新，系统分区
  原厂应用自动接管）再重装。跨移植包降级（如 210→203）同走此路径
- **切换失败回滚 state**：`switch_stock/switch_port` 原在安装**之前**写 state，
  安装失败后 info 仍谎报目标态（导致守护进程按错状态铺库、旧 WebUI 卸载守卫
  被"已回原厂"骗过而误删插件）；失败时恢复切换前的 mode/port
- **WebUI 卸载守卫改用切换命令真实结果**：`doSwitch` 返回是否输出"完成"，
  `doRemove` 只在成功时才继续卸载；不再依赖会被提前改写的 state

## 6.0.0

- **SCHEMA=2：port zip 可选 `profiles/` 随包**（`plugin export` 自动附带本机用户 profile；
  内置 profile 自动跳过；手工组包亦可）。
  安装时落到 `/data/adb/vivocam/plugins/profiles/`（profile_select 用户目录优先）；
  同名保留本地版本（本地可能带实测回填的 KNOWN_*_MODES，随包版不许静默覆盖）；
  坏 profile 只跳过不阻断安装。旧模块收到 SCHEMA=2 包会明确报"请先升级模块"
- **`plugin export --ver <归档版本>`**：从 `.versions/` 归档直接导出历史版本，
  不必先 `plugin use` 切回

- **插件导出分享**：`cam.sh plugin export <family> [--verified]` + WebUI 版本卡「导出」按钮。
  把已安装插件打成自包含 zip 落 `/sdcard/Download/vivocam/`（与导入目录一致，可往返验证），
  不需要解包镜像；legacy 注册目录自动合成 port.conf（沿 migrate 继承模式 + 现算 sha256）。
  `--verified` 需本机 profile 真实匹配才允许背书 TARGETS（`_generic`/`forced` 拒绝）；
  库池缺库即拒绝导出并列缺失名；产物先过 `plugin_validate` 六步自检再打包。
  **store-only zip 兜底**（真机实测 KSU/Magisk 构建 busybox 无 zip applet）：CRC 取自
  gzip 尾部 8 字节（RFC 1952），头部 hex 拼接 + `xxd -r -p` 还原，零依赖产 zip。
  设计定稿见 `docs/PLUGIN-EXPORT.md`。原二阶段两项已随本版落地（见上两条）
- **未收录机型一键生成 profile**：`cam.sh profile-gen` + WebUI「仅诊断模式」卡片按钮。
  自动采集机型身份（MATCH_KEYS/SOC）/原厂相机路径与库数（stock_apk_resolve 自动定位）/
  HWBBK_MAP（解析 ro.build.expect.hardware）/HAL 格式，生成后立即验证 MATCH_KEYS 命中
  （失败不留半套）；已匹配机型与同名文件拒绝生成——自动档不许遮蔽已验证的内置
  profile，也不许覆盖实测回填
- **diagnose 双通道归因**：新增 logcat crash 缓冲区扫描（Java 闪退层，tombstone 抓不到），
  内置签名含 `duplicate column name`（高→低版本回落的数据残留 → 处置 `cam.sh clear`，
  PD2419 实测：16.x 相机升级 minivlog 库表后，原厂相机迁移重建同名列失败致录像闪退）
- **WebUI「清除数据」按钮**：`cam.sh clear` 上屏——确认框写明代价（设置重置、
  MiniVLog 草稿丢失、DCIM 不受影响）与适用场景（高→低版本数据残留闪退），
  引导不确定时先「崩溃归因」
- **WebUI 用户插件「卸载」徽标**：仅用户插件卡显示；激活态引导先回原厂，
  校验 `mode=stock` 成功后才自动 `plugin remove`，杜绝 state 残留指向已删插件

## 5.0.0

插件化架构，机型解绑：

- **资源三分离**：主模块 / 目标机 profile / 移植包插件；模块 zip 不含任何固件二进制
- **内容寻址库池**：跨移植包按 md5 去重（两源合并实测 78→80 个唯一内容，214MB→86MB）
- **原厂库首启自备份**：`cp -L` 解引用 `/system` 的实体+符号链接混合布局，取代随包分发
- **机型自动识别**：只用未被伪装污染的属性（`ro.product.name` 等）多键匹配；未匹配机型
  安全降级为「仅备份 + 诊断」，不伪装、不铺库
- **原厂属性快照回放**：开机采集 `/proc/cmdline`（bootloader 注入、resetprop 改不到）
  + 快照文件，切回原厂在任何机型上都还原该机真值，无硬编码
- **插件生命周期**：`plugin install / check / update / use / rollback / remove / build`；
  安装六步校验（结构 / SCHEMA / MODULE_MIN / APK sha256 / `$$MEAT` 复核 / 清单数量）
  + 原子落盘 + 版本归档
- **conf 非执行解析器**：键白名单 + 值转义，外部插件数据不可执行（注入测试通过）
- **新目标机填空模板** `profiles/x100.profile`：占位符不匹配任何真实属性（未填完全惰性），
  任何 vivo 机型复制改名即用；解析器支持「引号值 + 行尾注释」
- **诊断工具化**：`probe`（HAL scene 差集，标注为可疑上界而非预测）、
  `diagnose`（tombstone 自动归因到已知缺陷）、`selfcheck`
- **WebUI**：profile × 插件动态生成卡片；可更新徽标、未验证机型黄条、本地目录导入

## v4

- 免重启三向切换（原厂 / X500 / X500PM）+ KernelSU WebUI（单文件、`nextPaint`
  解决 `ksu.exec` 阻塞主线程的渲染问题）
- 开机版本感知守护（`cam_state` 驱动，15s 检查重建相机 native 库目录）
- 机型伪装四属性 resetprop；重启后「重新应用属性」恢复

## v1–v3（诊断与证伪期，见 docs/FINDINGS.md）

- 确认 X500 系相机 App 层可移植（同平台 MTK）：`UnsatisfiedLinkError` 修复、
  106/107 库布局、水印库真名 `libvivo.watermark.process`
- 证伪 HAL 层路线：单指令 patch 打地鼠、vendor 库整体替换 cameras=0
  （vcf 框架与 5 摄拓扑编译期绑定）
- 破译 `.dat` HAL 配置 = 循环 XOR 明文 XML（密钥 `mysecretkey`）
