#!/bin/bash

# Requirements: git-bash
# https://git-scm.com/download/win

set -Eeuo pipefail
# set -o xtrace

trap cleanup SIGINT SIGTERM ERR EXIT

ScriptFullname=$(readlink -e "$0")
ScriptName=$(basename "$0")
ScriptDir=$(dirname "$ScriptFullname")

# Useful things
source "$ScriptDir/helper.lib"

# Common
SteamPath=$(reg_readkey "HKCU\Software\Valve\Steam" "SteamPath")
DocumentsPath=$(reg_readkey "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" "Personal")
WorkDir="$(dirname "$(readlink -e "$0")")"
ThirdPartyBin="$ScriptDir/3rd-party-bin"

# Usefull KF2 executables / Paths / Configs
KFDoc="$DocumentsPath/My Games/KillingFloor2"
KFPath="$SteamPath/steamapps/common/killingfloor2"
KFWin64="$KFPath/Binaries/Win64"
KFEditor="$KFWin64/KFEditor.exe"
KFEditorPatcher="$KFWin64/kfeditor_patcher.exe"
KFEditorMergePackages="$KFWin64/KFEditor_mergepackages.exe"
KFGame="$KFWin64/KFGame.exe"
KFWorkshop="$KFPath/Binaries/WorkshopUserTool.exe"
KFUnpublish="$KFDoc/KFGame/Unpublished"
KFPublish="$KFDoc/KFGame/Published"
KFEditorConf="$KFDoc/KFGame/Config/KFEditor.ini"

# Source filesystem
MutSource="$ScriptDir/.."
MutPubContent="$MutSource/PublicationContent"
MutConfig="$MutSource/Config"
MutLocalization="$MutSource/Localization"
MutBuildConfig="$MutSource/build.ini" # not ini at all but who cares? :D
MutTestConfig="$MutSource/test.ini"

# Steam workshop upload filesystem
KFUnpublishBrewedPC="$KFUnpublish/BrewedPC"
KFUnpublishPackages="$KFUnpublishBrewedPC/Packages"
KFUnpublishScript="$KFUnpublishBrewedPC/Script"
KFUnpublishConfig="$KFUnpublish/Config"
KFUnpublishLocalization="$KFUnpublish/Localization"
KFPublishBrewedPC="$KFPublish/BrewedPC"
KFPublishPackages="$KFPublishBrewedPC/Packages"
KFPublishScript="$KFPublishBrewedPC/Script"
KFPublishConfig="$KFPublish/Config"
KFPublishLocalization="$KFPublish/Localization"

# Tmp files
MutWsInfoName="wsinfo.txt"
MutWsInfo="$KFDoc/$MutWsInfoName"
KFEditorConfBackup="$KFEditorConf.backup"

function show_help ()
{
	cat <<EOF
Usage: $0 OPTION

Build, pack, test and upload your kf2 packages to the Steam Workshop.

Available options:
 -ib, --init-build   generate $(basename "$MutBuildConfig") with build parameters 
 -it, --init-test    generate $(basename "$MutTestConfig") with test parameters 
  -i, --init         the same as "./$ScriptName --init-build; ./$ScriptName --init-test"
  -c, --compile      build package(s)
  -b, --brew         compress *.upk and place inside *.u
 -bm, --brew-manual  the same (almost) as above, but with patched kfeditor by @notpeelz
  -u, --upload       upload package(s) to the Steam Workshop 
  -t, --test         run local single player test with $(basename "$MutTestConfig") parameters
  -v, --version      show version
  -h, --help         show this help
EOF
}

function show_version ()
{
	cat <<EOF
$ScriptName $(git describe)
EOF
}

function cleanup()
{
	trap - SIGINT SIGTERM ERR EXIT
	restore_kfeditorconf
}

function backup_kfeditorconf ()
{
	cp -f "$KFEditorConf" "$KFEditorConfBackup"
}

function restore_kfeditorconf ()
{
	if [[ -f "$KFEditorConfBackup" ]]; then
		mv -f "$KFEditorConfBackup" "$KFEditorConf"
	fi
}

function init_build ()
{
	local PackageList=""
	
	:> "$MutBuildConfig"
	
	while read Package
	do
		if [[ -z "$PackageList" ]]; then
			PackageList="$Package"
		else
			PackageList="$PackageList $Package"
		fi
	done < <(find "$MutSource" -mindepth 2 -maxdepth 2 -type d -ipath '*/Classes' | sed -r 's|.+/([^/]+)/[^/]+|\1|' | sort)
	
	echo "PackageBuildOrder=\"$PackageList\""  >> "$MutBuildConfig"
	echo "PackageUpload=\"$PackageList\"" >> "$MutBuildConfig"
}

function read_build_settings ()
{
	if ! [[ -f "$MutBuildConfig" ]]; then init_build; fi
	
	if bash -n "$MutBuildConfig"; then
		source "$MutBuildConfig"
	else
		echo "$MutBuildConfig broken! Check this file before continue or create new one using $0 --init-build"
		return 1
	fi
}

