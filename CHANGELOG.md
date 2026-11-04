# Changelog

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
