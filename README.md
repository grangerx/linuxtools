# linuxtools
Various tools written to simplify linux operations

network-scripts/migrate-ifcfg-to-networkmanager - Migrates ifcfg files to network-manager (nmconnection) files

This is a script to perform rhel/centos/rocky/alma linux network migration from ifcfg-based files to networkmanager nmconnection files.
This script was created due to the built-in 'nmcli' utility doing such a terrible job of converting the files.
This script retains the existing static IP configuration, bonding config, etc. of the network cards, rather than just slap a dhcp-based file into /etc/NetworkManager/system-connections with the same interface name. 
