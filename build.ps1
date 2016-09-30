# This script prepares all the required files for the NuGet package.
# * .targets file
# * Header files
# * DLL and import library files

$ErrorActionPreference = "Stop"

################################################################################
# Definitions

# MSBuild Settings

Set-Variable -Name Toolsets -Option Constant -Value @(
    "v100", "v110", "v120", "v140"
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

# Execute a command.

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

$settings = ([XML](Get-Content (Join-Path $thisDir "settings.xml"))).settings

# Locate the necessary files.

if (-not (Test-Path $settings.msbuild_exe)) {
    showMsg("MsBuild.exe not found!")
    exit
}

$tempDir = Join-Path ([environment]::getenvironmentvariable("TEMP")) "taglib-nuget-build"

$sourceDir = Join-Path $tempDir "taglib\source"
$taglibDir = Join-Path $thisDir "src\taglib"
$zlibDir   = Join-Path $thisDir "src\zlib"

$workBaseDir  = Join-Path $tempDir "taglib\work"
$libBaseDir   = Join-Path $thisDir "package\lib\native"
$buildBaseDir = Join-Path $thisDir "package\build\native"

if (Test-Path $workBaseDir) {
    Remove-Item -Path $workBaseDir -Recurse -Force
}

if (Test-Path $libBaseDir) {
    Remove-Item -Path $libBaseDir -Recurse -Force
}

if (Test-Path $buildBaseDir) {
    Remove-Item -Path $buildBaseDir -Recurse -Force
}

New-Item -Path $buildBaseDir -ItemType directory | Out-Null
Remove-Item (Join-Path $thisDir "*.nuspec")
Remove-Item (Join-Path $thisDir "*.nupkg")

# Check TagLib version.

$fileName = Join-Path $taglibDir "taglib\toolkit\taglib.h"
$lines = (Get-Content -Path $fileName -Encoding UTF8).Trim()

if ($lines.Length -ne 170 `
    -or $lines[30] -ne '#define TAGLIB_MAJOR_VERSION 1' `
    -or $lines[31] -ne '#define TAGLIB_MINOR_VERSION 11' `
    -or $lines[32] -ne '#define TAGLIB_PATCH_VERSION 0')
{
    showMsg "TagLib version mismatch!"
    exit
}

# Copy the header files which should be installed.

$headerSrcDir = Join-Path $taglibDir  "taglib"
$headerDstDir = Join-Path $libBaseDir "include"

$fileName = Join-Path $taglibDir "taglib\CMakeLists.txt"
$lines = (Get-Content -Path $fileName -Encoding UTF8).Trim()

if ($lines.Length -ne 377 `
    -or $lines[38]  -ne "set(tag_HDRS" `
    -or $lines[143] -ne ")")
{
    showMsg "Error reading taglib/CMakeLists.txt (header files)!"
    exit
}

$headers = @()
foreach ($header in $lines[39..142])
{
    if ($header -eq '${CMAKE_CURRENT_BINARY_DIR}/../taglib_config.h') {
        # Skip it. taglib_config.h is no longer used.
    }
    else {
        $header = $header -Replace "/", "\"

        $src = Join-Path $headerSrcDir $header
        $dst = Join-Path $headerDstDir $header
        $dir = Split-Path $dst -Parent
        if (-not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType directory | Out-Null
        }
        Copy-Item $src $dst

        $headers += "        <file src=`"package\lib\native\include\$header`" target=`"lib\native\include\$header`" />"
    }
}

# Create the nuspec file for the header-only package.

$content = (Get-Content -Path (Join-Path $thisDir "taglibcpp.nuspec.template") -Encoding UTF8)
$content = $content -Replace "{{version}}", $settings.package.version
$content = $content -Replace "{{headers}}", ($headers -Join "`n")
$content | Set-Content -Path (Join-Path $thisDir "taglibcpp.nuspec") -Encoding UTF8

$metadata = ([xml]$content).package.metadata

# Create the targets file for the header-only package.

$targetsContent = @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">

"@

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
</Project>

"@

