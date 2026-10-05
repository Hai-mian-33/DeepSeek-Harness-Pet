"""
Generate the project summary document for 蓝鲸小深 (Blue Whale Pet).

Written as a script rather than by hand so the document can be regenerated when the
project changes, and so the structure stays reviewable in version control.

Chinese text needs an explicit `w:eastAsia` font: setting run.font.name alone only
affects the Latin (ASCII) range, so CJK glyphs would fall back to whatever the theme
provides. Both the ascii and eastAsia attributes are therefore set on every run.
"""

import sys
from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.shared import Inches, Pt, RGBColor

OUT = sys.argv[1] if len(sys.argv) > 1 else "蓝鲸小深-项目总结.docx"

BODY_FONT = "Microsoft YaHei"
MONO_FONT = "Consolas"
BRAND = RGBColor(0x4D, 0x6B, 0xFE)
MUTED = RGBColor(0x6B, 0x72, 0x80)


def set_font(run, name=BODY_FONT, size=None, bold=None, color=None):
    """Apply a font to a run, including the East Asian range."""
    run.font.name = name
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = rpr.makeelement(qn("w:rFonts"), {})
        rpr.append(rfonts)
    rfonts.set(qn("w:ascii"), name)
    rfonts.set(qn("w:hAnsi"), name)
    rfonts.set(qn("w:eastAsia"), name)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.font.bold = bold
    if color is not None:
        run.font.color.rgb = color
    return run


def para(doc, text="", size=10.5, bold=False, color=None, space_after=6,
         space_before=0, style=None, align=None, indent=None):
    p = doc.add_paragraph(style=style)
    if text:
        set_font(p.add_run(text), size=size, bold=bold, color=color)
    pf = p.paragraph_format
    pf.space_after = Pt(space_after)
    pf.space_before = Pt(space_before)
    if align is not None:
        p.alignment = align
    if indent is not None:
        pf.left_indent = Inches(indent)
    return p


def rich(doc, parts, size=10.5, space_after=6, style=None, indent=None, color=None):
    """A paragraph built from (text, bold) or (text, bold, mono) tuples."""
    p = doc.add_paragraph(style=style)
    for part in parts:
        text, bold = part[0], part[1]
        mono = part[2] if len(part) > 2 else False
        set_font(p.add_run(text),
                 name=MONO_FONT if mono else BODY_FONT,
                 size=size - 0.5 if mono else size,
                 bold=bold,
                 color=color)
    p.paragraph_format.space_after = Pt(space_after)
    if indent is not None:
        p.paragraph_format.left_indent = Inches(indent)
    return p


def bullet(doc, parts, size=10.5):
    return rich(doc, parts, size=size, space_after=3, style="List Bullet")


def code(doc, lines):
    """A monospaced block on a light background."""
    for line in lines:
        p = doc.add_paragraph()
        set_font(p.add_run(line if line else " "), name=MONO_FONT, size=9)
        pf = p.paragraph_format
        pf.space_after = Pt(0)
        pf.space_before = Pt(0)
        pf.left_indent = Inches(0.25)
    # Trailing breathing room after the block.
    para(doc, "", space_after=4)


def heading(doc, text, level):
    h = doc.add_heading(level=level)
    set_font(h.add_run(text), size={0: 22, 1: 15, 2: 12.5, 3: 11}[level],
             bold=True, color=BRAND if level <= 1 else RGBColor(0x0F, 0x11, 0x15))
    h.paragraph_format.space_before = Pt(12 if level <= 1 else 9)
    h.paragraph_format.space_after = Pt(5)
    return h


def table(doc, header, rows, widths=None):
    t = doc.add_table(rows=1, cols=len(header))
    t.style = "Light Grid Accent 1"
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    for i, text in enumerate(header):
        cell = t.rows[0].cells[i]
        cell.text = ""
        set_font(cell.paragraphs[0].add_run(text), size=9.5, bold=True)
    for row in rows:
        cells = t.add_row().cells
        for i, text in enumerate(row):
            cells[i].text = ""
            mono = text.startswith("`") and text.endswith("`")
            set_font(cells[i].paragraphs[0].add_run(text.strip("`")),
                     name=MONO_FONT if mono else BODY_FONT,
                     size=8.5 if mono else 9.5)
    if widths:
        for row in t.rows:
            for i, w in enumerate(widths):
                row.cells[i].width = Inches(w)
    para(doc, "", space_after=4)
    return t


