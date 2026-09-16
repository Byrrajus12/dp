$repoRoot = $PSScriptRoot
$arduinoRoot = Join-Path $repoRoot ".arduino-cli"

$env:ARDUINO_DIRECTORIES_DATA = Join-Path $arduinoRoot "data"
$env:ARDUINO_DIRECTORIES_DOWNLOADS = Join-Path $arduinoRoot "downloads"
$env:ARDUINO_DIRECTORIES_USER = Join-Path $arduinoRoot "user"
$env:ARDUINO_BUILD_CACHE_PATH = Join-Path $arduinoRoot "build-cache"

& (Join-Path $repoRoot ".tools\arduino-cli.exe") @args
exit $LASTEXITCODE
