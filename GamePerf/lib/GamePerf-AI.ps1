<#
    GamePerf-AI.ps1  -  send a session to an AI analyst
    ================================================================
    Optional. Without a provider the app just writes ai-prompt.md and you
    paste it wherever you like. With one, the app sends the same brief and
    shows the answer, and you can ask follow-up questions.

    Two wire formats cover everything:

      * OpenAI-style  POST {base}/chat/completions
          xAI Grok, OpenAI, Google Gemini (its OpenAI-compatible endpoint),
          OpenRouter, Ollama, LM Studio, or any compatible server.
      * Anthropic     POST {base}/messages   (Claude)

    Model names drift faster than any app can ship, so every default is
    just a starting point: the app's "List models" asks the provider for
    its current list.

    Keys are stored with Windows DPAPI (current user only) or read from
    the provider's usual environment variable. They are only ever sent to
    the provider's own endpoint.
#>

$GpAiProviders = [ordered]@{
    none       = @{ Name = 'No AI - just write the files'; Style = 'none' }
    xai        = @{ Name = 'xAI Grok'; Style = 'openai'; BaseUrl = 'https://api.x.ai/v1'; Model = 'grok-4.7'; KeyEnv = 'XAI_API_KEY'; KeyUrl = 'https://console.x.ai' }
    openai     = @{ Name = 'OpenAI'; Style = 'openai'; BaseUrl = 'https://api.openai.com/v1'; Model = 'gpt-5.5'; KeyEnv = 'OPENAI_API_KEY'; KeyUrl = 'https://platform.openai.com/api-keys' }
    anthropic  = @{ Name = 'Anthropic Claude'; Style = 'anthropic'; BaseUrl = 'https://api.anthropic.com/v1'; Model = 'claude-opus-5-5'; KeyEnv = 'ANTHROPIC_API_KEY'; KeyUrl = 'https://platform.claude.com' }
    gemini     = @{ Name = 'Google Gemini'; Style = 'openai'; BaseUrl = 'https://generativelanguage.googleapis.com/v1beta/openai'; Model = 'gemini-3.8-flash'; KeyEnv = 'GEMINI_API_KEY'; KeyUrl = 'https://aistudio.google.com/apikey' }
    openrouter = @{ Name = 'OpenRouter (any model)'; Style = 'openai'; BaseUrl = 'https://openrouter.ai/api/v1'; Model = 'openrouter/auto'; KeyEnv = 'OPENROUTER_API_KEY'; KeyUrl = 'https://openrouter.ai/keys' }
    ollama     = @{ Name = 'Ollama (local, free)'; Style = 'openai'; BaseUrl = 'http://localhost:11434/v1'; Model = ''; NoKey = $true }
    lmstudio   = @{ Name = 'LM Studio (local, free)'; Style = 'openai'; BaseUrl = 'http://localhost:1234/v1'; Model = ''; NoKey = $true }
    custom     = @{ Name = 'Custom (OpenAI-compatible URL)'; Style = 'openai'; BaseUrl = ''; Model = ''; KeyOptional = $true }
}

# Claude request settings. API version 2026-10-21 rejects temperature/top_p/top_k,
# so none are sent to any provider.
$GpAnthropicVersion = '2026-10-21'
$GpAnthropicFallbackBeta = 'server-side-fallback-2026-07-01'

$GpAiSystemPrompt = @'
You are an expert PC gaming and VR performance engineer. You are given a performance capture (frame times from PresentMon, Windows performance counters, GPU telemetry), the machine's configuration, the game's configuration files and the player's goals. Give a precise, evidence-based diagnosis and concrete, prioritised changes. Quote the numbers and timestamps you rely on. Only recommend settings that exist in the provided files unless you clearly mark a suggestion as new. Respect the player's goals exactly - in particular, never suggest quad views, foveated rendering or upscaling if the goals exclude them. Use clear Markdown headings and short bullet lists.
'@

