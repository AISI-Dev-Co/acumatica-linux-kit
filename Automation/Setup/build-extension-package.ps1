param(
	[Parameter(Mandatory = $true)]
	[string]$ExtensionPath,
	[string]$ConfigPath,
	[string]$WebsiteRoot,
	[switch]$SkipDotnetBuild
)

$ErrorActionPreference = "Stop"

$extensionRoot = [System.IO.Path]::GetFullPath($ExtensionPath)
if (!(Test-Path $extensionRoot)) { throw "Extension path not found: $extensionRoot" }

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
	$ConfigPath = Join-Path $extensionRoot "extension.package.json"
}
else {
	$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
}
if (!(Test-Path $ConfigPath)) { throw "Extension package manifest not found: $ConfigPath" }

$manifest = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

function Require-ManifestValue {
	param([object]$Value, [string]$Name)
	if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
		throw "extension.package.json is missing required value: $Name"
	}
}

Require-ManifestValue $manifest.projectName "projectName"
Require-ManifestValue $manifest.description "description"
Require-ManifestValue $manifest.csproj "csproj"
Require-ManifestValue $manifest.outputZip "outputZip"

$buildConfiguration = if ($manifest.buildConfiguration) { [string]$manifest.buildConfiguration } else { "Release" }
$projectItemsPath = if ($manifest.projectItemsPath) { [string]$manifest.projectItemsPath } else { "_project" }
$dllName = if ($manifest.dllName) { [string]$manifest.dllName } else { ([System.IO.Path]::GetFileNameWithoutExtension([string]$manifest.csproj) + ".dll") }
$pdbName = [System.IO.Path]::ChangeExtension($dllName, ".pdb")
$normalizeModernUiPaths = $manifest.normalizeModernUiPaths -eq $true

if ([string]::IsNullOrWhiteSpace($WebsiteRoot)) {
	$WebsiteRoot = if ($env:ACUMATICA_WEBSITE_ROOT) { $env:ACUMATICA_WEBSITE_ROOT } else { "C:\AcumaticaERP" }
}

$projectFile = Join-Path $extensionRoot ([string]$manifest.csproj)
$projectItemsRoot = Join-Path $extensionRoot $projectItemsPath
$dllPath = Join-Path $extensionRoot (Join-Path "Bin" $dllName)
$pdbPath = Join-Path $extensionRoot (Join-Path "Bin" $pdbName)
$receiptPath = "$dllPath.acumatica-build.json"
$outZip = Join-Path $extensionRoot ([string]$manifest.outputZip)
$pxCommandLine = Join-Path $WebsiteRoot "Bin\PX.CommandLine.exe"
$siteDataDll = Join-Path $WebsiteRoot "Bin\PX.Data.dll"

if (!(Test-Path $projectFile)) { throw "Project file not found: $projectFile" }
if (!(Test-Path $projectItemsRoot)) { throw "Project items folder not found: $projectItemsRoot" }
if (!(Test-Path $pxCommandLine)) { throw "PX.CommandLine.exe not found: $pxCommandLine" }
if (!(Test-Path $siteDataDll)) { throw "PX.Data.dll not found: $siteDataDll" }

