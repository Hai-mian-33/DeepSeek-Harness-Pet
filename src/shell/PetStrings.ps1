# PetStrings.ps1 — bilingual UI copy for the pet shell (简体中文 / English).
#
# The data side (bridge + reducer) has its own catalogue in `src/core/i18n.mjs`; this
# file is the presentation half of the same system, because a WPF script cannot import
# an ES module. The two tables share keys and `{0}`-style placeholders, and the shell's
# chosen language reaches the bridge through the control file (`Write-Control`), so a
# single right-click switch re-renders both halves within one poll.
#
# PowerShell 5.1 reads BOM-less scripts as ANSI, which turns every Chinese literal into
# mojibake, so this file MUST stay UTF-8 with BOM (tools\Validate-Shell.ps1 -Fix repairs
# it if a tool ever strips it).

$script:PetLanguage = 'zh-CN'

$script:PetStrings = @{
    'zh-CN' = @{
        menuOpenHarness = '打开 DeepSeek Harness'
        menuExpandList  = '展开全部对话'
        menuCollapseList = '收起对话列表'
        menuScale       = '缩放'
        menuLanguage    = '语言'
        menuSilent      = '静默模式（仅保留动画）'
        menuAlwaysOnTop = '始终置顶'
        menuExit        = '退出桌宠'
        titleSuffix     = ' · 状态'
        expandCollapse  = '▴ 收起'
        expandAll       = '▾ 展开全部对话'
        noConversations = '当前没有进行中的对话'
        unreadMark      = '  ● 未处理'
        progressPrefix  = '进度 {0}'
        longTask        = '长任务'
        hoverLine       = '阶段 {0}   时长 {1}   运行中工具 {2}'
        othersBadge     = '另有 {0} 个对话{1}'
        othersDetail    = '（{0}）'
        othersRunning   = '{0} 个进行中'
        othersFinished  = '{0} 个已完成'
        othersJoin      = '，'
        sessionFallback = '会话'
    }
    'en' = @{
        menuOpenHarness = 'Open DeepSeek Harness'
        menuExpandList  = 'Expand all conversations'
        menuCollapseList = 'Collapse conversation list'
        menuScale       = 'Scale'
        menuLanguage    = 'Language'
        menuSilent      = 'Silent mode (animation only)'
        menuAlwaysOnTop = 'Always on top'
        menuExit        = 'Quit pet'
        titleSuffix     = ' · Status'
        expandCollapse  = '▴ Collapse'
        expandAll       = '▾ Expand all'
        noConversations = 'No conversations right now'
        unreadMark      = '  ● unread'
        progressPrefix  = 'Progress {0}'
        longTask        = 'Long task'
        hoverLine       = 'Stage {0}   Elapsed {1}   Tools {2}'
        othersBadge     = '{0} more conversations{1}'
        othersDetail    = ' ({0})'
        othersRunning   = '{0} running'
        othersFinished  = '{0} done'
        othersJoin      = ', '
        sessionFallback = 'Session'
    }
}

<#
.SYNOPSIS
    Map any language tag onto one the shell can render, or '' when unrecognised.
.DESCRIPTION
    Accepts the forms that occur in the wild (`zh`, `zh-CN`, `zh_CN`, `en`, `en-US`)
    and normalises them. An unrecognised tag returns '' so the caller can keep the
    current language rather than silently resetting it.
#>
function ConvertTo-PetLanguage {
    param([string]$Value)
    $lower = $Value.Trim().ToLowerInvariant()
    if ($lower -eq '' ) { return '' }
    if ($lower -eq 'zh' -or $lower.StartsWith('zh-') -or $lower.StartsWith('zh_')) { return 'zh-CN' }
    if ($lower.StartsWith('en')) { return 'en' }
    return ''
}

<#
.SYNOPSIS
    The language a fresh shell starts in, before config or the user says otherwise.
.DESCRIPTION
    Chinese systems start Chinese; everything else starts English. The choice is
    persisted in shell-config.json on the first save, so this only ever runs once
    per machine unless the config is deleted.
#>
function Get-PetDefaultLanguage {
    try {
        $ui = [System.Globalization.CultureInfo]::CurrentUICulture
        if ($null -ne $ui -and $ui.Name -like 'zh*') { return 'zh-CN' }
    } catch { }
    return 'en'
}

function Get-PetLanguage {
    return $script:PetLanguage
}

<# Apply a language tag; an unrecognised one leaves the current choice untouched. #>
function Set-PetLanguage {
    param([string]$Value)
    $normalised = ConvertTo-PetLanguage -Value $Value
    if ($normalised -ne '') { $script:PetLanguage = $normalised }
}

<#
.SYNOPSIS
    One localised string by key, in the shell's current language.
.DESCRIPTION
    A missing key falls back to the Chinese table and then to the key itself, so a
    typo degrades to visible text instead of an empty label — the popup renders this
    output under Set-StrictMode, and a null TextBlock text would be a silent blank.
#>
function Get-PetString {
    param([string]$Key)
    $table = $script:PetStrings[$script:PetLanguage]
    if ($null -eq $table -or -not $table.ContainsKey($Key)) { $table = $script:PetStrings['zh-CN'] }
    if (-not $table.ContainsKey($Key)) { return $Key }
    return [string]$table[$Key]
}

<# Short alias so renderer lines stay readable: `(T 'menuExit') -f ...`. #>
function T {
    param([string]$Key)
    return (Get-PetString -Key $Key)
}
