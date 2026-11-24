param(
	[Parameter(Mandatory = $true)][string]$Builder,
	[string]$Site25 = "D:\AcumaticaInstances\clean25",
	[string]$Site26 = "C:\AcumaticaERP"
)

$ErrorActionPreference = "Stop"
$root = Join-Path ([IO.Path]::GetTempPath()) ("extension-guard-test-" + [guid]::NewGuid().ToString("N"))
$dll = Join-Path $root "Bin\GuardFixture.dll"
$receipt = "$dll.acumatica-build.json"
$zip = Join-Path $root "GuardFixture.zip"
$project = Join-Path $root "GuardFixture.csproj"
$source = Join-Path $root "Class1.cs"

function Assert-Fails {
	param([scriptblock]$Action, [string]$Message)
	try { & $Action | Out-Null }
	catch {
		if ($_.Exception.Message -notlike "*$Message*") { throw }
		return
	}
	throw "Expected failure containing '$Message'"
}

function Assert-Outputs {
	foreach ($path in @($dll, $receipt, $zip)) {
		if (!(Test-Path $path)) { throw "Missing successful build output: $path" }
	}
}

try {
	New-Item -ItemType Directory -Force -Path (Join-Path $root "_project") | Out-Null
	@{
		projectName = "GuardFixture"
		description = "Guard fixture"
		csproj = "GuardFixture.csproj"
		outputZip = "GuardFixture.zip"
	} | ConvertTo-Json | Set-Content (Join-Path $root "extension.package.json")
	Set-Content (Join-Path $root "_project\ProjectMetadata.xml") '<project name="GuardFixture" level="" description="Guard fixture" />'
	$propertyProject = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net48</TargetFramework>
    <OutputPath>Bin\</OutputPath>
    <AppendTargetFrameworkToOutputPath>false</AppendTargetFrameworkToOutputPath>
  </PropertyGroup>
  <ItemGroup>
    <Reference Include="PX.Data">
      <HintPath>$(AcumaticaWebsiteRoot)\Bin\PX.Data.dll</HintPath>
      <Private>false</Private>
    </Reference>
  </ItemGroup>
</Project>
'@
	Set-Content $project $propertyProject
	Set-Content $source 'public class GuardFixture : PX.Data.PXGraph<GuardFixture> {}'

	& $Builder -ExtensionPath $root -WebsiteRoot $Site25 | Out-Null
	Assert-Outputs
	& $Builder -ExtensionPath $root -WebsiteRoot $Site25 -SkipDotnetBuild | Out-Null
	Assert-Outputs
	Assert-Fails { & $Builder -ExtensionPath $root -WebsiteRoot $Site26 -SkipDotnetBuild } "does not match checked build receipt"

	& $Builder -ExtensionPath $root -WebsiteRoot $Site26 | Out-Null
	Assert-Outputs
	& $Builder -ExtensionPath $root -WebsiteRoot $Site26 -SkipDotnetBuild | Out-Null
	Assert-Outputs
	[IO.File]::AppendAllText($dll, "tampered")
	Assert-Fails { & $Builder -ExtensionPath $root -WebsiteRoot $Site26 -SkipDotnetBuild } "does not match checked build receipt"
	& $Builder -ExtensionPath $root -WebsiteRoot $Site26 | Out-Null
	Assert-Outputs

	$metadata = Join-Path $root "_project\ProjectMetadata.xml"
	Set-Content $metadata "invalid project XML"
	Assert-Fails { & $Builder -ExtensionPath $root -WebsiteRoot $Site26 } "PX.CommandLine buildproject failed"
	if ((Test-Path $receipt) -or (Test-Path $zip)) { throw "Failed PX build left a receipt or ZIP" }
	Set-Content $metadata '<project name="GuardFixture" level="" description="Guard fixture" />'

	Set-Content $project $propertyProject.Replace('$(AcumaticaWebsiteRoot)', $Site25)
	Assert-Fails { & $Builder -ExtensionPath $root -WebsiteRoot $Site26 } "Acumatica reference"
	if (Test-Path $receipt) { throw "Failed reference check left a build receipt" }
	Set-Content $project $propertyProject

	& $Builder -ExtensionPath $root -WebsiteRoot $Site26 | Out-Null
	Assert-Outputs
	Remove-Item $receipt
	Assert-Fails { & $Builder -ExtensionPath $root -WebsiteRoot $Site26 -SkipDotnetBuild } "No checked build receipt"
	& $Builder -ExtensionPath $root -WebsiteRoot $Site26 | Out-Null
	Assert-Outputs
	Set-Content $source 'not valid C#'
	Assert-Fails { & $Builder -ExtensionPath $root -WebsiteRoot $Site26 } "dotnet build failed"
	foreach ($path in @($dll, $receipt, $zip)) {
		if (Test-Path $path) { throw "Failed build left a deliverable: $path" }
	}
	Write-Output "PASS: 25R1/26R1 full and skip builds, wrong references, missing/mismatched receipt and DLL, failed native cleanup"
}
finally {
	if (Test-Path $root) { Remove-Item $root -Recurse -Force }
}
