# This script prepares all the required files for the NuGet package.
# * .targets file
# * Header files
# * DLL and import library files

$ErrorActionPreference = "Stop"

################################################################################
# Definitions

# MSBuild Settings

Set-Variable -Name Toolsets -Option Constant -Value @(
    "v100", "v110", "v110_xp", "v120", "v120_xp"
)

Set-Variable -Name Platforms -Option Constant -Value @(
    "Win32", "x64"
)

Set-Variable -Name Configs -Option Constant -Value @(
    "Debug", "Release"
)

################################################################################
# Functions

# Print message with time.

function showMsg($msg)
{
    $d = Get-Date -Format "HH:mm:ss"
    Write-Host "[$d] " -ForegroundColor Yellow -NoNewLine
    Write-Host "$msg " -ForegroundColor Green
}

# Download a file from the internet.

function download($url, $dir)
{
    $wc = New-Object System.Net.WebClient

    $f = Join-Path $dir (Split-Path $url -Leaf)
    $wc.DownloadFile($url, $f)

    return $f;
}

# Extract a ZIP file.

function extract($path)
{
    $e = Join-Path (Get-Location) "tools\unzip.exe"
    $d = Split-Path $path -Parent
    $f = Split-Path $path -Leaf
    execute $e $f $d
}

function execute($exe, $params, $dir)
{
    # It looks like WaitForExit() is more stable than -Wait.

    $proc = Start-Process $exe $params -WorkingDirectory $dir `
        -NoNewWindow -PassThru
    $proc.WaitForExit()
}

################################################################################
# Main

$thisDir = Split-Path $script:myInvocation.MyCommand.path -Parent

# Read the settings.

$tempDir    = ""
$msbuildExe = ""
$lines = Get-Content (Join-Path $thisDir "prepare.ini") -Encoding UTF8
foreach ($line in $lines) {
    $s = $line.split("=").Trim()
    if ($s[0] -eq "TempDir") {
        $tempDir = $s[1]
    }
    elseif ($s[0] -eq "MSBuildExe") {
        $msbuildExe = $s[1]
    }
}
if ($tempDir -eq "" -or $msbuildExe -eq "") {
    showMsg("Error reading prepare.ini!")
    exit
}

# Locate the necessary files.

$sourceDir = Join-Path $tempDir "source"
$taglibUrl = "https://github.com/taglib/taglib/archive/v1.9.1.zip"
$taglibDir = Join-Path $sourceDir "taglib-1.9.1"
$zlibUrl = "http://zlib.net/zlib128.zip"
$zlibDir = Join-Path $sourceDir "zlib-1.2.8"

$workBaseDir  = Join-Path $tempDir "work"
$libBaseDir   = Join-Path $thisDir "package\lib\native"
$buildBaseDir = Join-Path $thisDir "package\build\native"

# Download and extract the source files if not found.

if (-not (Test-Path $sourceDir)) {
    New-Item -Path $sourceDir -ItemType directory | Out-Null
}

if (-not (Test-Path $taglibDir)) {
    showMsg "TagLib source not found. Downloading..."
    $f = download $taglibUrl $sourceDir
    extract $f
}

if (-not (Test-Path $zlibDir)) {
    showMsg "zlib source not found. Downloading..."
    $f = download $zlibUrl $sourceDir
    extract $f
}

if (Test-Path $workBaseDir) {
    Remove-Item -Path $workBaseDir -Recurse -Force
}

if (Test-Path $libBaseDir) {
    Remove-Item -Path $libBaseDir -Recurse -Force
}

if (Test-Path $buildBaseDir) {
    Remove-Item -Path $buildBaseDir -Recurse -Force
}

# Check TagLib version.

$fileName = Join-Path $taglibDir "CMakeLists.txt"
$lines = (Get-Content -Path $fileName -Encoding UTF8).Trim()

if ($lines.Length -ne 120 `
    -or $lines[48] -ne 'set(TAGLIB_LIB_MAJOR_VERSION "1")' `
    -or $lines[49] -ne 'set(TAGLIB_LIB_MINOR_VERSION "9")' `
    -or $lines[50] -ne 'set(TAGLIB_LIB_PATCH_VERSION "1")')
{
    showMsg "TagLib version mismatch!"
    exit
}

# Copy the header files which should be installed.

$headerSrcDir = Join-Path $taglibDir  "taglib"
$headerDstDir = Join-Path $libBaseDir "include"

$fileName = Join-Path $taglibDir "taglib\CMakeLists.txt"
$lines = (Get-Content -Path $fileName -Encoding UTF8).Trim()