function Get-GpAiConfig {
    <# Provider, endpoint, model and key the app should use right now. #>
    param([Parameter(Mandatory)][hashtable]$Settings)
    $id = [string]$Settings.AiProvider
    if (-not $GpAiProviders.Contains($id)) { $id = 'none' }
    $p = $GpAiProviders[$id]
    $model = ''
    if ($Settings.AiModels -and $Settings.AiModels.ContainsKey($id)) { $model = [string]$Settings.AiModels[$id] }
    if (-not $model) { $model = [string]$p.Model }
    $base = [string]$p.BaseUrl
    if (($id -eq 'custom' -or $id -eq 'ollama' -or $id -eq 'lmstudio') -and $Settings.AiBaseUrl) { $base = [string]$Settings.AiBaseUrl }
    $key = ''
    if ($Settings.AiKeys -and $Settings.AiKeys.ContainsKey($id)) { $key = Unprotect-GpSecret ([string]$Settings.AiKeys[$id]) }
    if (-not $key -and $p.KeyEnv) { $key = [Environment]::GetEnvironmentVariable([string]$p.KeyEnv) }
    $effort = [string]$Settings.AiEffort
    if (-not $effort) { $effort = 'high' }
    [pscustomobject]@{
        Id = $id; Name = $p.Name; Style = $p.Style; BaseUrl = $base.TrimEnd('/'); Model = $model; ApiKey = $key; Effort = $effort
        NeedsKey = -not ($p.NoKey -or $p.KeyOptional); KeyEnv = $p.KeyEnv; KeyUrl = $p.KeyUrl
    }
}

function Test-GpAiReady {
    <# '' when the config can be used, otherwise what is missing. #>
    param([Parameter(Mandatory)]$Config)
    if ($Config.Style -eq 'none') { return 'No AI provider selected.' }
    if (-not $Config.BaseUrl) { return 'Enter the server URL in Settings.' }
    if (-not $Config.Model) { return 'Choose a model in Settings (use "List models").' }
    if ($Config.NeedsKey -and -not $Config.ApiKey) { return "Add your $($Config.Name) API key in Settings." }
    return ''
}

function Test-GpClaudeModernModel([string]$Model) {
    # Current-generation Claude models: they take output_config.effort and
    # the server-side "default" fallback for safety-classifier declines.
    return $Model -match '^claude-(opus-5|fable-5|sonnet-5-5|mythos-5)'
}

function New-GpAiRequest {
    <#
        Build the HTTP request without sending it - kept separate so the
        tests can check every provider's wire format offline.
        $Messages: array of @{ role = 'user' | 'assistant'; content = '...' }
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][object[]]$Messages,
        [string]$System = $GpAiSystemPrompt
    )
    $headers = [ordered]@{}
    if ($Config.Style -eq 'anthropic') {
        $body = [ordered]@{
            model = $Config.Model
            max_tokens = 16000
            system = $System
            messages = @($Messages | ForEach-Object { [ordered]@{ role = $_.role; content = [string]$_.content } })
        }
        if (Test-GpClaudeModernModel $Config.Model) {
            $body.output_config = [ordered]@{ effort = $Config.Effort }
            # A request a safety classifier declines is retried server-side on
            # the model Anthropic recommends for that category.
            $body.fallbacks = 'default'
            $headers['anthropic-beta'] = $GpAnthropicFallbackBeta
        }
        $headers['x-api-key'] = $Config.ApiKey
        $headers['anthropic-version'] = $GpAnthropicVersion
        return [pscustomobject]@{ Uri = "$($Config.BaseUrl)/messages"; Headers = $headers; Body = (ConvertTo-Json -InputObject $body -Depth 8 -Compress) }
    }
    $msgs = @([ordered]@{ role = 'system'; content = $System })
    $msgs += @($Messages | ForEach-Object { [ordered]@{ role = $_.role; content = [string]$_.content } })
    $body = [ordered]@{ model = $Config.Model; messages = $msgs; stream = $false }
    if ($Config.ApiKey) { $headers['Authorization'] = "Bearer $($Config.ApiKey)" }
    if ($Config.Id -eq 'openrouter') { $headers['X-Title'] = 'GamePerf' }
    return [pscustomobject]@{ Uri = "$($Config.BaseUrl)/chat/completions"; Headers = $headers; Body = (ConvertTo-Json -InputObject $body -Depth 8 -Compress) }
}

