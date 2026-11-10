param(
    [string]$RunId = "42747052884",
    [string]$DestDir = "G:\My Drive\Chess\tablebases\atomic"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
}

$tables = @(
    "KQQvKQ", "KQQvKR", "KQQvKB",
    "KQRvKQ", "KQRvKR", "KQRvKB", "KQRvKN",
    "KQBvKQ", "KQBvKR", "KQBvKB", "KQBvKN",
    "KQNvKQ", "KQNvKR", "KQNvKB", "KQNvKN",
    "KRRvKQ", "KRBvKQ", "KRNvKQ",
    "KBBvKQ", "KBNvKQ", "KNNvKQ"
)

$tempDir = Join-Path $env:TEMP "atomic_tb_dl"
if (Test-Path $tempDir) {
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$total = $tables.Count
$idx = 0

foreach ($t in $tables) {
    $idx++
    $destFile = Join-Path $DestDir "$t.atbd"
    
    if (Test-Path $destFile) {
        $size = (Get-Item $destFile).Length
        if ($size -eq 2147483680) {
            Write-Host "[$idx/$total] $t already exists and is valid (2,147,483,680 bytes). Skipping."
            continue
        } else {
            Write-Warning "[$idx/$total] $destFile exists but has unexpected size $size. Re-downloading."
            Remove-Item $destFile -Force
        }
    }

    Write-Host "[$idx/$total] Downloading atomic-tb-$t (Run $RunId)..."
    $artDir = Join-Path $tempDir $t
    if (Test-Path $artDir) { Remove-Item $artDir -Recurse -Force -ErrorAction SilentlyContinue }
    
    try {
        gh run download $RunId -n "atomic-tb-$t" -D $artDir
        
        $downloaded = Get-ChildItem -Path $artDir -Filter "*.atbd" -Recurse | Select-Object -First 1
        if ($null -eq $downloaded) {
            Write-Error "Could not find .atbd file in download for $t"
            continue
        }
        
        Write-Host "Moving $($downloaded.FullName) to $destFile..."
        Move-Item $downloaded.FullName $destFile -Force
        
        # Verify destination size
        $finalSize = (Get-Item $destFile).Length
        if ($finalSize -eq 2147483680) {
            Write-Host "[$idx/$total] SUCCESS: $t installed ($finalSize bytes)."
        } else {
            Write-Warning "[$idx/$total] WARNING: $t size mismatch: $finalSize"
        }
    } catch {
        Write-Error "Failed to download/install $t - $_"
    } finally {
        if (Test-Path $artDir) {
            Remove-Item $artDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Download and sync of all $total tables finished!"