if ($lines.Length -ne 335 `
    -or $lines[32]  -ne "set(tag_HDRS" `
    -or $lines[132] -ne ")")
{
    showMsg "Error reading taglib/CMakeLists.txt (header files)!"
    exit
}

foreach ($header in $lines[33..131])
{
    if ($header -eq '${CMAKE_BINARY_DIR}/taglib_config.h') {
        # Skip it. taglib_config.h is no longer used.
    }
    else {
        $src = Join-Path $headerSrcDir $header
        $dst = Join-Path $headerDstDir $header
        $dir = Split-Path $dst -Parent
        if (-not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType directory | Out-Null
        }
        Copy-Item $src $dst
    }
}

# Apply patches to taglib.h and tiostream.h.
# Workaround for TagLib1.x. Will be removed in TagLib2.0.

$fileName = Join-Path $headerDstDir "toolkit\taglib.h"
$lines = Get-Content -Path $fileName -Encoding UTF8
if (($lines.Length -ne 170) -or `
    ($lines[28] -ne "#include ""taglib_config.h""")) {
    showMsg "Can't apply a patch to taglib.h!"
}

$lines[28] = "//#include ""taglib_config.h"""
$lines | Set-Content -Path $fileName -Encoding UTF8

$fileName = Join-Path $headerDstDir "toolkit\tiostream.h"
$lines = (Get-Content -Path $fileName -Encoding UTF8)
if (($lines.Length -ne 169) -or `
    ($lines[52] -ne "    const std::string  m_name;") -or `
    ($lines[53] -ne "    const std::wstring m_wname;")) {
    showMsg "Can't apply a patch to tiostream.h!"
}

$lines = $Lines[0..51] + "#pragma warning(push)"          + $Lines[52..168]
$lines = $Lines[0..52] + "#pragma warning(disable: 4251)" + $Lines[53..169]
$lines = $Lines[0..55] + "#pragma warning(pop)"           + $Lines[56..170]
$lines | Set-Content -Path $fileName -Encoding UTF8

# Begin creating the targets file.

$targetsContent = @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">

"@

# Add include paths to the targets file.

$targetsContent += @"
  <ItemDefinitionGroup>
    <ClCompile>
      <AdditionalIncludeDirectories>
"@

$fileName = Join-Path $taglibDir "taglib\CMakeLists.txt"
$lines = (Get-Content -Path $fileName -Encoding UTF8).Trim()

if ($lines[0] -ne "set(CMAKE_INCLUDE_CURRENT_DIR ON)" `
    -or $lines[1] -ne "include_directories(" `
    -or $lines[26] -ne ")")
{
    showMsg "Error reading taglib/CMakeLists.txt (include directories)!"
    exit
}

$dirs = @("")
$dirs += $lines[2..25].Replace('${CMAKE_CURRENT_SOURCE_DIR}', "")
foreach ($dir in $dirs)
{
    $tmp = Join-Path "`$(MSBuildThisFileDirectory)..\..\lib\native\include" $dir
    $targetsContent += "$tmp;"
}

$targetsContent += @"
%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
    </ClCompile>
  </ItemDefinitionGroup>
  <Target Name="TagLib_AfterBuild" AfterTargets="AfterBuild" />

"@

# Go through all the platforms, toolsets and configurations.

$count = $Platforms.Length * $Toolsets.Length * $Configs.Length
$i = 1

