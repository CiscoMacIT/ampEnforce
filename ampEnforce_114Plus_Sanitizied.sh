#!bin/bash

## HEADER
# Package Title: Cisco AMP Enforcer 1.14+
# Author: Jacob Davidson <jadavids@cisco.com>

## DEFINITIONS

#Jamf Script Parameters
ampMinVersionString="$4"
ampMinVersionMajor=$(echo "$ampMinVersionString" | awk 'BEGIN { FS = "." } ; {print $1}')
ampMinVersionMinor=$(echo "$ampMinVersionString" | awk 'BEGIN { FS = "." } ; {print $2}')
ampMinVersionSub=$(echo "$ampMinVersionString" | awk 'BEGIN { FS = "." } ; {print $3}')
ampMinVersionBuild=$(echo "$ampMinVersionString" | awk 'BEGIN { FS = "." } ; {print $4}')
redirectingURL="$5"
businessUUID="$6"

softwareTitle=CiscoAMP
logFolder="/Library/Logs/CHANGEME"
logFile="$logFolder"/"$softwareTitle.log"
timeStamp=$(date "+%Y %b %d %T")
consoleUser=$(stat -f %Su "/dev/console")
logSize=$(stat -f%z $logFile)
maxSize=1000000
TestFailed=0
boolRunARecon=false
ciscoAMPPath="/Applications/Cisco AMP for Endpoints/AMP for Endpoints Connector.app/Contents/Info.plist"
policyPath="/Library/Application Support/Cisco/AMP for Endpoints Connector/policy.xml"
localInstallerVolume="/Volumes/ampmac_connector"
localInstallerPackage="ciscoampmac_connector.pkg"
tmpFolder="CHANGEME"

grabConsoleUserAndHome(){
  currentUser=$(stat -f %Su "/dev/console")
  homeFolder=$(dscl . read "/Users/$currentUser" NFSHomeDirectory | cut -d: -f 2 | sed 's/^ *//'| tr -d '\n')
  case "$homeFolder" in
     *\ * )
           homeFolder=$(printf %q "$homeFolder")
          ;;
       *)
           ;;
esac
}

grabConsoleUserAndHome

ampVersionTest(){
	ampVersionMajor=$(defaults read "$ciscoAMPPath" CFBundleShortVersionString | cut -f1 -d'.')
	ampVersionMinor=$(defaults read "$ciscoAMPPath" CFBundleShortVersionString | cut -f2 -d'.')
	ampVersionSub=$(defaults read "$ciscoAMPPath" CFBundleShortVersionString | cut -f3 -d'.')
	ampVersionBuild=$(defaults read "$ciscoAMPPath" CFBundleVersion | tr -d '.')
	if [[ $ampVersionMajor -lt $ampMinVersionMajor ]]
		then
			(( TestFailed++ ))
		elif [[ $ampVersionMajor -eq $ampMinVersionMajor ]]
			then
				if [[ $ampVersionMinor -lt $ampMinVersionMinor ]]
					then
						(( TestFailed++ ))
					elif [[ $ampVersionMinor -eq $ampMinVersionMinor ]]
						then
							if [[ $ampVersionSub -lt $ampMinVersionSub ]]
								then
									(( TestFailed++ ))
								elif [[ $ampVersionSub -eq $ampMinVersionSub ]]
								then
									if [[ $ampVersionBuild -lt $ampMinVersionBuild ]]
										then
											(( TestFailed++ ))
										else
											writeLog "AMP is up to date. Checking services..."
									fi
							fi
				fi
	fi
}

ampRunningTest()
{
launchDaemonRunning=$(launchctl print system/com.cisco.amp.daemon | grep -c "state = running")
launchAgentRunning=$(launchctl print gui/$(id -u "$currentUser")/com.cisco.amp.agent.app | grep -c "state = running")

if [[ "$currentUser" == "root" ]]
	then
		if [[ $launchDaemonRunning -lt 1 ]]
			then
				writeLog "No user is logged in..."
				writeLog "AMP LaunchDaemon is NOT running. Reinstalling..."
				(( TestFailed++ ))
		fi
	elif [[ $launchDaemonRunning -lt 1 ]] || [[ $launchAgentRunning -lt 1 ]]
		then
			writeLog "AMP LaunchDaemon or LaunchAgent NOT running. Reinstalling..."
			(( TestFailed++ ))
fi
}