function read_test_settings ()
{
	if ! [[ -f "$MutTestConfig" ]]; then init_test;	fi
	
	if bash -n "$MutTestConfig"; then
		source "$MutTestConfig"
	else
		echo "$MutTestConfig broken! Check this file before continue or create new one using $0 --init-test"
		return 1
	fi
}

function merge_packages () # $1: Mutator name
{
	local UpkList=""
	
	cp -f "$KFUnpublishScript/$1.u" "$KFWin64"
	
	while read Upk
	do
		cp -f "$MutSource/$1/$Upk" "$KFWin64"
		UpkList="$UpkList $Upk"
	done < <(find "$MutSource/$1" -type f -name '*.upk' -printf "%f\n")
	
	if [[ -n "$UpkList" ]]; then
		local ModificationTime=$(stat -c %y "$KFWin64/$1.u")
		CMD //C "cd "$(cygpath -w "$KFWin64")" && $(basename "$KFEditorMergePackages") make $UpkList $1.u" &
		local PID="$!"
		while ps -p "$PID" &> /dev/null
		do
			if [[ "$ModificationTime" != "$(stat -c %y "$KFWin64/$1.u")" ]]; then # file changed
				sleep 2 # wait a bit in case the file hasn't been written to the end yet 
				kill "$PID"; break
			fi
			sleep 2
		done
	fi
	
	for Upk in $UpkList; do	rm -f "$KFWin64/$Upk"; done # cleanup
}

function compiled ()
{
	for Package in $PackageBuildOrder
	do
		if ! test -f "$KFUnpublishScript/$Package.u"; then
			return 1
		fi
	done
}