# ---------------------------------------------------------------- document

doc = Document()
section = doc.sections[0]
section.left_margin = section.right_margin = Inches(0.85)
section.top_margin = section.bottom_margin = Inches(0.8)

# Body style default, so unstyled paragraphs still get the CJK font.
normal = doc.styles["Normal"]
normal.font.name = BODY_FONT
normal.font.size = Pt(10.5)
normal.element.rPr.rFonts.set(qn("w:eastAsia"), BODY_FONT)
normal.paragraph_format.space_after = Pt(6)
normal.paragraph_format.line_spacing = 1.15

# --- title
title = doc.add_paragraph()
title.alignment = WD_ALIGN_PARAGRAPH.CENTER
set_font(title.add_run("蓝鲸小深"), size=26, bold=True, color=BRAND)
sub = doc.add_paragraph()
sub.alignment = WD_ALIGN_PARAGRAPH.CENTER
set_font(sub.add_run("DeepSeek Harness 桌面宠物 · 项目总结"), size=13, color=MUTED)
meta = doc.add_paragraph()
meta.alignment = WD_ALIGN_PARAGRAPH.CENTER
set_font(meta.add_run("一只始终置顶的蓝色鲸鱼，用真实会话事件显示 Harness 的运行状态"),
         size=10, color=MUTED)
para(doc, "", space_after=10)

# --- 1 background
heading(doc, "一、项目背景", 1)

heading(doc, "1.1 要解决的问题", 2)
para(doc, "DeepSeek Harness 是一个多会话的 AI 编程代理环境。当多个任务同时运行时，"
          "用户必须把 Harness 窗口切到前台才能知道某个任务是否还在跑、跑到哪一步、有没有"
          "报错。一旦切去写代码或看文档，这些信息就完全不可见了。")
para(doc, "本项目提供的解决办法是：把 Harness 的真实运行状态外化为一个常驻桌面的小鲸鱼，"
          "不占用工作区、不抢焦点，扫一眼就知道现在有几个任务在跑、各自的进度和结果。")

heading(doc, "1.2 设计目标", 2)
bullet(doc, [("实时性：", True), ("气泡随任务进展持续更新，而不是只在状态切换时跳变。", False)])
bullet(doc, [("不打扰：", True), ("点击桌宠不夺取编辑器焦点，静默模式下只保留动画。", False)])
bullet(doc, [("不遗漏：", True), ("任务结束后气泡保留，直到用户点击查看为止；未点击的永不自动消失。", False)])
bullet(doc, [("可并行：", True), ("多个任务同时运行时可各自展开一个对话框，默认只显示一个以免干扰。", False)])
bullet(doc, [("隐私优先：", True), ("只读取状态、轮次、工具名称、时间和短错误码，"
                                 "不读取提示词、模型回复、工具参数或文件内容。", False)])

heading(doc, "1.3 为什么是「鲸鱼」", 2)
para(doc, "鲸鱼取自 DeepSeek 官方品牌标识，不是另画的相似形象。精灵图的每一帧都是把同一条"
          "官方 50×50 路径放在仿射变换下，适配该状态需要的姿态。除鲸鱼本体外不绘制任何"
          "道具（无电脑、键盘、时钟、水花、阴影），因此它在任意缩放下都读作一个干净的品牌标记。")

# --- 2 features
heading(doc, "二、功能特性", 1)

heading(doc, "2.1 桌宠行为", 2)
table(doc,
      ["功能", "行为说明"],
      [
          ["拖拽移动", "左键拖动即可移动；快速甩动会滑行后停下，轻放则轻微弹一下。"],
          ["边缘固定（核心特性）", "拖过屏幕边缘时，桌宠贴着边缘停住，保持完整大小和完全可见，"
                            "继续往外拖只沿边缘滑动。这与「把宠物缩到屏幕外只留一点」的做法相反，"
                            "详见第四节。"],
          ["九种动画状态", "待机、思考中、工作中、等待确认、完成庆祝、出错、拖拽中、长任务，"
                      "外加一帧备用位以保持 8×9 的图集约定。"],
          ["位置记忆", "位置按显示器归一化保存，分辨率或任务栏变化后重新夹取到安全区域。"],
      ],
      widths=[1.35, 5.3])