checkAndGetURLs()
{
dmgURL=$(curl --head "$redirectingURL" | grep "Location:" | awk '{print $2}')
if [[ -z $dmgURL ]]
  then
    writeLog "Unable to retrieve DMG url. Exiting..."
    exit 1
fi

writeLog "DMG URL found. Continuing..."

dmgFile=$(basename "$(echo $dmgURL | awk -F '?' '{print $1}')")
dmgName=$(writeLog "${dmgFile%.*}")
}

downloadInstaller()
{
mkdir -p "$tmpFolder"
writeLog "Downloading $dmgFile..."
/usr/bin/curl -L -s "$redirectingURL" -o "$tmpFolder"/"$dmgFile" --location-trusted
}

installPackage()
{
if [[ -e "$tmpFolder"/"$dmgFile" ]]
  then
    hdiutil mount "$tmpFolder"/"$dmgFile" -nobrowse -quiet
    if [[ -e "$localInstallerVolume"/"$localInstallerPackage" ]]
      then
        writeLog "$localInstallerPackage found. Installing..."
        /usr/sbin/installer -pkg "$localInstallerVolume"/"$localInstallerPackage" -target /
        if [[ $(echo $?) -gt 0  ]]
          then
            writeLog "Installer encountered error. Exiting..."
            hdiutil unmount "$localInstallerVolume"
            rm -f "$tmpFolder"/"$dmgFile"
            exit 1
          else
            writeLog "Successfully installed "$localInstallerPackage". Exiting..."
            hdiutil unmount "$localInstallerVolume"
            rm -f "$tmpFolder"/"$dmgFile"
            exit 0
        fi
    fi
  else
    writeLog "$dmgFile failed to download. Exiting..."
    exit 1
fi
}
## LOGGING
writeLog(){ echo "[$timeStamp] [$softwareTitle] [$consoleUser]: $1" | tee -a $logFile; }
[[ -d $logFolder ]] || mkdir -p -m 775 "$logFolder"
[[ $logSize -ge $maxSize ]] && rm -rf "$logFile"


## BODY

# Tests to confirm app is present, processes are running, and daemons are loaded
if [[ -e "$policyPath" ]]
		then
      if [[ "$(sw_vers -buildVersion)" > "20A" ]]
        then
          localBusinessUUID=$(cat "$policyPath" | xpath -e //business/uuid | sed 's/<uuid>//;s/<\/uuid>//')
        else
          localBusinessUUID=$(cat "$policyPath" | xpath //business/uuid | sed 's/<uuid>//;s/<\/uuid>//')
      fi
			if [[ "$businessUUID" == "$localBusinessUUID" ]]
        then
          writeLog "businessUUID matches. Continuing..."
        else
          writeLog "Locally installed Cisco AMP client not using Cisco created policy, mismatch UUID. Exiting..."
          exit
      fi
fi

# Tests the installed version to the casper deployed version
if [[ -e "/Applications/FireAMP/FireAMP Mac.app" ]]
	then
		shortversionResultInt=$(defaults read "/Applications/FireAMP/FireAMP Mac.app/Contents/Info.plist" CFBundleShortVersionString | tr -d '.')
		if [[ $shortversionResultInt -lt 131 ]]
			then
				writeLog "FireAMP 1.3.0 found. Ignoring for specific version upgrade."
			else
				writeLog "FireAMP 1.3.1+ Found. Will update..."
				(( TestFailed++ ))
		fi
elif [[ -e "$ciscoAMPPath" ]]
		then
				ampVersionTest
				ampRunningTest
		else
				writeLog "Cisco AMP not installed. Installing..."
				(( TestFailed++ ))

fi

# If any tests failed, then download a fresh FA installer
if [[ "$TestFailed" -gt 0 ]]
	then
		writeLog "Reinstall Trigger Totals: $TestFailed"
		checkAndGetURLs
		downloadInstaller
		installPackage
	else
		writeLog "AMP installed and running properly..."
		exit 0
fi

if [[ -e "/Applications/Cisco AMP for Endpoints/Uninstall AMP for Endpoints Connector.pkg" ]]; then
	rm -f "/Applications/Cisco AMP for Endpoints/Uninstall AMP for Endpoints Connector.pkg"
fi
if [[ -e /Library/CiscoIT/tmp/Amp.pkg ]]; then
	rm -f /Library/CiscoIT/tmp/Amp.pkg
fi

if $boolRunARecon; then
	/usr/local/jamf/bin/jamf recon
fi

## FOOTER
exit 0