function compile ()
{
	read_build_settings
	
	if ! command -v multini &> /dev/null; then
		get_latest_multini "$ThirdPartyBin"
	fi
	
	backup_kfeditorconf
	
	multini --del "$KFEditorConf" 'ModPackages' 'ModPackages'
	for Package in $PackageBuildOrder
	do
		multini --add "$KFEditorConf" 'ModPackages' 'ModPackages' "$Package"
	done
	multini --set "$KFEditorConf" 'ModPackages' 'ModPackagesInPath' "$(cygpath -w "$MutSource")"
	
	rm -rf "$KFUnpublish" "$KFPublish"
	
	mkdir -p "$KFUnpublishPackages" "$KFUnpublishScript"
	
	pushd "$MutSource"
	find $PackageBuildOrder -type f -name '*.upk' -exec cp -f {} "$KFUnpublishPackages" \;
	popd
	
	if [[ -d "$MutLocalization" ]]; then
		mkdir -p "$KFUnpublishLocalization"
		cp -rf "$MutLocalization"/* "$KFUnpublishLocalization"
	fi
	
	if [[ -d "$MutConfig" ]]; then
		mkdir -p "$KFUnpublishConfig"
		cp -rf "$MutConfig"/* "$KFUnpublishConfig"
	fi
	
	CMD //C "$(cygpath -w "$KFEditor")" make -stripsource -useunpublished &
	local PID="$!"
	while ps -p "$PID" &> /dev/null
	do
		if compiled; then kill "$PID"; break; fi
		sleep 2
	done 
	
	restore_kfeditorconf
}

function publish_common ()
{
	if [[ -d "$MutLocalization" ]]; then
		mkdir -p "$KFPublishLocalization"
		cp -rf "$MutLocalization"/* "$KFPublishLocalization"
	fi
	
	if [[ -d "$MutConfig" ]]; then
		mkdir -p "$KFPublishConfig"
		cp -rf "$MutConfig"/* "$KFPublishConfig"
	fi
}

function brewed ()
{
	for Package in $PackageUpload
	do
		if ! test -f "$KFPublishBrewedPC/$Package.u"; then
			return 1
		fi
	done
}

function brew ()
{
	read_build_settings
	
	if ! compiled ; then
		echo "You must compile packages before brewing. Use $0 --compile for this."
		exit 1
	fi
	
	rm -rf "$KFPublish"
	
	mkdir -p "$KFPublishBrewedPC"
	
	CMD //C "cd "$(cygpath -w "$KFWin64")" && "$(basename "$KFEditor")" brewcontent -platform=PC $PackageUpload -useunpublished" &
	local PID="$!"
	while ps -p "$PID" &> /dev/null
	do
		if brewed; then kill "$PID"; break; fi
		sleep 2
	done
	
	publish_common
	
	rm -f "$KFPublishBrewedPC"/*.tmp # cleanup
}

function brew_manual ()
{
	read_build_settings
	
	if ! compiled ; then
		echo "You must compile packages before brewing. Use $0 --compile for this."
		exit 1
	fi
	
	rm -rf "$KFPublish"
	
	mkdir -p "$KFPublishBrewedPC" "$KFPublishScript"

	if ! [[ -x "$KFEditorPatcher" ]]; then
		get_latest_kfeditor_patcher "$KFEditorPatcher"
	fi
	
	pushd "$KFWin64" && "$KFEditorPatcher"; popd
	
	for Package in $PackageUpload
	do
		merge_packages "$Package"
		mv "$KFWin64/$Package.u" "$KFPublishScript"
	done
	
	publish_common
}

function upload ()
{
	read_build_settings
	
	if ! compiled ; then
		echo "You must compile packages before uploading. Use $0 --compile for this."
		exit 1
	fi
	
	if ! [[ -d "$KFPublish" ]]; then
		echo "Warn: uploading without brewing"
		mkdir -p "$KFPublishBrewedPC" "$KFPublishScript"
		
		for Package in $PackageUpload
		do
			cp -f "$KFUnpublishScript/$Package.u" "$KFPublishScript"
		done
		
		if [[ -d "$KFUnpublishPackages" ]]; then
			cp -rf "$KFUnpublishPackages" "$KFPublishPackages"
		fi
		
		publish_common
	fi
	
	local PreparedWsDir=$(mktemp -d -u -p "$KFDoc")
	
	cat > "$MutWsInfo" <<EOF
\$Description \"$(cat "$MutPubContent/description.txt")\"
\$Title \"$(cat "$MutPubContent/title.txt")\"
\$PreviewFile \"$(cygpath -w "$MutPubContent/preview.png")\"
\$Tags \"$(cat "$MutPubContent/tags.txt")\"
\$MicroTxItem \"false\"
\$PackageDirectory \"$(cygpath -w "$PreparedWsDir")\"
EOF
	
	cp -rf "$KFPublish"/* "$PreparedWsDir"
	
	CMD //C "$(cygpath -w "$KFWorkshop")" "$MutWsInfoName"
	
	rm -rf "$PreparedWsDir"
	rm -f "$MutWsInfo"
}

function init_test ()
{
	local AviableMutators=""
	local AviableGamemodes=""
	
	for Package in $PackageUpload
	do
		# find available mutators
		while read MutClass
		do
			if [[ -z "$AviableMutators" ]]; then
				AviableMutators="$Package.$MutClass"
			else
				AviableMutators="$AviableMutators,$Package.$MutClass"
			fi
		done < <(grep -rihPo '\s.+extends\s(KF)?Mutator' "$MutSource/$Package" | awk '{ print $1 }')
		
		# find available gamemodes
		while read GamemodeClass
		do
			if [[ -z "$AviableGamemodes" ]]; then
				AviableGamemodes="$Package.$MutClass"
			else
				AviableGamemodes="$AviableGamemodes,$Package.$MutClass"
			fi
		done < <(grep -rihPo '\s.+extends\sKFGameInfo_' "$MutSource/$Package" | awk '{ print $1 }')
	done
	
	if [[ -z "$AviableGamemodes" ]]; then
		AviableGamemodes="KFGameContent.KFGameInfo_Survival"
	fi
	
	cat > "$MutTestConfig" <<EOF
# Test parameters 

# Map:
Map="KF-Nuked"

# Game:
# Survival:       KFGameContent.KFGameInfo_Survival
# WeeklyOutbreak: KFGameContent.KFGameInfo_WeeklySurvival
# Endless:        KFGameContent.KFGameInfo_Endless
# Objective:      KFGameContent.KFGameInfo_Objective
# Versus:         KFGameContent.KFGameInfo_VersusSurvival
Game="$AviableGamemodes"

# Difficulty:
# Normal:         0
# Hard:           1
# Suicide:        2
# Hell:           3
Difficulty="0"

# GameLength:
# 4  waves:       0
# 7  waves:       1
# 10 waves:       2
GameLength="0"

# Mutators
Mutators="$AviableMutators"

# Additional parameters
Args=""
EOF
}

function run_test ()
{
	local UseUnpublished=""
	
	read_build_settings
	read_test_settings
	
	if ! brewed; then UseUnpublished="-useunpublished"; fi
	
	CMD //C "$(cygpath -w "$KFGame")" $Map?Difficulty=$Difficulty?GameLength=$GameLength?Game=$Game?Mutator=$Mutators?$Args $UseUnpublished -log
}

export PATH="$PATH:$ThirdPartyBin"

if [[ $# -eq 0 ]]; then show_help; exit 0; fi
case $1 in
	  -h|--help             ) show_help             ;;
	  -v|--version          ) show_version          ;;
	 -ib|--init-build       ) init_build            ;;
	 -it|--init-test        ) init_test             ;;
	  -i|--init             ) init_build; init_test ;;
	  -c|--compile          ) compile               ;;
	  -b|--brew             ) brew                  ;;
	 -bm|--brew-manual      ) brew_manual           ;;
	  -u|--upload           ) upload                ;;
	  -t|--test             ) run_test              ;;
	    *                   ) echo "Command not recognized: $1"; exit 1 ;;
esac