[System.IO.File]::WriteAllText( `
    (Join-Path $buildBaseDir "taglibcpp.targets"), $targetsContent)

# Build the header-only package.

NuGet pack (Join-Path $thisDir "taglibcpp.nuspec")

# Go through all the platforms, toolsets and configurations.

$count = $Platforms.Length * $Toolsets.Length * $Configs.Length
$i = 1

:toolset foreach ($toolset in $Toolsets)
{
    # Create the nuspec file for each toolset.

    $content = (Get-Content -Path (Join-Path $thisDir "taglibcpp-bin.nuspec.template") -Encoding UTF8)
    $content = $content -Replace "{{version}}", $settings.package.version
    $content = $content -Replace "{{toolset}}", $toolset
    $content | Set-Content -Path (Join-Path $thisDir "taglibcpp-$toolset.nuspec") -Encoding UTF8

    # Begin creating the targets file for each toolset.

    $targetsContent = @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <Target Name="TagLib_AfterBuild" AfterTargets="AfterBuild" />

"@

    foreach ($platform in $Platforms)
    {
        $dirName = "$platform-$toolset".ToLower()

        $binOutDir = Join-Path $libBaseDir (Join-Path "bin" $dirName)
        New-Item -Path $binOutDir -ItemType directory | Out-Null

        $libOutDir = Join-Path $libBaseDir (Join-Path "lib" $dirName)
        New-Item -Path $libOutDir -ItemType directory | Out-Null

        foreach ($config in $Configs)
        {
            showMsg "Start Building [$toolset, $platform, $config] ($i/$count)"

            $vsVer = $toolset.Substring(1, 2) + ".0"

            $env:BOOST_ROOT = $settings.boost_root
            $env:BOOST_INCLUDEDIR = Join-Path $settings.boost_root "boost"

            if ($platform -eq "x64") {
              $bitness = "64"
            }
            else {
              $bitness = "32"
            }

            $env:BOOST_LIBRARYDIR = Join-Path $settings.boost_root "lib$bitness-msvc-$vsVer"

            # CMake and MsBuid parameters.

            $generator = "Visual Studio " + $toolset.Substring(1, 2)

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

            $archFlag = ""
            if (([int]$vsVer -ge 11) -and ($platform -eq "Win32")) {
                $archFlag = "/arch:IA32"
            }

            $zlibDirC = $zlibDir.Replace("\", "/")

            $WorkDir = Join-Path $workBaseDir "$platform\$toolset\$config"

            # Build TagLib as a DLL.

            New-Item -Path $workDir -ItemType directory | Out-Null

            $params  = "-G ""$generator"" "
            $params += "-T ""$toolset$toolsetSuffix"" "
            $params += "-DBoost_USE_STATIC_LIBS=on "
            $params += "-DCMAKE_CXX_FLAGS=""/DWIN32 /D_WINDOWS /DUNICODE /D_UNICODE /W0 /GR /EHsc $archFlag /MP "" "
            $params += "-DCMAKE_CXX_FLAGS_DEBUG=""/D_DEBUG /MDd /Zi /Ob0 /Od /RTC1"" "
            $params += "-DCMAKE_CXX_FLAGS_RELEASE=""/MD /GL /O2 /Ob2 /D NDEBUG"" "
            $params += "-DBUILD_SHARED_LIBS=on "
            $params += """$taglibDir"" "
            execute $settings.cmake_exe $params $workDir
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
            execute $settings.msbuild_exe $params $workDir

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
            $condition += "And (`$(Configuration.ToLower().IndexOf('debug')) "
            if ($config -eq "Debug") {
                $condition += "&gt; "
            }
            else {
                $condition += "== "
            }
            $condition += "-1)"

            $label = "${platform}_${config}".ToLower()
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

"@

            if ($config -eq "Debug") {
                $targetsContent += @"
    <Copy SourceFiles="`$(MSBuildThisFileDirectory)$pdbPath" DestinationFolder="`$(TargetDir)" SkipUnchangedFiles="true" />
"@
            }

            $targetsContent += @"
  </Target>

"@
            $i++;
        }
    }

    # Finish creating the targets file.

    $targetsContent += @"
</Project>

"@

    [System.IO.File]::WriteAllText( `
        (Join-Path $buildBaseDir "taglibcpp-$toolset.targets"), $targetsContent)

    # Build the binary package for each toolset.

    NuGet pack (Join-Path $thisDir "taglibcpp-$toolset.nuspec")
}

