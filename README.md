# Sing-box 多协议一键部署脚本

一个强大的 Sing-box 自动化部署工具，支持SS/HY2/TUIC/VLESS Reality/AnyTLS Reality 协议自选部署。

---

## ✨ 主要特性

### 🎯 部署机功能

- ✅ **一键安装** - 自动部署 Sing-box 最新服务端
- ✅ **自动生成** - 自动生成 密钥和配置文件，Reality 自选或默认SNI
- ✅ **多系统支持** - 支持 Alpine, Debian, Ubuntu, CentOS, RHEL, Fedora 等操作系统
- ✅ **开机自启** - 自动配置 Systemd / OpenRC 开机自启，崩溃自动拉起服务端
- ✅ **连接 IP** - 自动获取公网 IP 或手动输入 连接IP/DDNS域名 并生成客户端链接
- ✅ **管理工具** - 输入 sb 指令进入管理界面查看节点链接、重置端口、服务端控制查看等功能

## ✅ 一键部署命令

安装全功能 sing-box：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/brian952700/singbox-deploy/main/install-singbox-yyds.sh)"
```

## 多用户管理

在 VPS 上以 root 运行 `sb`，选择 **4) 用户管理**，然后选择入站。支持 Hysteria2、TUIC、VLESS Reality 和 AnyTLS Reality。可以新增用户、查看个人链接或删除用户。每个入站至少保留一个用户。Shadowsocks 沿用原有单账号配置。

已有安装请运行下面的命令来更新管理面板。这个升级步骤保留现有账号和配置，服务继续运行。新增或删除用户时，面板会先校验新配置，再重启服务。

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/brian952700/singbox-deploy/main/install-singbox-yyds.sh)" -- --update-panel
```
