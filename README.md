# mihomo-next

Mihomo + Reality + Caddy + Reader 一键安装脚本

## 使用

```bash
wget -N https://raw.githubusercontent.com/1432433gg/mihomo-next/main/install.sh && chmod +x install.sh && ./install.sh
```

如果提示 `wget: command not found`，先运行 `apt update && apt install -y wget`。

两种安装方式：

- 「1. 安装（Mihomo + Reality + Caddy + Reader）」：输入域名和端口（默认 443），UUID 和 Reality 密钥自动生成，short-id 为空。
- 「2. 安装（Mihomo + Shadowsocks 2022）」：只装 Mihomo，输入端口（默认是 10000-32767 之间的随机端口），加密方式 2022-blake3-aes-128-gcm，密码自动生成，开启 UDP，不需要域名。

两种只能选一种：装了其中一种后再选另一种，脚本会提示并停止；要换请重装系统。重复安装同一种可以，会沿用原来的 UUID、密钥或密码。

## 要求

- Debian 10+ 或 Ubuntu 20.04+，amd64 / arm64，root 用户
- 域名已解析到服务器，80 端口能从外网访问（申请证书用；只装 Shadowsocks 2022 时不需要）

## 菜单

```
—————— 安装 ——————
1.  安装（Mihomo + Reality + Caddy + Reader）
2.  安装（Mihomo + Shadowsocks 2022）
3.  升级 脚本
—————— 配置变更 ——————
4.  修改 UUID / 密码
5.  修改端口
—————— 查看信息 ——————
6.  查看连接信息
7.  查看服务运行状态
—————— 其他 ——————
8.  更新 / 指定版本 Mihomo
9.  更新 / 指定版本 Caddy
10. 更新 / 指定版本 Reader
11. 重新申请 SSL 证书
12. 更新 Linux 内核
13. 安装 BBR 加速
0.  退出
```

## 组成

| 组件 | 说明 |
| --- | --- |
| Mihomo | VLESS + Reality 服务端，默认 443 端口；只装 Shadowsocks 2022 时是 Shadowsocks 服务端，默认随机端口（10000-32767）；所有流量直连出站 |
| Caddy | 监听 80 端口（申请证书、跳转 HTTPS）和本机 8443（Reality 的回落目标），自动申请和续期证书，反代 Reader |
| Reader | Docker 运行，只在本机 8080 监听，由 Caddy 反代 |
| chrony | 使用谷歌时间服务器，时区 Asia/Shanghai |

所有组件默认不记录日志。

## Reader

- 安装完成后打开 `https://你的域名`（端口不是 443 时要带上端口），点「注册」创建账号
- 第一个注册的账号就是管理员
- 默认只能注册 1 个账号，注册之后别人就无法再注册
- 用户名至少 5 位，只能用小写字母和数字；密码至少 8 位
- 必须登录才能使用

Reader 的更多用法和设置见 [reader-next](https://github.com/1432433gg/reader-next)。

## 目录

```
install.sh                    安装脚本
mihomo/vless-reality.yaml     Mihomo 配置（VLESS + Reality）
mihomo/shadowsocks-2022.yaml  Mihomo 配置（Shadowsocks 2022）
caddy/caddy.json              Caddy 配置
reader/reader.env             Reader 设置
docker/docker-compose.yaml    Reader 的 Docker 配置
systemd/mihomo.service        Mihomo 服务
systemd/caddy.service         Caddy 服务
chrony/google.conf            谷歌时间服务器
apt/archive.list              Debian 10 / 11 的归档软件源
LICENSE                       MIT 许可证
```

配置文件里的 `{{DOMAIN}}`、`{{PORT}}` 等在安装时自动填入。只下载 `install.sh` 运行时，脚本会从本仓库下载这些文件。

## 文件位置

| 路径 | 内容 |
| --- | --- |
| `/etc/mihomo/config.yaml` | Mihomo 配置 |
| `/etc/caddy/caddy.json` | Caddy 配置 |
| `/var/lib/caddy` | 证书 |
| `/etc/mihomo-next/info.conf` | 安装方式、域名、端口、UUID、密钥、Shadowsocks 密码 |
| `/etc/mihomo-next/docker-compose.yaml` | Reader 的 Docker 配置 |
| `/etc/mihomo-next/reader.env` | Reader 设置 |
