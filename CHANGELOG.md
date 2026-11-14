# Changelog

## v6（当前）

- **SCHEMA=2：port zip 可选 `profiles/` 随包**（`plugin export --with-profile` 或手工组包）。
  安装时落到 `/data/adb/vivocam/plugins/profiles/`（profile_select 用户目录优先）；
  同名保留本地版本（本地可能带实测回填的 KNOWN_*_MODES，随包版不许静默覆盖）；
  坏 profile 只跳过不阻断安装。旧模块收到 SCHEMA=2 包会明确报"请先升级模块"
- **`plugin export --ver <归档版本>`**：从 `.versions/` 归档直接导出历史版本，
  不必先 `plugin use` 切回；WebUI 导出确认框加"附带本机 profile"询问（条件显示）

- **插件导出分享**：`cam.sh plugin export <family> [--verified]` + WebUI 版本卡「导出」按钮。
  把已安装插件打成自包含 zip 落 `/sdcard/Download/vivocam/`（与导入目录一致，可往返验证），
  不需要解包镜像；legacy 注册目录自动合成 port.conf（沿 migrate 继承模式 + 现算 sha256）。
  `--verified` 需本机 profile 真实匹配才允许背书 TARGETS（`_generic`/`forced` 拒绝）；
  库池缺库即拒绝导出并列缺失名；产物先过 `plugin_validate` 六步自检再打包。
  **store-only zip 兜底**（真机实测 KSU/Magisk 构建 busybox 无 zip applet）：CRC 取自
  gzip 尾部 8 字节（RFC 1952），头部 hex 拼接 + `xxd -r -p` 还原，零依赖产 zip。
  设计定稿见 `docs/PLUGIN-EXPORT.md`。原二阶段两项已随本版落地（见上两条）
- **diagnose 双通道归因**：新增 logcat crash 缓冲区扫描（Java 闪退层，tombstone 抓不到），
  内置签名含 `duplicate column name`（高→低版本回落的数据残留 → 处置 `cam.sh clear`，
  PD2419 实测：16.x 相机升级 minivlog 库表后，原厂相机迁移重建同名列失败致录像闪退）
- **WebUI 用户插件「卸载」徽标**：仅用户插件卡显示；激活态引导先回原厂，
  校验 `mode=stock` 成功后才自动 `plugin remove`，杜绝 state 残留指向已删插件

## v5（当前）

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
