$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$perl = Join-Path $root '.tools\strawberry-perl\perl\bin\perl.exe'

if (-not (Test-Path $perl)) {
    throw "Portable Perl not found at $perl. Install it with the dependency setup notes in README.md."
}

& $perl @args
exit $LASTEXITCODE