function Read-GpAiResponse {
    <# Pull the answer text out of either provider's response JSON. Returns @{ ok; text; error; model; usage }. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Json)
    $r = $null
    try { $r = $Json | ConvertFrom-Json } catch { return @{ ok = $false; error = "The provider returned something that is not JSON: $($Json.Substring(0, [Math]::Min(300, $Json.Length)))" } }
    if ($Config.Style -eq 'anthropic') {
        if ($r.stop_reason -eq 'refusal') {
            $cat = ''
            if ($r.stop_details -and $r.stop_details.category) { $cat = " ($($r.stop_details.category))" }
            return @{ ok = $false; error = "Claude declined this request$cat. Try again, or another model." }
        }
        $text = (@($r.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n").Trim()
        $note = ''
        if ($r.stop_reason -eq 'max_tokens') { $note = "`n`n_(The answer hit the length limit and was cut off. Ask it to continue.)_" }
        $usage = ''
        if ($r.usage) { $usage = "$($r.usage.input_tokens) in / $($r.usage.output_tokens) out tokens" }
        return @{ ok = [bool]$text; text = $text + $note; error = $(if ($text) { '' } else { 'The response had no text.' }); model = [string]$r.model; usage = $usage }
    }
    $choice = @($r.choices) | Select-Object -First 1
    $text = ''
    if ($choice -and $choice.message) { $text = [string]$choice.message.content }
    if ($choice -and $choice.message -and $choice.message.refusal) { return @{ ok = $false; error = "The model declined: $($choice.message.refusal)" } }
    $note = ''
    if ($choice -and $choice.finish_reason -eq 'length') { $note = "`n`n_(The answer hit the length limit and was cut off. Ask it to continue.)_" }
    $usage = ''
    if ($r.usage) { $usage = "$($r.usage.prompt_tokens) in / $($r.usage.completion_tokens) out tokens" }
    return @{ ok = [bool]$text; text = $text.Trim() + $note; error = $(if ($text) { '' } else { 'The response had no text.' }); model = [string]$r.model; usage = $usage }
}

function Get-GpAiErrorText {
    param([int]$Status, [string]$Body)
    $msg = ''
    try {
        $j = $Body | ConvertFrom-Json
        if ($j.error.message) { $msg = [string]$j.error.message }
        elseif ($j.error -is [string]) { $msg = [string]$j.error }
        elseif ($j.message) { $msg = [string]$j.message }
    } catch { }
    if (-not $msg) { $msg = $Body; if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) } }
    $msg = $msg.Trim()
    if ($msg -and $msg -notmatch '[.!?]$') { $msg += '.' }
    $hint = ''
    switch ($Status) {
        401 { $hint = ' Check the API key in Settings.' }
        403 { $hint = ' The key does not have access to this model or endpoint.' }
        404 { $hint = ' The model name or URL is wrong - try "List models".' }
        413 { $hint = ' The brief is too large for this model; untick some config files.' }
        429 { $hint = ' Rate limited or out of credit - wait a minute or check billing.' }
    }
    return "HTTP $Status - $msg$hint"
}

function Invoke-GpHttp {
    <# One HTTP call through HttpClient (UTF-8 both ways, long timeout). Returns @{ status; body; error }. #>
    param([Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Uri, $Headers, [string]$Body, [int]$TimeoutSec = 600)
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch { }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), $Uri)
        if ($Headers) { foreach ($k in $Headers.Keys) { if ($Headers[$k]) { [void]$req.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) } } }
        [void]$req.Headers.TryAddWithoutValidation('User-Agent', "GamePerf/$GamePerfVersion")
        if ($null -ne $Body -and $Method -ne 'GET') {
            $req.Content = New-Object System.Net.Http.StringContent($Body, [Text.Encoding]::UTF8, 'application/json')
        }
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        return @{ status = [int]$resp.StatusCode; body = [Text.Encoding]::UTF8.GetString($bytes); error = '' }
    } catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        return @{ status = 0; body = ''; error = $e.Message }
    } finally { $client.Dispose() }
}

function Invoke-GpAiChat {
    <# Send the conversation. Returns @{ ok; text; error; model; usage }. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][object[]]$Messages, [string]$System = $GpAiSystemPrompt)
    $why = Test-GpAiReady $Config
    if ($why) { return @{ ok = $false; error = $why } }
    $req = New-GpAiRequest -Config $Config -Messages $Messages -System $System
    $res = Invoke-GpHttp -Method 'POST' -Uri $req.Uri -Headers $req.Headers -Body $req.Body
    if ($res.status -eq 0) { return @{ ok = $false; error = "Could not reach $($Config.BaseUrl): $($res.error)" } }
    if ($res.status -lt 200 -or $res.status -ge 300) { return @{ ok = $false; error = (Get-GpAiErrorText $res.status $res.body) } }
    return (Read-GpAiResponse -Config $Config -Json $res.body)
}

