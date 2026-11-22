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

## 为用户配置出口

打开 `sb → 4) 用户管理`，选择 Hysteria2、VLESS Reality 或 AnyTLS Reality。用户列表会显示每位用户当前使用默认路由、独立出口还是共享出口。

- **个人出口**：选择用户编号，再选「配置独立出口」，粘贴 `vless://` 或 `ss://` 链接。可以在同一用户页查看个人链接、配置或移除绑定。
- **共享出口**：在用户列表按 `A` 或直接回车。确认导入后，会为当前入站设置共享出口，同时清除该入站已有的个人绑定。之后可重新设置个人出口，个人出口优先。
- 输入 `0` 返回上一级。标题和状态通过颜色区分，设置 `NO_COLOR` 可关闭颜色。

- VLESS 支持 TCP、WebSocket、普通 gRPC，以及链接中的 TLS 或 REALITY 参数。XHTTP 和 Xray 专有加密参数暂不支持。
- Shadowsocks 支持常见 `ss://` 链接和旧式 Base64 链接。带 SIP003 插件的链接暂不支持。
- 应用配置会重启 sing-box。现有用户的入站密码、UUID 和客户端链接可继续使用。
