# 用 Git Bash 把本项目上传到个人 GitHub 公开仓库 —— 完整操作指南

> 本指南假设：你在 Windows 上使用 Git Bash，仓库本地路径为
> `C:\Users\23154\Desktop\deepseek-pet`，目标是在你的 GitHub 账号下新建一个
> **公开仓库**并把代码推上去。整个过程只需 Git Bash，网页操作只有"新建仓库"一步。
>
> 注意：`ref/`、`state/`、`build/`、`debug.log`、`*.docx` 已被 `.gitignore`
> 排除，不会被上传；`docs/images/` 中的截图会上传（README 需要它们）。

---

## 第 0 步：确认已安装 Git

打开 Git Bash，输入：

```bash
git --version
```

能打印版本号即可。没有安装的话，到 <https://git-scm.com/download/win> 下载安装（一路默认即可）。

## 第 1 步：配置 Git 身份（只需一次，本机已完成）

本机 Git 已配置好署名，可以跳过这一步；如需核对或修改：

```bash
git config --global user.name     # 当前为 Sun Haiming
git config --global user.email    # 当前为 haiming.sun33@gmail.com

# 如需修改：
git config --global user.name "你的名字或昵称"
git config --global user.email "你的GitHub注册邮箱"
```

> 邮箱建议使用 GitHub 注册邮箱（当前配置的 `haiming.sun33@gmail.com` 与 GitHub 账号绑定后，提交会正确归属到你的头像和贡献统计）；如果想保护隐私，可在 GitHub → Settings → Emails
> 里启用 `Keep my email addresses private`，然后使用形如
> `12345678+username@users.noreply.github.com` 的代发邮箱。

## 第 2 步：在 GitHub 上新建空仓库

1. 浏览器打开 <https://github.com/new>；
2. Repository name 填 `DeepSeek-Harness-Pet`；
3. 选择 **Public**；
4. **不要**勾选任何初始化选项（不要 Add README / .gitignore / License，本地已经全有）；
5. 点击 **Create repository**，停留在随后出现的页面（里面有仓库地址），先不要做它提示的命令——本指南下面会给你完整命令。

> 你的仓库地址将是：`https://github.com/Hai-mian-33/DeepSeek-Harness-Pet.git`
> （若他人参考本文，请把 `Hai-mian-33` 换成自己的 GitHub 用户名。）

## 第 3 步：初始化本地仓库并完成首次提交

在 Git Bash 中执行：

```bash
cd /c/Users/23154/Desktop/deepseek-pet

# 以当前目录初始化 git 仓库（该目录尚不是 git 仓库，这条是安全的）
git init

# 查看将被提交的文件，确认没有 ref/、state/、build/、debug.log、*.docx
git add .
git status

# 首次提交
git commit -m "feat: 蓝鲸小深 v1.0 —— DeepSeek Harness 桌面宠物（含中英双语界面）

- 桥接层：按字节偏移尾读 Harness 会话日志与投影缓存，零依赖 Node 实现
- 界面层：WPF 透明窗口，拖拽/贴边/惯性/多屏，状态气泡与对话列表面板
- 双语系统：右键菜单随时切换 中文/English，配置持久化，经控制通道同步到桥接层
- 自托管看门狗：随 Harness 自动启停；96 个单元测试全部通过"

# 把默认分支命名为 main（旧版 Git 也兼容的写法）
git branch -M main
```

## 第 4 步：关联远程仓库并推送

```bash
git remote add origin https://github.com/Hai-mian-33/DeepSeek-Harness-Pet.git

# 确认关联成功
git remote -v

# 推送到 main 分支（-u 建立跟踪关系，以后只需 git push）
git push -u origin main
```

### 首次推送时的登录

弹出 GitHub 登录窗口时：

* **推荐**：选 "Sign in with your browser"，浏览器授权后自动继续；
* 如果只在终端里提示输入密码：GitHub 已不接受账号密码，这里要填 **Personal Access Token（PAT）**，不是登录密码。没有 PAT 的话：
  1. GitHub → 右上角头像 → **Settings → Developer settings → Personal access tokens → Tokens (classic)**；
  2. **Generate new token (classic)**，勾选 `repo` 权限，生成后**立即复制**（只显示一次）；
  3. 推送时 `Password:` 处粘贴该 token。

推送成功后刷新 GitHub 仓库页面即可看到全部代码、README 和截图。

## 第 5 步：以后更新代码的日常流程

```bash
cd /c/Users/23154/Desktop/deepseek-pet
git add .                       # 或 git add <具体文件>
git commit -m "fix: 描述这次改动"
git push                        # 已建立跟踪，无需再带参数
```

## 常见问题

**1. `remote: Repository not found` 或 403**
用户名或仓库名拼错、仓库不是你账号下的、或 token 没勾 `repo` 权限。重新检查第 2、4 步；必要时先删掉重连：
```bash
git remote remove origin
git remote add origin https://github.com/Hai-mian-33/DeepSeek-Harness-Pet.git
```

**2. 提示 `failed to push some refs`（远程非空）**
多半是建仓库时勾选了初始化文件。把远程内容合并进来再推：
```bash
git pull origin main --allow-unrelated-histories --no-edit
git push -u origin main
```

**3. 中文文件名显示为转义数字**
执行 `git config --global core.quotepath false` 后 `git status` 即可正常显示中文。

**4. 每次推送都想免输 token**
```bash
git config --global credential.helper manager
```
（Git for Windows 自带凭据管理器，首次输入后长期记住。）

**5. 想改仓库名 / 换账号**
改完后更新远程地址即可：
```bash
git remote set-url origin https://github.com/Hai-mian-33/DeepSeek-Harness-Pet.git
```

**6. 确认没有敏感信息被上传**
```bash
git ls-files | grep -E "^(ref/|state/|build/)" ; echo "无输出即安全"
```
`ref/`（DeepSeek Harness 内部参考代码）、`state/`（运行时状态）、`build/`（本机日志与临时截图）都不会进入仓库——这正是开源前必须排除的内容。

---

## 本仓库推荐的开源配置（网页上顺手设置）

* 仓库页 → **About** 齿轮 → Description 填 `DeepSeek Harness 桌面宠物 · Bilingual desktop whale pet (zh-CN/English)`，Topics 加 `deepseek` `desktop-pet` `wpf` `powershell` `windows`；
* **Settings → General → Features** 保持默认（Issues 勾选即可）；
* 首页已有 `README.md`（英文）+ `README.zh-CN.md`（中文）+ `LICENSE`（MIT）+ `CONTRIBUTING.md`，无需再动。

完成之后，任何人都可以通过仓库首页的 `English | 简体中文` 链接切换阅读两份文档。
