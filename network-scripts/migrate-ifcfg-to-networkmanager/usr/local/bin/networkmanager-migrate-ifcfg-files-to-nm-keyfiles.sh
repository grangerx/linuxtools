#!/bin/bash
#file : networkmanager-migrate-ifcfg-files-to-nm-keyfiles.sh
#author: justin@grangerx.com
#version: 2025.09.12.b

VERBOSE="FALSE"
IFCFGPATHPREFIX="/etc/sysconfig/network-scripts/"
NMCONNPATHPREFIX="/etc/NetworkManager/system-connections"
IFCFGFNAMEPREFIX="ifcfg-"


#check for the running NetworkManager.service, exit if it is not running
NMSVCRUNNING=$( systemctl show -p SubState --value NetworkManager.service )
if [ "x${NMSVCRUNNING}" != "xrunning" ]; then
       echo "ERROR: The NetworkManager service must be running to use this script."
       exit 1
fi

#have to include local OPTIND otherwise this function will fail the second time it is called
#(OPTIND isn't reset each time if it is global)
while getopts 'vi:' arg ; do
	case ${arg} in
		v) VERBOSE="TRUE" ; echo "VERBOSE" ;;
		i) INTERFACE=${OPTARG} ;;
		*) echo "Error: ${arg} is not a valid parameter. Exiting." ; exit 1 ;;
	esac
done
shift $((OPTIND-1))

#--------------
#-v- function vecho() - only echo if the verbose flag was passed on the cmdline
#--------------
function vecho() { if [ "${VERBOSE}" == "TRUE" ]; then echo "$@" ; fi }
#--------------
#-^- 
#--------------


#--------------
#-v- function writelinetofile() - write a line to a destination file, appending to file
#--------------
function writelinetofile() {
	file="${1}"
	shift
	line="$@"
	vecho "${line}"
	echo "${line}" >> "${file}"
}
#--------------
#-^- 
#--------------

#--------------
#-v- netmasktoprefix() - given a netmask, echoes the prefix which matches that netmask
#--------------
#function based on: https://stackoverflow.com/questions/50413579/bash-convert-netmask-in-cidr-notation
#function returns prefix for given netmask in arg1
#example: 255.255.255.0 -> 24
#example: 255.255.255.192 -> 26
function netmasktoprefix() {
	local nm="${1}"
	bits=0
	for octet in $(echo ${nm} | sed 's/\./ /g'); do 
		binbits=$(echo "obase=2; ibase=10; ${octet}"| bc | sed 's/0//g') 
		let bits+=${#binbits}
	done
	echo "${bits}"
}
export -f netmasktoprefix
#--------------
#-^-
#--------------

#--------------
#-v- function setproperty() - given a property section, key, and value, sets the props array[section.key]=value, optionally warning if already set.
#--------------
function setproperty() {
	local OPTIND
	local sk
	while getopts 'cs:k:v:w' arg ; do
		case ${arg} in
			s) local section="${OPTARG}" ;;
			k) local key="${OPTARG}" ;;
			v) local value="${OPTARG}" ;;
			c) local createbutdonotupdate="yes" ;;
			w) local warnonalreadyset="yes" ;;
			*) echo "Error: ${arg} is not a valid parameter. Exiting." ; exit 1 ;;
		esac
	done
	shift $((OPTIND-1))

	#if a section was given, create a key like section.key, otherwise just use key:
	if [ -n "${section}" ]; then
		sk="${section}.${key}"
	else
		sk="${key}"
	fi

	#warn if the key was already set and warn was requested (defaults to 'no')
	if [ "${props[${sk}]+isset}" ] ; then
		if [ "${warnonalreadyset}" == 'yes' ] ; then
			echo "[WARNING] property ${sk} was already set before being set to [${value}]."
		elif [ "${createbutdonotupdate}" == 'yes' ] ; then
			return
		fi
	fi
	#set the props[key] value
	props[${sk}]="${value}"
}
#--------------
#-^-
#--------------

