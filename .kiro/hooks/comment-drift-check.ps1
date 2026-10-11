# comment-drift check hook script.
#
# Purpose:
#   Runs on the "stop" trigger, i.e. when the assistant finishes a turn after
#   completing all plan tasks. It uses git to find Terraform (.tf) files changed
#   in this working session and reports their diffs as "comment-drift review
#   candidates" to STDOUT.
#
# Limitation:
#   A hook is only a command runner. It cannot semantically judge drift between
#   code and comments, nor rewrite comments by itself. This script only collects
#   and presents the review candidates; the actual judgment and comment update
#   is performed by the session AI agent that reads this output.
#
# Input:
#   Receives the stop hook event (JSON) via STDIN. Only "cwd" is used here.
#
# Exit code:
#   Always exits 0 (never blocks work). If there is nothing to review, exits
#   silently.

# Keep going on non-terminating errors. git writes warnings (e.g. CRLF notices)
# to stderr; with 'Stop' those would abort the script, so do not use 'Stop' here.
$ErrorActionPreference = 'Continue'

# Make Korean/non-ASCII diff content print correctly.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Read the hook event from STDIN to get cwd. Fall back to current location.
$cwd = (Get-Location).Path
try {
    $raw = [Console]::In.ReadToEnd()
    if ($raw) {
        $evt = $raw | ConvertFrom-Json
        if ($evt.cwd) { $cwd = $evt.cwd }
    }
} catch {
    # Ignore parse failures and keep going.
}

Set-Location -LiteralPath $cwd

# Nothing to do outside a git work tree.
$null = & git rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0) {
    exit 0
}

# Collect changed .tf files (working tree + staged), de-duplicated.
$changed = @()
$changed += (& git diff --name-only -- '*.tf' 2>$null)
$changed += (& git diff --name-only --cached -- '*.tf' 2>$null)
$changed = $changed | Where-Object { $_ } | Sort-Object -Unique

if (-not $changed -or $changed.Count -eq 0) {
    # No changed .tf files, so no drift review needed.
    exit 0
}

Write-Output "=== comment-drift review candidates ==="
Write-Output "The following Terraform files changed in this session. For each change,"
Write-Output "check whether the surrounding comments still match the code (meaning,"
Write-Output "arguments, resource names, defaults, behavior). Update any stale comment"
Write-Output "in Korean declarative style (ending with ~da)."
Write-Output ""

foreach ($file in $changed) {
    Write-Output "----- $file -----"
    # Show the combined change versus HEAD.
    $diff = & git diff HEAD -- $file 2>$null
    if ($diff) {
        $diff | ForEach-Object { Write-Output $_ }
    } else {
        Write-Output "(no diff: may be a new or untracked change)"
    }
    Write-Output ""
}

Write-Output "=== review rules ==="
Write-Output "- If resource names, variables/args, defaults, conditions, or behavior"
Write-Output "  changed but a nearby comment still describes the old code, that is drift."
Write-Output "- When drift exists, update only the comment. Do not change code logic."
Write-Output "- If the comment already matches the code, leave it unchanged."

exit 0