heading(doc, "2.2 状态对话框", 2)
para(doc, "对话框是桌宠的主要信息载体，其行为经过多轮打磨，目前的规则如下：")
bullet(doc, [("运行中实时显示：", True),
             ("任务运行时显示阶段、当前工具名、进度（已完成 2/10）和持续走动的已用时长。", False)])
bullet(doc, [("结束后继续保留：", True),
             ("任务结束后对话框不消失，其中的时间改为显示「刚刚 / 2 分钟前 / 16 分钟前」并持续更新，"
              "因此保留的框仍然在提供信息，而不是一个看起来已废弃的静态「任务完成」。", False)])
bullet(doc, [("点击后才消失：", True),
             ("点击对话框或桌宠会打开 Harness 并移除该对话的框。保留依据是「是否已被点击」而非计时器，"
              "所以完成的任务不会悄悄溜走。", False)])
bullet(doc, [("新回复会重新出现：", True),
             ("确认只针对被点击的那一条回复。同一对话之后有新的回复时，对话框会重新出现。", False)])
bullet(doc, [("并行任务各自成框：", True),
             ("默认只显示排名第一的框，保持简洁；点击「展开」后每个并行任务各占一个框，"
              "各自显示自己的状态。顶部徽标说明数量构成，例如"
              "「另有 5 个对话（1 个进行中，4 个已完成）」。", False)])

heading(doc, "2.3 交互方式", 2)
table(doc,
      ["操作", "结果"],
      [
          ["左键单击桌宠", "打开 DeepSeek Harness 桌面版，并清除当前显示的对话"],
          ["左键单击对话框", "打开 Harness 并按该对话确认，仅移除这一个框"],
          ["单击「展开/收起」", "展开全部对话列表，或收起为单个框"],
          ["单击顶部徽标", "同「展开/收起」"],
          ["右键单击桌宠", "菜单：打开 Harness、展开/收起列表、缩放 50–200%、静默模式、始终置顶、退出"],
          ["Ctrl + 滚轮", "快捷缩放"],
      ],
      widths=[1.5, 5.15])

# --- 3 technical
heading(doc, "三、技术实现", 1)

heading(doc, "3.1 总体架构", 2)
para(doc, "整个系统由三部分组成，数据单向流动：")
code(doc, [
    "$DSH_HOME/sessions/…/session.v4.jsonl.zstd    $DSH_HOME/storages/session_projcache/…",
    "（只追加的会话事件日志，zstd 帧）              （宿主自己持久化的 Session Projection 行）",
    "                    │                                        │",
    "                    └────────────────┬───────────────────────┘",
    "                                     ▼",
    "                        src/bridge.mjs（Node，无第三方依赖）",
    "                  按字节偏移 tail 日志 → 折叠为有界的隐私事实 → 归约 → 原子快照",
    "                                     │",
    "                    state/pet-state.json  +  state/pet-control.json",
    "                                     ▼",
    "                   src/shell/WhalePet.ps1（WPF，透明窗口）",
    "                    120×130 桌宠窗口  +  对话框/列表弹窗",
])
bullet(doc, [("src/core/*.mjs —— 纯核心：", True),
             ("事件折叠、状态归约、窗口几何。无 I/O、无时钟、无全局状态，"
              "每个值得信任的行为都是带单元测试的纯函数。", False)])
bullet(doc, [("src/bridge.mjs —— 唯一读取 Harness 存储的进程：", True),
             ("它 tail 真实会话日志，折叠成桌宠被允许知道的那一小部分事实，"
              "运行归约器，然后原子地发布一份 JSON 快照。", False)])
bullet(doc, [("src/shell/WhalePet.ps1 —— 表现层：", True),
             ("两个透明 WPF 窗口（桌宠本体，以及从状态气泡长成对话列表的弹窗）。"
              "它从不读取 Harness 存储，只渲染快照。", False)])
