# linuxtools
Various tools written to simplify linux operations

network-scripts/migrate-ifcfg-to-networkmanager - script to perform linux (for rhel/centos/rocky/alma) network migration from ifcfg-based files to networkmanager.
-- created after the built in 'nmcli' utility did such a terrible job of it.  This version of the script tries to retain static IP configuration, bonding config, etc., rather than just slap a dhcp-based file into /etc/NetworkManager/system-connections with the correct interface name. 
