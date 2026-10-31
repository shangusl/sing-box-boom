
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


---

## 📄 开源许可
MIT License.