para(doc, "这个分界的意义在于：隐私规则集中在唯一一个可审计的文件里，"
          "而渲染层可以在不触碰数据通路的前提下整体替换。")

heading(doc, "3.2 为什么状态来自文件而非 HTTP", 2)
para(doc, "Harness 确实暴露了一个回环 HTTP API，但它用「每进程随机启动令牌」认证——"
          "该令牌在 GET /?token=… 换取一个签名并绑定权限的 Cookie"
          "（dsh-client-connection）。独立进程无法取得这个令牌，"
          "因此桌宠改用宿主自己也会使用并持久化的两个来源：")
bullet(doc, [("会话事件日志：", True),
             ("权威的 session/event 流，由相互独立的 zstd 帧首尾相接写成——"
              "正因如此，按字节偏移 tail 既廉价又具备流式特征。", False)])
bullet(doc, [("Session Projection 缓存：", True),
             ("宿主自己持久化的投影行，是开放中的用户提问与 todo 进度唯一出现的地方。", False)])
rich(doc, [("需求中提到的「SSE 断线自动重连 + 轮询兜底」，在这里的落地方式是"
            "「按字节偏移的 tail 订阅」而不是套接字：每轮只解码自上次以来新增的帧，"
            "写到一半的尾部帧直接留给下一轮，某一轮失败则继续沿用上一份良好快照并把自己标记为"
            "降级——根本没有会断开的连接。", False)])

heading(doc, "3.3 隐私边界", 2)
para(doc, "src/core/session-facts.mjs 只在「识别」事件时读取其载荷。穿过折叠后幸存的字段"
          "恰好是：状态、轮次/步骤编号、工具名称、时间戳、todo 计数，以及用有界正则提取的"
          "简短机器错误码（EPERM、ENOENT、HTTP500）。提示词、模型回复、工具参数、"
          "工具结果内容、工作区路径与文件内容一律丢弃。")
para(doc, "两个刻意的选择：")
bullet(doc, [("只保留工作目录的最后一段", False), ("作为项目标签。", False)])
bullet(doc, [("会话标题默认不采集", True),
             ("（需 --expose-title）。标题虽然短，但它是从你的提示词推导来的，"
              "所以桌宠默认显示项目文件夹名。titleInput 内嵌了首条提示词原文，从不读取。", False)])
para(doc, "tests/reducer.test.mjs 对此有断言：它折叠一个携带密钥的事件，"
          "然后检查该密钥没有出现在结果事实里。")

heading(doc, "3.4 关键技术难点", 2)
para(doc, "以下每一条都是实际踩过并解决的坑，也是最容易在复刻时重复踩到的地方。")

para(doc, "① 透明窗口的鼠标命中测试", size=11, bold=True, space_after=3)
rich(doc, [("AllowsTransparency = true 的 WPF 窗口是分层窗口，"
            "Windows 对它按「每像素 alpha」做命中测试：alpha 为 0 的像素对鼠标是透明的，"
            "点击会穿透到后面的程序。而精灵图除鲸鱼本体外全是透明像素，"
            "所以背景用 Brushes.Transparent 时，只有鲸鱼身上那几个不透明像素可以被点到——"
            "抓空白处毫无反应，点击还会漏到别的窗口。", False)])
rich(doc, [("修复方式是让背景为 alpha 1 的黑色（", False),
           ("#01000000", False, True),
           ("）：肉眼不可见，但对命中测试不透明，于是整个窗口都是有效的拖拽目标。", False)])

para(doc, "② 拖拽必须轮询，不能依赖鼠标事件", size=11, bold=True, space_after=3)
rich(doc, [("窗口以 ShowActivated = $false 显示（这样点击桌宠不会夺走编辑器的焦点），"
            "而在这种状态下 Mouse.Capture 无法可靠保持，MouseMove 很快就会停止到达，"
            "MouseUp 则被投递给光标下的其他窗口。因此只有「按下」取自 WPF，"
            "移动与释放改为每帧从系统读取（", False),
           ("Cursor.Position", False, True),
           (" 与 ", False),
           ("GetAsyncKeyState", False, True),
           ("）。", False)])