function Get-GpAiModels {
    <# The provider's current model list (ids), newest-looking first. Returns @{ ok; models; error }. #>
    param([Parameter(Mandatory)]$Config)
    if ($Config.Style -eq 'none' -or -not $Config.BaseUrl) { return @{ ok = $false; error = 'Choose a provider first.' } }
    $h = [ordered]@{}
    if ($Config.Style -eq 'anthropic') { $h['x-api-key'] = $Config.ApiKey; $h['anthropic-version'] = $GpAnthropicVersion }
    elseif ($Config.ApiKey) { $h['Authorization'] = "Bearer $($Config.ApiKey)" }
    $res = Invoke-GpHttp -Method 'GET' -Uri "$($Config.BaseUrl)/models" -Headers $h -TimeoutSec 30
    if ($res.status -eq 0) { return @{ ok = $false; error = "Could not reach $($Config.BaseUrl): $($res.error)" } }
    if ($res.status -lt 200 -or $res.status -ge 300) { return @{ ok = $false; error = (Get-GpAiErrorText $res.status $res.body) } }
    try {
        $j = $res.body | ConvertFrom-Json
        $ids = @($j.data | ForEach-Object { [string]$_.id } | Where-Object { $_ })
        if (-not $ids.Count -and $j.models) { $ids = @($j.models | ForEach-Object { [string]$_.name } | Where-Object { $_ }) }   # Ollama native shape
        return @{ ok = $true; models = @($ids | Sort-Object -Descending) }
    } catch { return @{ ok = $false; error = 'Could not read the model list.' } }
}

function New-GpAiFirstMessage {
    <#
        The first user turn: the session's ai-prompt.md plus anything the
        user added on the AI page - extra files and pasted text - redacted
        the same way.
    #>
    param([Parameter(Mandatory)][string]$SessionDir, [string[]]$ExtraFiles = @(), [string]$Pasted = '', [string]$Question = '', [switch]$Redact)
    $brief = Read-GpTextFile -Path (Join-Path $SessionDir 'ai-prompt.md')
    if (-not $brief) { throw 'This session has no ai-prompt.md yet - run the analysis first.' }
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine($brief.TrimEnd())
    $extra = @($ExtraFiles | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($extra.Count) {
        [void]$sb.AppendLine(); [void]$sb.AppendLine('## Additional files I added')
        foreach ($f in $extra) {
            $t = Read-GpTextFile -Path $f -MaxBytes 262144
            if ($null -eq $t) { continue }
            [void]$sb.AppendLine(); [void]$sb.AppendLine("### $(Split-Path -Leaf $f)"); [void]$sb.AppendLine(); [void]$sb.AppendLine("Location: ``$f``")
            [void]$sb.AppendLine('```'); [void]$sb.AppendLine($t.TrimEnd()); [void]$sb.AppendLine('```')
        }
    }
    if ($Pasted -and $Pasted.Trim()) {
        [void]$sb.AppendLine(); [void]$sb.AppendLine('## Pasted by me'); [void]$sb.AppendLine()
        [void]$sb.AppendLine('```'); [void]$sb.AppendLine($Pasted.TrimEnd()); [void]$sb.AppendLine('```')
    }
    if ($Question -and $Question.Trim()) {
        [void]$sb.AppendLine(); [void]$sb.AppendLine('## My question'); [void]$sb.AppendLine(); [void]$sb.AppendLine($Question.Trim())
    }
    $text = $sb.ToString()
    if ($Redact) { $text = Protect-GpText $text }
    return $text
}

function Save-GpAiTranscript {
    <# Keep the conversation next to the session, as Markdown. #>
    param([Parameter(Mandatory)][string]$SessionDir, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][object[]]$Messages, [string]$Stamp)
    if (-not $Stamp) { $Stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss', $GpInv) }
    $path = Join-Path $SessionDir ("ai-analysis-{0}-{1}.md" -f $Config.Id, $Stamp)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("# AI analysis - $($Config.Name) ($($Config.Model))")
    $first = $true
    foreach ($m in $Messages) {
        [void]$sb.AppendLine()
        if ($m.role -eq 'user') {
            if ($first) { [void]$sb.AppendLine('## Sent: session brief (ai-prompt.md + your additions)'); $first = $false }
            else { [void]$sb.AppendLine('## You asked'); [void]$sb.AppendLine(); [void]$sb.AppendLine([string]$m.content) }
        } else {
            [void]$sb.AppendLine('## Answer'); [void]$sb.AppendLine(); [void]$sb.AppendLine([string]$m.content)
        }
    }
    Write-GpTextFile -Path $path -Text $sb.ToString()
    return $path
}
