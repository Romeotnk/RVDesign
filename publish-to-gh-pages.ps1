param(
    [string]$RepoOwner = 'Romeotnk',
    [string]$RepoName = 'RVDesign',
    [string]$SourceDir = '.\mirror',
    [string]$Branch = 'gh-pages',
    [string]$CommitMessage = 'Publish mirror site to gh-pages'
)

if (-not $env:GH_TOKEN) {
    Write-Error 'Set $env:GH_TOKEN before running this script.'
    exit 1
}

function Invoke-GitHubApi($method, $url, $body = $null) {
    $headers = @{
        Authorization = "Bearer $env:GH_TOKEN"
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($body -ne $null) {
        $jsonBody = $body | ConvertTo-Json -Depth 10
        return Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $jsonBody -ContentType 'application/json'
    }
    return Invoke-RestMethod -Method $method -Uri $url -Headers $headers
}

function Create-Blob($path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $base64 = [Convert]::ToBase64String($bytes)
    $body = @{ content = $base64; encoding = 'base64' }
    $url = "https://api.github.com/repos/$RepoOwner/$RepoName/git/blobs"
    $result = Invoke-GitHubApi -method Post -url $url -body $body
    return $result.sha
}

function Get-CurrentHeadSha() {
    $url = "https://api.github.com/repos/$RepoOwner/$RepoName/git/ref/heads/$Branch"
    try {
        $ref = Invoke-GitHubApi -method Get -url $url
        return $ref.object.sha
    } catch {
        return $null
    }
}

function Create-Tree($entries, $baseTreeSha) {
    $body = @{ tree = $entries }
    if ($baseTreeSha) { $body.base_tree = $baseTreeSha }
    $url = "https://api.github.com/repos/$RepoOwner/$RepoName/git/trees"
    return Invoke-GitHubApi -method Post -url $url -body $body
}

function Create-Commit($treeSha, $parentSha) {
    $body = @{
        message = $CommitMessage
        tree = $treeSha
    }
    if ($parentSha) { $body.parents = @($parentSha) }
    $url = "https://api.github.com/repos/$RepoOwner/$RepoName/git/commits"
    return Invoke-GitHubApi -method Post -url $url -body $body
}

function Update-Ref($commitSha, $createIfMissing) {
    $refUrl = "https://api.github.com/repos/$RepoOwner/$RepoName/git/refs/heads/$Branch"
    if ($createIfMissing) {
        $body = @{ ref = "refs/heads/$Branch"; sha = $commitSha }
        return Invoke-GitHubApi -method Post -url "https://api.github.com/repos/$RepoOwner/$RepoName/git/refs" -body $body
    }
    $body = @{ sha = $commitSha; force = $true }
    return Invoke-GitHubApi -method Patch -url $refUrl -body $body
}

function Enable-Pages() {
    $url = "https://api.github.com/repos/$RepoOwner/$RepoName/pages"
    $body = @{ source = @{ branch = $Branch; path = '/' } }
    try {
        return Invoke-GitHubApi -method Put -url $url -body $body
    } catch {
        Write-Warning "Pages activation may have failed or already configured: $_"
        return $null
    }
}

Push-Location $SourceDir
$files = Get-ChildItem -Recurse -File | Sort-Object FullName
if (-not $files) {
    Write-Error "No files found in $SourceDir"
    exit 1
}

$existingHeadSha = Get-CurrentHeadSha
$baseTreeSha = $null
$createRef = $false
if ($existingHeadSha) {
    Write-Host "Existing branch '$Branch' found with SHA $existingHeadSha"
    $commitInfo = Invoke-GitHubApi -method Get -url "https://api.github.com/repos/$RepoOwner/$RepoName/git/commits/$existingHeadSha"
    $baseTreeSha = $commitInfo.tree.sha
} else {
    Write-Host "Branch '$Branch' not found; creating new branch."
    $createRef = $true
}

$entries = @()
foreach ($file in $files) {
    $relPath = $file.FullName.Substring((Get-Location).Path.Length + 1).Replace('\','/')
    Write-Host "Creating blob for $relPath"
    $sha = Create-Blob $file.FullName
    $entries += @{ path = $relPath; mode = '100644'; type = 'blob'; sha = $sha }
}

$tree = Create-Tree -entries $entries -baseTreeSha $baseTreeSha
Write-Host "Created tree: $($tree.sha)"
$commit = Create-Commit -treeSha $tree.sha -parentSha $existingHeadSha
Write-Host "Created commit: $($commit.sha)"
$ref = Update-Ref -commitSha $commit.sha -createIfMissing $createRef
Write-Host "Updated ref: $($ref.ref) -> $($commit.sha)"

$pages = Enable-Pages
Write-Host "GitHub Pages configured on branch '$Branch'. URL: https://$RepoOwner.github.io/$RepoName/"

Pop-Location