rich(doc, [("一个反面教训：绝不能用 ", False),
           ("[System.Windows.Forms.Control]::MouseButtons", False, True),
           (" 做这件事。纯 WPF 进程里 WinForms 从不安装它的消息过滤器，"
            "该属性会持续返回 None——即使按键正被按住。基于它的「看门狗」"
            "会在下一个 tick 取消每一次拖拽，表现为「完全拖不动」。", False)])

para(doc, "③ 弹窗里的可点击控件必须有 Tag", size=11, bold=True, space_after=3)
rich(doc, [("弹窗同样不投递 WPF 点击事件，所以弹窗内的点击靠「命中测试可视化树 + 读取元素 "
            "Tag」解析。Tag 要么是会话 id，要么是 ", False),
           ("action:", False, True),
           (" 命名空间里的内部动作。没有 Tag 的控件对这套机制完全不可见："
            "「展开/收起」按钮一度没有 Tag，命中测试返回空字符串，点击被当作"
            "「没点到会话」丢弃——按钮看起来坏了，其实它的 Add_Click 处理函数是对的，"
            "只是从未被执行。", False)])
rich(doc, [("相关的一个坑：WPF 元素若 Background 为 null 也不可命中，"
            "所以可点击面板要设成 Brushes.Transparent，而不是留空。", False)])

para(doc, "④ 拖动卡顿与面板闪现", size=11, bold=True, space_after=3)
rich(doc, [("重塑全树代价很高：", False),
           ("弹窗更新原本每次都会 Clear() 并重建整棵可视化树，"
            "而主循环每 40ms 调用一次，拖拽时还额外每帧调用——"
            "但数据其实每秒才变一次。结果就是拖动时桌宠卡顿、面板闪烁。", False)])
rich(doc, [("修复方式是把「内容」与「位置」彻底分开：用一份指纹"
            "（覆盖渲染读到的每个字段）判断内容是否真的变了，只在变化时重建；"
            "位置则每帧重新测量——那只是一次 SetWindowPos，足够廉价。", False)])

para(doc, "⑤ 完成记录的保留策略", size=11, bold=True, space_after=3)
rich(doc, [("这里连续踩了两个坑。第一个：归约器改成「未读完成永久保留」，"
            "测试也通过了，但桥接进程仍在 120 秒后删除记录——"
            "测试之所以通过，是因为它直接调用归约器，从未执行真正做删除的那段代码。", False)])
rich(doc, [("第二个更隐蔽：已确认的记录会按时间被清理，"
            "而这条记录是「用户已经处理过它」的唯一凭据。"
            "一旦被清掉，任何重新观察到同一轮结束的路径（日志帧重读、"
            "桥接重启未正确播种）都会生成一条新的未读记录，"
            "于是用户已经点过的框又冒出来。正确做法是按「条数」而非「时间」保留，"
            "并且只在出现真正更新的回复时才产生新的未读记录。", False)])

para(doc, "⑥ 严格模式下的字段契约", size=11, bold=True, space_after=3)
rich(doc, [("shell 在 ", False),
           ("Set-StrictMode -Version Latest", False, True),
           (" 下读取视图模型，因此缺失的属性是致命错误而非空白："
            "读取归约器忘记输出的字段会在动画循环里抛异常，"
            "整个桌宠随之消失，且错误只出现在日志里。", False)])
rich(doc, [("现在测试会双向校验字段：既检查「渲染用到的字段都存在」，"
            "也检查「不存在未被契约登记的字段」——"
            "后者是缺失的一环，曾让新字段悄悄上线而无人察觉。", False)])

para(doc, "⑦ 环境限制：跨进程窗口控制", size=11, bold=True, space_after=3)
rich(doc, [("「点击打开 Harness 并把它带到前台」这一功能在受限宿主内无法完成。"
            "从 shell 自己的进程内测得的日志是：", False)])