#--------------
#-v- function coalescemultivaluedprops() - after the props array is filled, coalesces 'ipaddr*' and 'dns*' values into single values
#--------------
function coalescemultivaluedprops() {
	#coalesce ip addresses / prefixes:
	ipbuf=""
	dnsbuf=""
	for key in "${!props[@]}"; do
		#handle ipaddr* keys
		if [[ "$key" =~ "ipaddr"* ]]; then
			keynum="${key#ipv4.ipaddr}"
			prefkey="ipv4.prefix${keynum}"
			if [ ! -n "${props[${prefkey}]}" ] ; then 
				echo "[WARNING]: An IP address exists without a matching prefix/subnet-mask entry."
			else
				ipbuf+=";${props['ipv4.ipaddr'${keynum}]}/${props['ipv4.prefix'${keynum}]}"
				unset props[${key}] ; unset props[${prefkey}]
			fi
	       	fi 
		#also handle dns* keys
		if [[ "$key" =~ "ipv4.dns"[0-9]$ ]]; then
			keynum="${key#ipv4.dns}"
			prefkey="ipv4.dns${keynum}"
			dnsbuf+=";${props['ipv4.dns'${keynum}]}"
			unset props[${key}] 
	       	fi 
	done
	#add the ipbuf , removing any semicolons at the start of the string:
	if [ -n "${ipbuf}" ]; then
		props['ipv4.address']="${ipbuf#;}"
	else
		#if no static IPs were given, but the ipv4.method=manual parameter exists,
		#(as can happen with bond secondaries)
		#then squelch the BOOTPROTO=none/static aka ipv4.method=manual	
		if [ "${props['ipv4.method']}" == "manual" ]; then
			unset props['ipv4.method']
		fi
	fi

	#add the dnsbuf , removing any semicolons at the start of the string:
	if [ -n "${dnsbuf}" ]; then
		props['ipv4.dns']="${dnsbuf#;}"
	fi
}
#--------------
#-^-
#--------------

#--------------
#-v- function generatenmconnectionfile() - takes an array of properties extracted from ifcfg files,
#	and generates an nmconnection file from the array.
#--------------
function generatenmconnectionfile() {
	declare -a props_keys_sorted
	#get the keys as their own array, sorted, which will put them in section order
	vecho =v===
	while IFS= read -rd '' key; do
		props_keys_sorted+=("${key}")
	done < <( printf '%s\0' "${!props[@]}" | sort -z )

	#truncate the existing file:
	echo > ${newconnfilepath}

	#convert the key arrays to ini file (keyfile) sections
	thissection=''
	prefix=''
	for x in "${props_keys_sorted[@]}"; do
		section="$( echo "${x}" | awk -F. ' { print $1 } ')"
		property="$( echo "${x}" | awk -F. ' { print $2 } ')"
		if [ "${thissection}" != "${section}" ] ; then
			#if [ -n "${thissection}" ]; then echo >> ${newconnfilepath} ; fi
			if [ -n "${thissection}" ]; then writelinetofile "${newconnfilepath}" '' ; fi
			thissection="${section}"
			if [ "${thissection}" == "UNHANDLED" ]; then prefix='#'; else prefix='' ; fi
			#echo "${prefix}[${thissection}]" >> ${newconnfilepath}
			writelinetofile "${newconnfilepath}" "${prefix}[${thissection}]"
			fi
		#echo "${prefix}${property}=${props[${x}]}" >> ${newconnfilepath}
		writelinetofile	"${newconnfilepath}" "${prefix}${property}=${props[${x}]}"
	done
	vecho "move the old ifcfg file:"
	vecho "from: ${ifcfgfilepath}"
	vecho "  to: ${newifcfgfilepath}"
	mv "${ifcfgfilepath}" "${newifcfgfilepath}"
	if [ "$?" -ne "0" ]; then echo "[WARNING]: Could not move the old ifcfg file.  Maybe something (chattr) is preventing that?"; fi
	vecho "Fix permisssions on new filepath:"
	chmod 600 "${newconnfilepath}"
	vecho =^===
}
#--------------
#-^-
#--------------

