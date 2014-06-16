# This script prepares all the required files for the NuGet package.
# * .targets file
# * Header files
# * DLL and import library files

$ErrorActionPreference = "Stop"

################################################################################
# Definitions

# MSBuild Settings

Set-Variable -Name Toolsets -Option Constant -Value @(
    "v90", "v100", "v110", "v110_xp", "v120", "v120_xp"
)

Set-Variable -Name Platforms -Option Constant -Value @(
    "Win32", "x64"
)

Set-Variable -Name RuntimeLinks -Option Constant -Value @(
    "MD", "MT"
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

# Begin creating the targets file.

$targetsContent = @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">

"@

# Add include paths to the targets file.

$targetsContent += @"
  <ItemDefinitionGroup>
    <ClCompile>
      <PreprocessorDefinitions>TAGLIB_STATIC;%(PreprocessorDefinitions)</PreprocessorDefinitions>
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
    <Link>
      <AdditionalDependencies>`$(MSBuildThisFileDirectory)..\..\lib\native\lib\taglib.lib;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>

  <Target Name="BeforeClCompile">

    <!-- Check if the runtime link is dynamic or static -->

    <CreateProperty Value="%(ClCompile.RuntimeLibrary)">
      <Output TaskParameter="Value" PropertyName="TagLib_RuntimeLibrary" />
    </CreateProperty>

    <!-- TagLib_RuntimeLink corresponds to /MDd, /MD, /MTd and /MT options -->

    <CreateProperty Condition="(`$(TagLib_RuntimeLibrary.ToLower().IndexOf('dll')) &gt; -1) And (`$(Configuration.ToLower().IndexOf('debug')) &gt; -1)" Value="mdd">
      <Output TaskParameter="Value" PropertyName="TagLib_RuntimeLink" />
    </CreateProperty>
    <CreateProperty Condition="(`$(TagLib_RuntimeLibrary.ToLower().IndexOf('dll')) &gt; -1) And (`$(Configuration.ToLower().IndexOf('debug')) == -1)" Value="md">
      <Output TaskParameter="Value" PropertyName="TagLib_RuntimeLink" />
    </CreateProperty>
    <CreateProperty Condition="(`$(TagLib_RuntimeLibrary.ToLower().IndexOf('dll')) == -1) And (`$(Configuration.ToLower().IndexOf('debug')) &gt; -1)" Value="mtd">
      <Output TaskParameter="Value" PropertyName="TagLib_RuntimeLink" />
    </CreateProperty>
    <CreateProperty Condition="(`$(TagLib_RuntimeLibrary.ToLower().IndexOf('dll')) == -1) And (`$(Configuration.ToLower().IndexOf('debug')) == -1)" Value="mt">
      <Output TaskParameter="Value" PropertyName="TagLib_RuntimeLink" />
    </CreateProperty>

    <!-- Suffix of lib & dll file like 'win32-v100-mdd' -->

    <CreateProperty Value="`$(Platform.ToLower())-`$(PlatformToolset.ToLower())-`$(TagLib_RuntimeLink)">
      <Output TaskParameter="Value" PropertyName="TagLib_LibSuffix" />
    </CreateProperty>


"@

# Go through all the platforms, toolsets and configurations.

$count = $Platforms.Length * $Toolsets.Length * $RuntimeLinks.Length * $Configs.Length
$i = 1

:toolset foreach ($toolset in $Toolsets)
{
    foreach ($platform in $Platforms)
    {
        foreach ($runtime in $RuntimeLinks)
        {
            foreach ($config in $Configs)
            {
                showMsg "Start Buiding [$toolset, $platform, $runtime, $config] ($i/$count)"

                $libSuffix = "$platform-$toolset-$runtime".ToLower()
                if ($config -eq "Debug") {
                    $libSuffix += "d"
                }

                $binOutDir = Join-Path $libBaseDir (Join-Path "bin" $libSuffix)
                New-Item -Path $binOutDir -ItemType directory | Out-Null

                $libOutDir = Join-Path $libBaseDir (Join-Path "lib" $libSuffix)
                New-Item -Path $libOutDir -ItemType directory | Out-Null

                # CMake and MsBuid parameters.

                $generator = "Visual Studio ";
                $vsVer = ""
                if ($toolset -eq "v90") {
                    $generator += "10"
                    $vsVer = "10.0"
                }
                else {
                    $generator += $toolset.Substring(1, 2)
                    $vsVer = $toolset.Substring(1, 2) + ".0"
                }
                if ($platform -eq "x64") {
                    $generator += " Win64"
                }

                $runtimeLib = "MultiThreaded"
                if ($config -eq "Debug") {
                    $runtimeLib += "Debug"
                }
                if ($runtime -eq "MD") {
                    $runtimeLib += "DLL"
                }

                # Build zlib as a static library.

                $WorkDir = Join-Path $workBaseDir "$platform\$toolset\$runtime\$config"
                $zlibWorkDir = Join-Path $workDir "zlib"
                New-Item -Path $zlibWorkDir -ItemType directory | Out-Null

                $params  = "-G ""$generator"" "
                $params += "-T ""$toolset"" "
                $params += """$zlibDir"" "
                execute "cmake.exe" $params $zlibWorkDir

                $zlibProject = Join-Path $zlibWorkDir "zlibstatic.vcxproj"
                Copy-Item (Join-Path $zlibDir "*.h") $zlibWorkDir

                # I couldn't override some propreties of the projects with
                # MSBuild for some reason. So modify the project file directly.

                $content = (Get-Content -Path $zlibProject -Encoding UTF8)
                $content = $content -Replace `
                    "<RuntimeLibrary>.*</RuntimeLibrary>", `
                    "<RuntimeLibrary>$runtimeLib</RuntimeLibrary>"
                $content | Set-Content -Path $zlibProject -Encoding UTF8

                $params  = """$zlibProject"" "
                $params += "/p:VisualStudioVersion=$vsVer "
                $params += "/p:Configuration=$config "
                $params += "/p:TargetName=zlib "
                $params += "/m "
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

                $content = (Get-Content -Path $taglibProject -Encoding UTF8)
                $content = $content -Replace `
                    "<RuntimeLibrary>.*</RuntimeLibrary>", `
                    "<RuntimeLibrary>$runtimeLib</RuntimeLibrary>"
                $content = $content -Replace "Level3",    "TurnOffAllWarnings"
                $content = $content -Replace "MultiByte", "Unicode"
                $content = $content -Replace "tag.lib",   "taglib.lib"
                $content = $content -Replace "tag.pdb",   "taglib.pdb"

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
                $params += "/p:TargetName=taglib "
                $params += "/m "
                execute $msbuildExe $params $taglibWorkDir

                # Copy necessary files

                $src = Join-Path $taglibWorkDir "taglib\$config\taglib.dll"
                Copy-Item $src $binOutDir

                $src = Join-Path $taglibWorkDir "taglib\$config\taglib.lib"
                Copy-Item $src $libOutDir

                if ($i -eq 1) {
                    $src = Join-Path $taglibWorkDir "taglib_config.h"
                    Copy-Item $src $headerDstDir
                }

                # Add a reference to the binary files to the targets file.

                $label = "$platform-$toolset-$config"

                $condition = "`$(TagLib_LibSuffix) == '$libSuffix'"
                $libPath = "..\..\lib\native\lib\$libSuffix\taglib.lib"
                $dllPath = "..\..\lib\native\bin\$libSuffix\taglib.dll"

                $targetsContent += @"
    <Copy Condition="$condition" SourceFiles="`$(MSBuildThisFileDirectory)$libPath" DestinationFolder="`$(MSBuildThisFileDirectory)..\..\lib\native\lib\" />
    <Copy Condition="$condition" SourceFiles="`$(MSBuildThisFileDirectory)$dllPath" DestinationFolder="`$(TargetDir)" />

"@

                $i++;
            }
        }
    }
}

# Finish creating the targets file.

$targetsContent += @"
  </Target>
</Project>

"@

New-Item -Path $buildBaseDir -ItemType directory | Out-Null
[System.IO.File]::WriteAllText( `
    (Join-Path $buildBaseDir "taglibcpp.targets"), $targetsContent)