code(doc, [
    "raise: SetForegroundWindow refused, GetLastError=203",
    "raise: attach=False fgThread=3800 self=64472",
    "raise: every method refused",
])
rich(doc, [("六种候选方法（SetForegroundWindow、SwitchToThisWindow、AttachThreadInput、"
            "合成 ALT 敲击、最小化后还原、SetWindowPos 带 SHOWWINDOW）全部被拒；"
            "即使是拥有消息队列的 WPF 线程，AttachThreadInput 也返回 False；"
            "跨进程 SetWindowPos 返回 False 且错误码为 5（ACCESS_DENIED），"
            "窗口样式位毫无变化。决定性细节是：同一进程操作「自己的」窗口完全正常"
            "（拖拽与弹窗定位都工作），所以限制专门针对控制其他程序的窗口。", False)])
rich(doc, [("从普通终端启动桌宠可以绕过这一限制，实测有效——"
            "此时启动可执行文件会由 Electron 的单实例机制把窗口带到前台。", False)])

# --- 4 reverse design
heading(doc, "四、逆向设计分析", 1)
rich(doc, [("本项目的设计起点是一条明确的反向判断：", False),
           ("「拖拽到边缘时固定，而不是隐藏」", True),
           ("。为了确认这条判断是否站得住，我们对既有桌宠做了资料核查。"
            "核查结果修正了原本的说法——这一点值得如实记录，因为它说明了"
            "「逆向设计」必须落在可验证的证据上，而不是印象。", False)])

heading(doc, "4.1 核查结果：原判断有一半需要修正", 2)
rich(doc, [("原本的表述是「与 ChatGPT 桌宠、GooglePiggy 相反，它们都把宠物藏到边缘」。"
            "核查后发现两个对象的行为并不相同，把二者并列是错误的：", False)])
bullet(doc, [("GooglePiggy —— 判断成立。", True),
             ("它确实在闲置时贴边隐藏：拖到屏幕物理外缘松手后，主体缩到屏幕之外，"
              "只留下一小截尾巴；Windows 上是一个 68×68 的可点击尾巴窗口，"
              "点击尾巴才弹回。内部显示器接缝不触发。", False)])
bullet(doc, [("ChatGPT / Codex Pets —— 判断不成立。", True),
             ("它并不是「贴边隐藏」的设计，而是常驻置顶的浮层，"
              "显示与隐藏全部由用户手动触发（右键隐藏、设置中隐藏、再次输入 /pet，"
              "以及一个单独的「收起」命令），位置跨重启保留。"
              "官方文档没有任何自动贴边收起的描述；"
              "相反，「靠近边缘时宠物消失」是被登记的缺陷，"
              "其期望行为正是「宠物在靠近屏幕边缘时应保持可见且可触及」。"
              "社区还有请求希望官方「增加」闲置自动隐藏，理由是它闲置时"
              "一直是个常驻置顶浮层——如果已有自动收起，这条请求就不成立。", False)])

rich(doc, [("因此准确的说法是：", False),
           ("ChatGPT / Codex Pets 是「手动或缺失的可见性管理」，"
            "GooglePiggy 是「自动收起到屏幕外」，"
            "而本项目是「贴边且始终完整可见」。", True),
           ("与两者相比，本项目依然构成真实差异，"
            "但差异的机制各不相同，不能用一个「藏起来」笼统概括。", False)])

para(doc, "实现上，本项目的边缘行为严格遵循「固定且可见」：")
bullet(doc, [("拖过任一边缘时，窗口贴着边缘停住，保持完整大小与完全可见，之后只沿该边缘滑动。", False)])
bullet(doc, [("夹取使用显示器的工作区，所以任务栏也算一条边缘。", False)])
bullet(doc, [("跨显示器接缝不会被当作吸引点；只有排布的极端边缘才起固定作用。", False)])
para(doc, "验证方式包括 6 个真实桌面用例（四条边加两个角，全部贴边、全尺寸、visible=True），"
          "以及几何层的单元测试。")

heading(doc, "4.2 对比要点", 2)
rich(doc, [("下表把三个对象并置。需要注意 GooglePiggy 与本项目的边缘机制是"
            "「同一目标下的相反取舍」，而 Codex Pets 根本没有自动边缘行为，"
            "因此比较的维度也不同。", False)])