:toolset foreach ($toolset in $Toolsets)
{
    foreach ($platform in $Platforms)
    {
        $binOutDir = Join-Path $libBaseDir "bin\$platform\$toolset"
        New-Item -Path $binOutDir -ItemType directory | Out-Null

        $libOutDir = Join-Path $libBaseDir "lib\$platform\$toolset"
        New-Item -Path $libOutDir -ItemType directory | Out-Null

        foreach ($config in $Configs)
        {
            showMsg "Start Buiding [$toolset, $platform, $config] ($i/$count)"

            # CMake and MsBuid parameters.

            $generator = "Visual Studio " + $toolset.Substring(1, 2)
            if ($platform -eq "x64") {
                $generator += " Win64"
            }

            $vsVer = $toolset.Substring(1, 2) + ".0"

            # Build zlib as a static library.

            $WorkDir = Join-Path $workBaseDir "$platform\$toolset\$config"
            $zlibWorkDir = Join-Path $workDir "zlib"
            New-Item -Path $zlibWorkDir -ItemType directory | Out-Null

            $params  = "-G ""$generator"" "
            $params += "-T ""$toolset"" "
            $params += """$zlibDir"" "
            execute "cmake.exe" $params $zlibWorkDir

            $zlibProject = Join-Path $zlibWorkDir "zlibstatic.vcxproj"
            Copy-Item (Join-Path $zlibDir "*.h") $zlibWorkDir

            $params  = """$zlibProject"" "
            $params += "/p:VisualStudioVersion=$vsVer "
            $params += "/p:Configuration=$config "
            $params += "/p:TargetName=zlib "
            execute $msbuildExe $params $zlibWorkDir

            $zlibLib = Join-Path $zlibWorkDir "$config\zlib.lib"

            # Build TagLib as a DLL.

            $taglibWorkDir = Join-Path $workDir "taglib"
            New-Item -Path $taglibWorkDir -ItemType directory | Out-Null

            $suffix = ""
            if ($config -eq "Debug") {
                $suffix = "d"
            }

            $params  = "-G ""$generator"" "
            $params += "-T ""$toolset"" "
            $params += "-DZLIB_INCLUDE_DIR=""$zlibWorkDir"" "
            $params += "-DZLIB_LIBRARY=""$zlibLib"" "
            $params += """$taglibDir"" "
            execute "cmake.exe" $params $taglibWorkDir

            $taglibProject = Join-Path $taglibWorkDir "taglib\tag.vcxproj"

            # I couldn't override some propreties of the TagLib project with
            # MSBuild for some reason. So modify the project file directly.

            $content = (Get-Content -Path $taglibProject -Encoding UTF8)
            $content = $content -Replace "Level3",    "TurnOffAllWarnings"
            $content = $content -Replace "MultiByte", "Unicode"
            $content = $content -Replace "tag.lib",   "taglib$suffix.lib"
            $content = $content -Replace "tag.pdb",   "taglib$suffix.pdb"

            $lineNo = $content.Length - 1
            if ($content[$lineNo] -eq "</Project>") {
                $content[$lineNo] `
                    = "<ItemGroup><ResourceCompile Include=""dllversion.rc"" />" `
                    + "</ItemGroup></Project>"
            }
            else {
                showMsg "Error modifying project file."
            }

            $content | Set-Content -Path $taglibProject -Encoding UTF8

            Copy-Item (Join-Path $thisDir "dllversion.rc") `
                (Join-Path $taglibWorkDir "taglib")

            $params  = """$taglibProject"" "
            $params += "/p:VisualStudioVersion=$vsVer "
            $params += "/p:Configuration=$config "
            $params += "/p:TargetName=taglib$suffix "
            execute $msbuildExe $params $taglibWorkDir

            # Copy necessary files

            $src = Join-Path $taglibWorkDir "taglib\$config\taglib$suffix.dll"
            Copy-Item $src $binOutDir

            $src = Join-Path $taglibWorkDir "taglib\$config\taglib$suffix.lib"
            Copy-Item $src $libOutDir

            # Add a reference to the binary files to the targets file.

            $label = "$platform-$toolset-$config"

            $condition  = "'`$(Platform.ToLower())' == '" + $platform.ToLower() + "' "
            $condition += "And '`$(PlatformToolset.ToLower())' == '" + $toolset.ToLower() + "' "
            $condition += "And ( `$(Configuration.ToLower().IndexOf('debug')) "
            if ($config -eq "Debug") {
                $condition += "&gt; "
            }
            else {
                $condition += "== "
            }
            $condition += "-1)"

            $libPath  = "`$(MSBuildThisFileDirectory)"
            $libPath += "..\..\lib\native\lib\$platform\$toolset\taglib$suffix.lib"
            $dllPath  = "`$(MSBuildThisFileDirectory)"
            $dllPath += "..\..\lib\native\bin\$platform\$toolset\taglib$suffix.dll"

            $targetsContent += @"
  <ItemDefinitionGroup Label="$label" Condition="$condition">
    <Link>
      <AdditionalDependencies>$libPath;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
  <Target Name="TagLib_AfterBuild_$label" Label="$label" Condition="$Condition" AfterTargets="TagLib_AfterBuild">
    <Copy SourceFiles="$dllPath" DestinationFolder="`$(TargetDir)" SkipUnchangedFiles="true" />
  </Target>

"@
            $i++;
        }
    }
}

# Finish creating the targets file.

$targetsContent += @"
</Project>

"@

New-Item -Path $buildBaseDir -ItemType directory | Out-Null
[System.IO.File]::WriteAllText( `
    (Join-Path $buildBaseDir "taglibcpp.targets"), $targetsContent)

