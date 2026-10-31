# sing-box-boom 🚀

> 全面复刻并超越 **233boy/sing-box** 的全协议多节点现代管理套件。
> 支持 **VLESS-Reality / Hysteria 2 / TUIC v5 / Shadowsocks 2022** 多协议一机共存。
> 搭载 **全球高校独立源站动态优选引擎**（已彻底清退 Cloudflare），杜绝被借道白嫖流量。

---

## 🌟 协议支持矩阵

| 协议 | 传输层 / 特性 | 推荐应用场景 |
| :--- | :--- | :--- |
| **VLESS-Reality** | TCP + Vision 流控 + 高校动态优选防白嫖 | 最稳日常主力翻墙、防 GFW 主动嗅探 |
| **Hysteria 2** | UDP 暴力加速 / 极速抗丢包 / 自签 ECDSA | 晚高峰、跨洲长距离高丢包网络、游戏加速 |
| **TUIC v5** | QUIC 0-RTT 握手 / 内置 BBR 算法 | 移动网络、弱网环境下极速低延迟开屏 |
| **Shadowsocks 2022** | 现代抗重放加密 (`2022-blake3-aes-128-gcm`) | 路由器轻量客户端、纯净低功耗设备 |
| **多节点共存** | 支持一机同时开 4 个甚至更多不同协议端口 | 多客户端灵活分流、好友互不干扰 |
| **系统 BBR** | Linux 原生 BBR + FQ 算法一键开启 | 显著提升 VPS 的 TCP/UDP 传输速率与稳定性 |

---

## 🔍 独立神器：Reality SNI 智能雷达测速工具 (`sni-scout`)

> 专为 VLESS-Reality 量身定制的 **“偷域名体检雷达”**。无需安装任何代理服务，单文件即开即用！
> 智能分析 VPS 地理位置，自动排查 Cloudflare / Akamai 等边缘 CDN（杜绝借道白嫖），全方位实测 **TLS 1.3 / HTTP/2 握手支持与物理 RTT 延迟**，输出五星推荐榜单。

**在任意 Linux VPS 上直接一键运行：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/shangusl/sing-box-boom/main/sni-scout.sh)
```

**或者直接测试指定的域名：**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/shangusl/sing-box-boom/main/sni-scout.sh) test www.apple.com www.cityu.edu.hk
```

---

## 🚀 一键安装与管理命令 (全协议套件)

在你的 Linux VPS 上直接执行（GitHub 原生直链，秒级同步）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/shangusl/sing-box-boom/main/install.sh)
```

> **国内备用加速源**（如遇 GFW 阻断可使用）：
> `bash <(curl -fsSL https://cdn.jsdelivr.net/gh/shangusl/sing-box-boom@main/install.sh)`
> 或 `bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/shangusl/sing-box-boom/main/install.sh)`

---

## 🛠 命令行快捷指令体系 (独立命令 `sbox`，不与 233boy 冲突)

安装后，在终端随时直接敲专属快捷命令：

```bash
sbox               # 呼出交互式管理总控制台
sbox add           # 快速添加一个新协议节点 (Reality / Hy2 / TUIC / SS)
sbox modify        # 快速修改现有节点 (改端口 / 换高校SNI / 刷新凭据)
sbox del           # 快速删除指定的节点
sbox info          # 查看所有节点的配置信息、连接串与终端二维码
sbox bbr           # 一键开启系统内核原生 BBR 加速
sbox update        # 在线升级脚本自身或 sing-box 核心
sbox start         # 启动 sing-box 服务
sbox stop          # 停止 sing-box 服务
sbox restart       # 重启 sing-box 服务
sbox status        # 查看服务运行状态
sbox log           # 实时查看运行日志 (tail -f)
```

> **注**：本脚本专属使用 `sbox` 指令，彻底保留原版 233boy 的 `sb` 快捷方式，两者在系统内和平共存、互不干扰！

---

## 📄 开源许可
MIT License.