table(doc,
      ["维度", "本项目（蓝鲸小深）", "ChatGPT / Codex Pets", "GooglePiggy"],
      [
          ["拖到边缘", "贴着边缘停住，完整可见，继续拖则沿边缘滑动",
           "无自动边缘行为；显示/隐藏由用户手动触发",
           "闲置时缩到屏幕外，只留可点击尾巴"],
          ["状态来源", "读取 Harness 会话事件日志与投影缓存（跨进程桥接）",
           "第一方聊天/代理状态，无需桥接",
           "由 Codex 钩子写状态文件（跨进程桥接）"],
          ["多任务", "并行任务各自一个对话框，默认显示一个，可展开全部",
           "有活动托盘与数字徽标，并有明确优先级",
           "单一全局状态，不支持多任务"],
          ["点击行为", "打开 Harness 桌面版并确认该对话",
           "点击返回 ChatGPT，活动列表可打开对应会话",
           "仅播放动画，不打开关联应用"],
      ],
      widths=[0.85, 2.0, 1.95, 1.85])

rich(doc, [("一个值得注意的巧合：Codex Pets 的精灵图契约是 1536×1872、"
            "8 列 × 9 行、每格 192×208——与本项目完全相同。"
            "这说明该规格已成为这类宠物的事实约定，本项目沿用它是合理的。", False)],
     size=10, color=MUTED)

para(doc, "本节结论的可靠性边界：以上对比来自各产品的官方文档、README、"
          "发行说明与缺陷追踪（可复核链接见仓库 README），"
          "未对 Codex Pets 与 GooglePiggy 做运行时实测。"
          "本项目自身的边缘行为则由代码与真实桌面用例直接确认。",
     size=10, color=MUTED)

# --- 5 status
heading(doc, "五、交付状态与验证", 1)

heading(doc, "5.1 代码规模", 2)
table(doc,
      ["部分", "规模", "说明"],
      [
          ["src/core/（9 个模块）", "约 1 656 行", "纯核心：事件折叠、归约、几何、时钟、完成记录"],
          ["src/bridge.mjs", "222 行", "轮询与快照发布"],
          ["src/shell/WhalePet.ps1", "2 249 行", "WPF 界面：窗口、动画、拖拽、气泡、列表"],
          ["tests/（5 个文件）", "74 个测试", "几何契约、归约、隐私边界、完成记录、会话观察"],
          ["tools/", "61 个 .ps1", "构建与验证工具（精灵图构建、真实桌面测试、截图）"],
      ],
      widths=[1.85, 1.15, 3.65])

heading(doc, "5.2 验证方式", 2)
bullet(doc, [("74 个单元测试", True),
             ("覆盖几何契约、优先级、时序、事件折叠词汇表、隐私边界、"
              "完成保留与「历史 vs 新闻」的判定规则。", False)])
bullet(doc, [("真实桌面用例", True),
             ("驱动真实窗口验证边缘固定、命中测试覆盖、面板折叠/展开、"
              "以及「从最小化状态唤起 Harness」。", False)])
bullet(doc, [("渲染验证", True),
             ("直接遍历真实 WPF 可视化树计数，确认折叠时恰好 1 个对话框、"
              "展开时每个任务各 1 个。", False)])

heading(doc, "5.3 已知限制", 2)
bullet(doc, [("无法定位到具体对话：", True),
             ("Harness 没有按会话深链的机制——SPA 完全不读 URL，协议处理器只接受 "
              "dsh://open 且仅限 macOS，宿主 API 也没有「把某个会话设为当前」的调用。"
              "因此点击只能唤起 Harness 窗口，落到当前已打开的对话上。"
              "桌宠已经持有会话 id，一旦 Harness 侧提供深链，这会是个小改动。", False)])
bullet(doc, [("受限宿主内无法提升窗口：", True),
             ("原因见 3.4 ⑦。从普通终端启动即可。", False)])
bullet(doc, [("多显示器仅单元测试：", True),
             ("跨显示器接缝处理有单元测试覆盖，但实机只有单显示器，"
              "未能做真实硬件的跨屏拖拽验证。", False)])

# --- footer note
para(doc, "", space_after=8)
note = doc.add_paragraph()
set_font(note.add_run("本文档由项目源码与验证记录整理生成；"
                      "所有结论均可在仓库中对应的代码、测试或工具脚本中复核。"),
         size=9, color=MUTED)

doc.save(OUT)
print(f"saved: {OUT}")