#--------------
#-v- function processafile() - given an path to an ifcfg file,
#	replaces it with a matching NM keyfile-formatted .nmconnection file
#--------------
function processafile() {
	ifcfgfilepath="${1}"
	ifcfgfilename="$(basename ${ifcfgfilepath} )"
	interfacename="${ifcfgfilename#ifcfg-}"

	newifcfgfilename="MIGRATED.${IFCFGFNAMEPREFIX}${interfacename}"
	newifcfgfilepath="${IFCFGPATHPREFIX}/${newifcfgfilename}"
	newconnfilename="${interfacename}.nmconnection"
	newconnfilepath="/etc/NetworkManager/system-connections/${newconnfilename}"
	bkupconnfilename="${interfacename}.nmconnection.BACKUP"
	bkupconnfilepath="/etc/NetworkManager/system-connections/${bkupconnfilename}"
	vecho "#processing ${x} :"
	vecho "#ifcfgfilename: ${ifcfgfilename}"
	vecho "#interfacename: ${interfacename}"
	vecho "#newconnfilename: ${newconnfilename}"
	vecho "#newconnfilepath: ${newconnfilepath}"
	vecho "#bkupconnfilename: ${bkupconnfilename}"
	vecho "#bkupconnfilepath: ${bkupconnfilepath}"


	#get current epoch timestamp:
	GEN_TIMESTAMP="$( date +%s )"
	#get a uuid to use in case the file doesn't include them
	GEN_UUID="$( uuidgen )"

	if [ ! -f "${ifcfgfilepath}" ]; then echo "ERROR: File ${ifcfgfilepath} does not exist or is inaccessible. Exiting." ; exit 1 ; fi
	if [ "${ifcfgfilename}" == "ifcfg-lo" ]; then echo "NOTE: File ${ifcfgfilepath} will not be processed since it refers to interface 'lo'" ; return  ; fi

	#first thing, make a backup of any existing nmconnection file
	vecho "Renaming any existing nmconnection file:"
	vecho "from: ${newconnfilepath}"
	vecho "  to: ${bkupconnfilepath}"
	mv ${newconnfilepath} ${bkupconnfilepath}

	declare -A ARR
	declare -A props
	#assume ipv6 is disabled:
	###props['ipv6.method']='disabled'

	#pull each line in the ifcfg file into a k-v array:
	while read -r LINE
	do
		key="$( echo ${LINE} | cut -d= -f1 )"
		value="$(echo ${LINE#${key}=} )"
		ARR["${key}"]="${value}"
	done < <( cat "${ifcfgfilepath}" | sed -e "s/\#.*$//;/^$/d" )

	#loop through each k-v array entry:
	for akey in "${!ARR[@]}"; do
		#get value:
		avalue="${ARR[${akey}]}"

		#strip quotes from avalue:
		avalue="${avalue#\"}" ; avalue="${avalue%\"}"

		#Note: Several properties are lowercased by using the bash variable syntax, with:  ,,
		#get lowercase value (bash 4.0)
		avaluelc="${avalue,,}"

		#get lowercase akey (bash 4.0)
		akeylc="${akey,,}"

		#process eacy VARIABLE in the ifcfg file, converting it to a property:
		case "${akey}" in
			TYPE) setproperty -s 'connection' -k "${akeylc}" -v "${avaluelc}" ;;
			ONBOOT) setproperty -s 'connection' -k 'autoconnect' -v "$( echo "${avaluelc}" | sed -e "s/yes/true/;s/no/false/" )" ;;
			NAME) setproperty -s 'connection' -k 'id' -v  "${avalue}" ;;
			HWADDR) setproperty -s '802-3-ethernet' -k 'mac-address' -v "${avalue}" ;;
			DEVICE) setproperty -s 'connection' -k 'interface-name' -v "${avalue}" ;;
			UUID) setproperty -s 'connection' -k 'uuid' -v "${avalue}" ;;
			DOMAIN) setproperty -s 'ipv4' -k 'dns-search' -v "${avalue// /,}" ;;
			PEERDNS) setproperty -s 'ipv4' -k 'ignore-auto-dns' -v "$( echo "${avaluelc}" | sed -e "s/yes/true/;s/no/false/" )" ;;
			GATEWAY) setproperty -s 'ipv4' -k 'gateway' -v "${avalue}" ;;
			#DEFROUTE becomes 'never-default', which has opposite boolean meaning:
			DEFROUTE) setproperty -s 'ipv4' -k 'never-default' -v "$( echo "${avaluelc}" | sed -e "s/yes/false/;s/no/true/" )" ;;
			#IPV4_FAILURE_FATAL becomes 'ipv4.may-fail', which has opposite boolean meaning:
			IPV4_FAILURE_FATAL) setproperty -s 'ipv4' -k 'may-fail' -v "$( echo "${avaluelc}" | sed -e "s/yes/false/;s/no/true/" )" ;;
			BOOTPROTO) setproperty -s 'ipv4' -k 'method' -v "$( echo "${avalue}" | sed -e "s/dhcp/auto/;s/none/manual/;s/static/manual/" )" ;;
			#ipv6 stuff:
			#IPV6_DEFROUTE becomes 'never-default', which has opposite boolean meaning:
			IPV6_DEFROUTE) setproperty -s 'ipv6' -k 'never-default' -v "$( echo "${avaluelc}" | sed -e "s/yes/false/;s/no/true/" )" ;;
			#IPV6_DISABLED will be converted into 'ipv6.method':
			IPV6_DISABLED) [ "${avaluelc}" == 'yes' ] &&  setproperty -s 'ipv6' -k 'method' -v 'disabled' ;;
			IPV6_AUTOCONF) setproperty -s 'ipv6' -k 'method' -v "$( echo "${avaluelc}" | sed -e "s/yes/auto/;s/no/manual/" )" ;;
			IPV6_ADDR_GEN_MODE) setproperty -s 'ipv6' -k 'addr-gen-mode' -v "$( echo "${avaluelc}" )" ;;
			#IPV6_FAILURE_FATAL becomes 'ipv6.may-fail', which has opposite boolean meaning:
			IPV6_FAILURE_FATAL) setproperty -s 'ipv6' -k 'may-fail' -v "$( echo "${avaluelc}" | sed -e "s/yes/false/;s/no/true/" )" ;;
			IPV6INIT) [ "${avaluelc}" == 'no' ] &&  setproperty -s 'ipv6' -k 'method' -v 'disabled' ;;
			#firewalld zone can be specified:
			ZONE) setproperty -s 'connection' -k "${akeylc}" -v "${avalue}" ;;
			#bond stuff:
			BONDING_OPTS) setproperty -s 'bond' -k 'options' -v "$( echo "${avalue}" | tr ' ' ',' )" ;;
			SLAVE) setproperty -s 'connection' -k 'slave-type' -v "$( echo "${avalue}" | sed -e "s/yes/bond/" )" ;;
			MASTER) setproperty -s 'connection' -k "${akeylc}" -v "${avalue}" ;;
			# squelch the 'BONDING_MASTER' parameter. 
			BONDING_MASTER) ;;
			#ips/prefixes/netmasks/dns (there can be multiple of each):
			IPADDR*) setproperty -s 'ipv4' -k "${akeylc}" -v "${avalue}" ;;
			PREFIX*) setproperty -s 'ipv4' -k "${akeylc}" -v "${avalue}" ;;
			NETMASK*) setproperty -s 'ipv4' -k 'prefix'${akeylc#netmask} -v "$( netmasktoprefix "${avalue}" )" ;;
			DNS*) setproperty -s 'ipv4' -k "${akeylc}" -v "${avalue}" ;;
			#proxy stuff:
			BROWSER_ONLY) setproperty -s 'proxy' -k "${akeylc}" -v "${avalue}" ;;
			PROXY_METHOD) setproperty -s 'proxy' -k 'method' -v "${avalue}" ;;
			PAC_SCRIPT) setproperty -s 'proxy' -k "${akeylc}" -v "${avalue}" ;;
			PAC_URL) setproperty -s 'proxy' -k "${akeylc}" -v "${avalue}" ;;
			#squelch the NM_CONTROLLED parameter, since, well, a keyfile is always nm-controlled.
			NM_CONTROLLED) ;;
			#anything unhandled goes here:
			*) setproperty -s 'UNHANDLED' -k "${akeylc}" -v "${avalue}" ; UNHANDLEDPROPFLAG=TRUE ;;
		esac
	done

	#set some needed default properties, in case the ifcfg did not have them:
	setproperty -s 'connection' -k 'id' -v  "${interfacename}"
	setproperty -s 'connection' -k 'timestamp' -v "${GEN_TIMESTAMP}" -c
	setproperty -s 'connection' -k 'type' -v 'ethernet' -c
	setproperty -s 'connection' -k 'uuid' -v "${GEN_UUID}" -c


	#coalesce the multi-valued params:
	coalescemultivaluedprops

	#generate the nmconnection file:
	generatenmconnectionfile
}
#--------------
#-^-
#--------------