function Get-FileBuildVersion {
	param([string]$Path)
	return (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
}

$siteBuild = Get-FileBuildVersion $siteDataDll
if ($siteBuild -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
	throw "Cannot determine Acumatica build from $siteDataDll (FileVersion: $siteBuild)"
}
$siteDataHash = (Get-FileHash -LiteralPath $siteDataDll -Algorithm SHA256).Hash

function Assert-ResolvedReferencesMatchSite {
	param([string]$Project, [string]$Configuration, [string]$Site, [string]$Build)

	# ResolveAssemblyReference is the authority, not project XML. -restore also handles SDK projects
	# whose assets file has not been created yet. Never rewrite project-owned HintPaths.
	$lines = @(& dotnet msbuild $Project -restore -target:ResolveReferences -getItem:Reference,ReferencePath `
		-property:Configuration=$Configuration -property:AcumaticaWebsiteRoot=$Site -verbosity:quiet -nologo 2>&1)
	if ($LASTEXITCODE -ne 0) { throw "Reference resolution failed ($LASTEXITCODE): $($lines -join [Environment]::NewLine)" }
	$report = $lines -join [Environment]::NewLine
	$start = [regex]::Match($report, '(?s)\{\s*"Items"\s*:')
	if (!$start.Success) { throw "MSBuild did not return resolved references: $report" }
	try { $items = ($report.Substring($start.Index) | ConvertFrom-Json).Items }
	catch { throw "Could not parse MSBuild resolved references: $report" }
	$resolved = @($items.ReferencePath)
	$resolvedNames = @($resolved | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension([string]$_.Identity) })
	foreach ($reference in @($items.Reference)) {
		$name = ([string]$reference.Identity).Split(',')[0]
		if ($name -match '^PX\.' -and $name -notin $resolvedNames) {
			throw "Acumatica reference $name did not resolve for $Project. Check its evaluated HintPath and AcumaticaWebsiteRoot."
		}
	}

	foreach ($reference in @($resolved)) {
		$path = [string]$reference.Identity
		if ([System.IO.Path]::GetFileName($path) -notmatch '^PX\..*\.dll$') { continue }
		if (!(Test-Path -LiteralPath $path)) { throw "Resolved Acumatica reference not found: $path" }
		$actual = Get-FileBuildVersion $path
		if ($actual -ne $Build) {
			throw "Acumatica reference $path has build $actual, but website $Site has build $Build. Set project HintPaths using AcumaticaWebsiteRoot or select the matching website."
		}
	}
}

function Normalize-ModernUiPackagePaths {
	param([string]$ZipPath)

	$patchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("extension-package-paths-" + [guid]::NewGuid().ToString("N"))
	try {
		Add-Type -AssemblyName System.IO.Compression.FileSystem
		[System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $patchRoot)

		$sourceScreensRoot = Join-Path $patchRoot "screens"
		$targetScreensRoot = Join-Path $patchRoot "development\screens"
		if (Test-Path $sourceScreensRoot) {
			New-Item -ItemType Directory -Force -Path $targetScreensRoot | Out-Null
			Get-ChildItem -Path $sourceScreensRoot -Force | ForEach-Object {
				Move-Item -Force -Path $_.FullName -Destination (Join-Path $targetScreensRoot $_.Name)
			}
			Remove-Item -Recurse -Force $sourceScreensRoot
		}

		$projectXmlPath = Join-Path $patchRoot "project.xml"
		if (Test-Path $projectXmlPath) {
			$projectXmlText = Get-Content -Raw -Path $projectXmlPath
			$projectXmlText = $projectXmlText.Replace('AppRelativePath="screens\', 'AppRelativePath="development\screens\')
			Set-Content -Path $projectXmlPath -Value $projectXmlText -NoNewline
		}

		Remove-Item $ZipPath -Force
		[System.IO.Compression.ZipFile]::CreateFromDirectory($patchRoot, $ZipPath)
	}
	finally {
		if (Test-Path $patchRoot) { Remove-Item -Recurse -Force $patchRoot }
	}
}

# Remove previous deliverables before any native command can fail. An unsuccessful attempt
# must not leave an old ZIP or, on a build, an old DLL that a later run could package.
if (Test-Path $outZip) { Remove-Item $outZip -Force }
if (!$SkipDotnetBuild) {
	if (Test-Path $receiptPath) { Remove-Item $receiptPath -Force }
	if (Test-Path $dllPath) { Remove-Item $dllPath -Force }
	if (Test-Path $pdbPath) { Remove-Item $pdbPath -Force }
}

Assert-ResolvedReferencesMatchSite -Project $projectFile -Configuration $buildConfiguration -Site $WebsiteRoot -Build $siteBuild

if (!$SkipDotnetBuild) {
	Push-Location $extensionRoot
	try {
		& dotnet build $projectFile -c $buildConfiguration -nologo -property:AcumaticaWebsiteRoot=$WebsiteRoot
		if ($LASTEXITCODE -ne 0) { throw "dotnet build failed with exit code $LASTEXITCODE" }
	}
	catch {
		if (Test-Path $dllPath) { Remove-Item $dllPath -Force }
		if (Test-Path $pdbPath) { Remove-Item $pdbPath -Force }
		throw
	}
	finally {
		Pop-Location
	}
}

if (!(Test-Path $dllPath)) { throw "Compiled DLL not found: $dllPath" }
if ($SkipDotnetBuild) {
	if (!(Test-Path $receiptPath)) {
		throw "No checked build receipt for $dllPath. Run one full build before SkipDotnetBuild."
	}
	try { $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json }
	catch { throw "Invalid checked build receipt $receiptPath. Run one full build before SkipDotnetBuild." }
	$dllHash = (Get-FileHash -LiteralPath $dllPath -Algorithm SHA256).Hash
	if ($receipt.dllSha256 -ne $dllHash -or $receipt.siteBuild -ne $siteBuild -or $receipt.sitePxDataSha256 -ne $siteDataHash) {
		throw "Prebuilt DLL or selected website does not match checked build receipt $receiptPath. Run a full build for this website."
	}
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("extension-package-" + [guid]::NewGuid().ToString("N"))
$stagingBinRoot = Join-Path $stagingRoot "Bin"
$stagingProjectItemsRoot = Join-Path $stagingRoot "_project"

try {
	New-Item -ItemType Directory -Force -Path $stagingBinRoot | Out-Null
	New-Item -ItemType Directory -Force -Path $stagingProjectItemsRoot | Out-Null

	$projectItemFiles = @(Get-ChildItem -Path $projectItemsRoot -Filter "*.xml" -File)
	if ($projectItemFiles.Count -eq 0) { throw "No customization project XML found: $projectItemsRoot" }
	$projectItemFiles | Copy-Item -Destination $stagingProjectItemsRoot -Force
	Copy-Item -Force $dllPath (Join-Path $stagingBinRoot $dllName)
	if (Test-Path $pdbPath) { Copy-Item -Force $pdbPath (Join-Path $stagingBinRoot $pdbName) }

	foreach ($relativeFile in @($manifest.frontendFiles)) {
		if ([string]::IsNullOrWhiteSpace([string]$relativeFile)) { continue }

		$sourceFile = Join-Path $extensionRoot ([string]$relativeFile)
		if (!(Test-Path $sourceFile)) { throw "Frontend package file not found: $sourceFile" }

		$targetFile = Join-Path $stagingRoot ([string]$relativeFile)
		$targetDir = Split-Path -Parent $targetFile
		New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
		Copy-Item -Force $sourceFile $targetFile
	}

	& $pxCommandLine `
		/method buildproject `
		/website $WebsiteRoot `
		/in $stagingRoot `
		/out $outZip `
		/description ([string]$manifest.description) `
		/level 0
	if ($LASTEXITCODE -ne 0) { throw "PX.CommandLine buildproject failed with exit code $LASTEXITCODE" }
	if (!(Test-Path $outZip)) { throw "Customization ZIP was not produced: $outZip" }

	if ($normalizeModernUiPaths) {
		Normalize-ModernUiPackagePaths -ZipPath $outZip
	}
	if (!$SkipDotnetBuild) {
		@{
			dllSha256 = (Get-FileHash -LiteralPath $dllPath -Algorithm SHA256).Hash
			siteBuild = $siteBuild
			sitePxDataSha256 = $siteDataHash
		} | ConvertTo-Json | Set-Content -LiteralPath $receiptPath
	}
}
catch {
	if (Test-Path $outZip) { Remove-Item $outZip -Force }
	throw
}
finally {
	if (Test-Path $stagingRoot) { Remove-Item -Recurse -Force $stagingRoot }
}

if (!(Test-Path $outZip)) { throw "Customization ZIP was not produced: $outZip" }
Write-Output "ZIP=$outZip"
