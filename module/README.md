# vivocam-toolbox（模块内速查）

安装/卸载请在 KernelSU 管理器里操作。命令行入口：

```sh
sh /data/adb/modules/vivocam-toolbox/cam.sh {stock|x500|x500pm|port <family>|status|apply|clear}
sh .../cam.sh detect|info|ports|selfcheck|diagnose|probe|snapshot
sh .../cam.sh plugin list|install <zip|目录>|check|update|rollback|remove|build
sh .../cam.sh plugin export <family> [--verified]   # 导出已装插件为分享 zip（WebUI 版本卡也有按钮）
sh .../cam.sh addport <固件解包根> <family>   # 从镜像生成并安装移植包
```

- 切换约 15–20 秒，免重启、不清数据；异常时 `clear`，重启后属性失效点 WebUI「重新应用属性」
- **回原厂后录像等闪退** = 高→低版本相机数据残留（16.x 已升级库表，原厂相机迁移失败）→
  `clear` 重置相机数据（设置与 MiniVLog 草稿会清，DCIM 媒体不受影响）；`diagnose` 可自动归因
- 运行期数据（插件/库池/原厂备份/快照）在 `/data/adb/vivocam/`，升级/重装模块不丢
- 本模块不修改 `/vendor`、`/system`；卸载时 `uninstall.sh` 回放原厂属性
- 架构与限制：见仓库 `docs/ARCHITECTURE.md`、`docs/FINDINGS.md`
- 打包移植包（镜像结构/伪装码/打 zip）：见仓库 `docs/BUILD-PLUGIN.md`