#if an interace (-i <INTERFACE_NAME> ) was given on the cmdline, just work on that ifcfg file:
if [ -n "${INTERFACE}" ] ; then
	processafile "${IFCFGPATHPREFIX}/${IFCFGFNAMEPREFIX}${INTERFACE}"
#else, process every file matching: /etc/sysconfig/network-scripts/ifcfg-* 
else
	for x in ${IFCFGPATHPREFIX}/${IFCFGFNAMEPREFIX}* ; do
		vecho "#=v================================"
		processafile "${x}"
		vecho "#=^================================"
	done
fi
#if any ifcfg variables were not understood/processed by this script, warn the user.
if [ -n "${UNHANDLEDPROPFLAG}" ] ; then
	echo "#----------------------------------"
	echo "[WARNING]: Parameters were detected during conversion that did not have known conversions."
	echo "Note: For any parameters that this script did not know how to handle,"
	echo "those parameters were placed in a (commented-out) #[UNHANDLED] section of the nmconnection file."
	echo "#----------------------------------"
fi
echo "#----------------------------------"
echo "To view the current file being used for a connection, use:"
echo "#nmcli -f name,filename connection"
echo "#----------------------------------"
echo "#----------------------------------"
echo "To enact the changed files, use:"
echo "#nmcli connection reload"
echo "(Note: if there are any syntax errors, the 'reload' command  WILL DROP THE NETWORK CARD OFF THE NETWORK.)"
echo "#----------------------------------"
echo "#----------------------------------"
echo "Conversion completed. Please validate the files in ${NMCONNPATHPREFIX} ."
echo "#----------------------------------"
#EOF

