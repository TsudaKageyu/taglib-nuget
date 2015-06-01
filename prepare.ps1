# This script prepares all the required files for the NuGet package.
# * .targets file
# * Header files
# * DLL and import library files

$ErrorActionPreference = "Stop"

################################################################################
# Definitions

# MSBuild Settings

Set-Variable -Name Toolsets -Option Constant -Value @(
    "v90", "v100", "v110", "v120"
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
    $e = Join-Path (Get-Location) "tools\7za.exe"
    $d = Split-Path $path -Parent
    $f = Split-Path $path -Leaf
    execute $e "x ""$f""" $d
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

$sourceDir = Join-Path $tempDir "taglib\source"
$taglibUrl = "https://github.com/TsudaKageyu/taglib/archive/1.9.1-beta10.zip"
$taglibDir = Join-Path $sourceDir "taglib-1.9.1-beta10"
$zlibUrl = "http://zlib.net/zlib128.zip"
$zlibDir = Join-Path $sourceDir "zlib-1.2.8"

$workBaseDir  = Join-Path $tempDir "taglib\work"
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

if ($lines.Length -ne 131 `
    -or $lines[54] -ne 'set(TAGLIB_LIB_MAJOR_VERSION "1")' `
    -or $lines[55] -ne 'set(TAGLIB_LIB_MINOR_VERSION "9")' `
    -or $lines[56] -ne 'set(TAGLIB_LIB_PATCH_VERSION "1")')
{
    showMsg "TagLib version mismatch!"
    exit
}

# Copy the header files which should be installed.

$headerSrcDir = Join-Path $taglibDir  "taglib"
$headerDstDir = Join-Path $libBaseDir "include"

$fileName = Join-Path $taglibDir "taglib\CMakeLists.txt"
$lines = (Get-Content -Path $fileName -Encoding UTF8).Trim()

if ($lines.Length -ne 361 `
    -or $lines[34]  -ne "set(tag_HDRS" `
    -or $lines[138] -ne ")")
{
    showMsg "Error reading taglib/CMakeLists.txt (header files)!"
    exit
}

foreach ($header in $lines[35..137])
{
    if ($header -eq '${CMAKE_CURRENT_BINARY_DIR}/../taglib_config.h') {
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
        $dirName = "$platform-$toolset".ToLower()

        $binOutDir = Join-Path $libBaseDir (Join-Path "bin" $dirName)
        New-Item -Path $binOutDir -ItemType directory | Out-Null

        $libOutDir = Join-Path $libBaseDir (Join-Path "lib" $dirName)
        New-Item -Path $libOutDir -ItemType directory | Out-Null

        foreach ($config in $Configs)
        {
            showMsg "Start Buiding [$toolset, $platform, $config] ($i/$count)"

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

            $suffix = ""
            if ($config -eq "Debug") {
                $suffix = "d"
            }

            $toolsetSuffix = "";
            if ([int]$vsVer -ge 11) {
                $toolsetSuffix = "_xp";
            }

            $zlibDirC = $zlibDir.Replace("\", "/")

            $WorkDir = Join-Path $workBaseDir "$platform\$toolset\$config"

            # Build TagLib as a DLL.

            New-Item -Path $workDir -ItemType directory | Out-Null

            $params  = "-G ""$generator"" "
            $params += "-T ""$toolset$toolsetSuffix"" "
            $params += "-DCMAKE_CXX_FLAGS=""/DWIN32 /D_WINDOWS /DUNICODE /D_UNICODE /W0 /GR /EHsc /arch:IA32 /MP "" "
            $params += "-DCMAKE_CXX_FLAGS_DEBUG=""/D_DEBUG /MDd /Zi /Ob0 /Od /RTC1"" "
            $params += "-DCMAKE_CXX_FLAGS_RELEASE=""/MD /GL /O2 /Ob2 /D NDEBUG"" "
            $params += "-DZLIB_SOURCE=""$zlibDirC"" "
            $params += """$taglibDir"" "
            execute "cmake.exe" $params $workDir

            $taglibProject = Join-Path $workDir "taglib\tag.vcxproj"

            $content = (Get-Content -Path $taglibProject -Encoding UTF8)
            $content = $content -Replace "<ImportLibrary>.*</ImportLibrary>", ""
            $content = $content -Replace "<ProgramDatabaseFile>.*</ProgramDatabaseFile>", ""
            $lineNo = $content.Length - 1
            if ($content[$lineNo] -eq "</Project>") {
                $content[$lineNo] `
                    = "<ItemGroup><ClCompile Include=""dllmain.cpp"" /></ItemGroup>" `
                    + "<ItemGroup><ResourceCompile Include=""dllversion.rc"" /></ItemGroup>" `
                    + "</Project>"
            }
            else {
                showMsg "Error modifying project file."
            }
            $content | Set-Content -Path $taglibProject -Encoding UTF8

            $taglibSrcDir = Join-Path $workDir "taglib"
            Copy-Item (Join-Path $thisDir "src\dllmain.cpp")   $taglibSrcDir
            Copy-Item (Join-Path $thisDir "src\dllversion.rc") $taglibSrcDir

            $params  = """$taglibProject"" "
            $params += "/p:VisualStudioVersion=$vsVer "
            $params += "/p:Configuration=$config "
            $params += "/p:TargetName=taglib$suffix "
            execute $msbuildExe $params $workDir

            # Copy necessary files

            $dllPath = Join-Path $workDir "taglib\$config\taglib$suffix.dll"
            Copy-Item $dllPath $binOutDir

            if ($config -eq "Debug") {
                $pdbPath = Join-Path $workDir "taglib\$config\taglib$suffix.pdb"
                Copy-Item $pdbPath $binOutDir
            }

            $libPath = Join-Path $workDir "taglib\$config\taglib$suffix.lib"
            Copy-Item $libPath $libOutDir

            if ($i -eq 1) {
                $src = Join-Path $workDir "taglib_config.h"
                Copy-Item $src $headerDstDir
            }

            # Add a reference to the binary files to the targets file.

            $condition  = "'`$(Platform.ToLower())' == '" + $platform.ToLower() + "' "
            $condition += "And (`$(PlatformToolset.ToLower().IndexOf('" + $toolset.ToLower() + "')) == 0) "
            $condition += "And (`$(Configuration.ToLower().IndexOf('debug')) "
            if ($config -eq "Debug") {
                $condition += "&gt; "
            }
            else {
                $condition += "== "
            }
            $condition += "-1)"

            $label = "$toolset-$platform-$config".ToLower()
            $libPath = "..\..\lib\native\lib\$dirName\taglib$suffix.lib"
            $dllPath = "..\..\lib\native\bin\$dirName\taglib$suffix.dll"

            $targetsContent += @"
  <ItemDefinitionGroup Label="$label" Condition="$condition">
    <Link>
      <AdditionalDependencies>`$(MSBuildThisFileDirectory)$libPath;%(AdditionalDependencies)</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
  <Target Name="TagLib_AfterBuild_$label" Label="$label" Condition="$Condition" AfterTargets="TagLib_AfterBuild">
    <Copy SourceFiles="`$(MSBuildThisFileDirectory)$dllPath" DestinationFolder="`$(TargetDir)" SkipUnchangedFiles="true" />
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

