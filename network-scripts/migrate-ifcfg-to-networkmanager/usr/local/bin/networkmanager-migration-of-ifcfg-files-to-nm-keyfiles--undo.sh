#!/bin/sh

scriptfile="$( basename "$(readlink -f "$0")" )"
echo "scriptfile: ${scriptfile}"
scriptdir="$( dirname "$(readlink -f "$0")" )"
echo "scriptdir: ${scriptdir}"
#scriptcfgfile="${scriptdir}/${scriptfile}.cfg"
filesdir="${scriptdir}/../../../example/"
echo "filesdir: ${filesdir}"


echo "copy the ifcfg back and delete the nmconnection file:"
cp ${filesdir}/ifcfg-* /etc/sysconfig/network-scripts/ && rm -f /etc/NetworkManager/system-connections/*.nmconnection
