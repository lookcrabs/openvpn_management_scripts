#!/bin/bash

export http_proxy="http://cloud-proxy:3128"
export https_proxy="http://cloud-proxy:3128"

#Consts
OPENVPN_PATH='/etc/openvpn'
BIN_PATH="$OPENVPN_PATH/bin"
EASYRSA_PATH="$OPENVPN_PATH/easy-rsa"
VARS_PATH="$EASYRSA_PATH/vars"

#EASY-RSA Vars

    KEY_SIZE=4096
    COUNTRY="US"
    STATE="IL"
    CITY="Chicago"
    ORG="CDIS" 
    EMAIL='support\@datacommons.io'
    KEY_EXPIRE=365


#OpenVPN
PROTO=tcp



print_help() {
    echo "Welcome."
    echo "USAGE 1 : $0 " 
    echo "        : This will run the script and prompt for FQDN and a OU Name"
    echo "USAGE 2 : export FQDN=foo.bar.tld; export cloud="XDC"; export server_pem='/root/server.pem'; $0"
    echo "        : This will not prompt for any input"
    echo ""
    echo "This install script assumes you have a working email or email relay configured."
    echo ""
    echo "This scripts creates a lighttpd webserver for QRCodes.  You will need to copy the key+cert as a pem to /etc/lighttpd/certs/server.pem"
}

prep_env() {

    if [ ! $FQDN ]
    then
        echo "What is the FQDN for this VPN endpoint? "
        read FQDN
    fi
    if [ ! $cloud ]
    then
        echo "What is the Cloud/Env/OU/Abrreviation you want to use? "
        read cloud
    fi
    if [ ! $EMAIL ]
    then
        echo "What email address do you want to use? "
        read EMAIL
    fi
    if [ $server_pem ]
    then
        SERVER_PEM=$server_pem
    else
        SERVER_PEM=""
    fi
    if [ ! $VPN_SUBNET ]
    then
        VPN_SUBNET="192.168.64.0/18"
        VPN_SUBNET_BASE="${VPN_SUBNET%/*}"
        VPN_SUBNET_MASK=$( sipcalc $VPN_SUBNET | perl -ne 'm|Network mask\s+-\s+(\S+)| && print "$1"' )
        VPN_SUBNET_MASK_BITS=$( sipcalc $VPN_SUBNET | perl -ne 'm|Network mask \(bits\)\s+-\s+(\S+)| && print "$1"' )
    fi
    if [ ! $VM_SUBNET ]
    then
        VM_SUBNET="172.16.0.0/12"
        VM_SUBNET_BASE="${VM_SUBNET%/*}"
        VM_SUBNET_MASK=$( sipcalc $VM_SUBNET | perl -ne 'm|Network mask\s+-\s+(\S+)| && print "$1"' )
        VM_SUBNET_MASK_BITS=$( sipcalc $VM_SUBNET | perl -ne 'm|Network mask \(bits\)\s+-\s+(\S+)| && print "$1"' )
    fi
        


    apt-get update
    apt-get -y purge cloud-init
    echo "$FQDN" > /etc/hostname
    hostname $(cat /etc/hostname)

}

install_pkgs() {
    apt-get update; 
    apt-get -y install openvpn bridge-utils libssl-dev openssl zlib1g-dev easy-rsa haveged zip mutt sipcalc
    useradd  --shell /bin/nologin --system openvpn
}

install_custom_scripts() {

    cd $OPENVPN_PATH

    #pull our openvpn scripts
    git clone -b feat/install_script  git@github.com:LabAdvComp/openvpn_management_scripts.git
    ln -s openvpn_management_scripts bin
    cd  $BIN_PATH
    virtualenv .venv
    #This is needed or else you get : .venv/bin/activate: line 57: PS1: unbound variable
    set +u
    ( source .venv/bin/activate; pip install pyotp pyqrcode )
    set -u

}
install_easyrsa() {
    #copy EASYRSA in place
    cp -pr /usr/share/easy-rsa $EASYRSA_PATH
    cp "$OPENVPN_PATH/bin/templates/vars.template" $VARS_PATH

    EASY_RSA_DIR="$EASYRSA_PATH"
    EXTHOST="$FQDN"
    OU="$cloud"
    KEY_NAME="$OU-OpenVPN"

    perl -p -i -e "s|#EASY_RSA_DIR#|$EASY_RSA_DIR|" $VARS_PATH
    perl -p -i -e "s|#EXTHOST#|$EXTHOST|" $VARS_PATH
    perl -p -i -e "s|#KEY_SIZE#|$KEY_SIZE|" $VARS_PATH
    perl -p -i -e "s|#COUNTRY#|$COUNTRY|" $VARS_PATH
    perl -p -i -e "s|#STATE#|$STATE|" $VARS_PATH
    perl -p -i -e "s|#CITY#|$CITY|" $VARS_PATH
    perl -p -i -e "s|#ORG#|$ORG|" $VARS_PATH
    perl -p -i -e "s|#EMAIL#|$EMAIL|" $VARS_PATH
    perl -p -i -e "s|#OU#|$OU|" $VARS_PATH
    perl -p -i -e "s|#KEY_NAME#|$KEY_NAME|" $VARS_PATH
    perl -p -i -e "s|#KEY_EXPIRE#|$KEY_EXPIRE|" $VARS_PATH


    sed -i 's/^subjectAltName/#subjectAltName/' $EASYRSA_PATH/openssl-*.cnf

}

install_settings() {

    SETTINGS_PATH="$BIN_PATH/settings.sh"
    cp "$OPENVPN_PATH/bin/templates/settings.sh.template" "$SETTINGS_PATH"
    perl -p -i -e "s|#FQDN#|$FQDN|" $SETTINGS_PATH
    perl -p -i -e "s|#EMAIL#|$EMAIL|" $SETTINGS_PATH
    perl -p -i -e "s|#CLOUD_NAME#|${cloud}-vpn|" $SETTINGS_PATH

}

build_PKI() {

    cd $EASYRSA_PATH
    source $VARS_PATH ## execute your new vars file
    echo "This is long"
    ./clean-all  ## Setup the easy-rsa directory (Deletes all keys)
    ./build-dh  ## takes a while consider backgrounding
    ./pkitool --initca ## creates ca cert and key
    ./pkitool --server $EXTHOST ## creates a server cert and key
    openvpn --genkey --secret ta.key
    mv ta.key $EASYRSA_PATH/keys/ta.key
i
    #This will error but thats fine, the crl.pem was created (without it openvpn server crashes) 
    set +e
    revoke-full client &>/dev/null || true
    set -e

}

configure_ovpn() {

    OVPNCONF_PATH="/etc/openvpn/openvpn.conf"
    cp "$OPENVPN_PATH/bin/templates/openvpn.conf.template" "$OVPNCONF_PATH"

    perl -p -i -e "s|#FQDN#|$FQDN|" $OVPNCONF_PATH

    #perl -p -i -e "s|#VPN_SUBNET#|$VPN_SUBNET|" $OVPNCONF_PATH
    perl -p -i -e "s|#VPN_SUBNET_BASE#|$VPN_SUBNET_BASE|" $OVPNCONF_PATH
    perl -p -i -e "s|#VPN_SUBNET_MASK#|$VPN_SUBNET_MASK|" $OVPNCONF_PATH
    #perl -p -i -e "s|#VPN_SUBNET_MASK_BITS#|$VPN_SUBNET_MASK_BITS|" $OVPNCONF_PATH

    #perl -p -i -e "s|#VM_SUBNET#|$VPN_SUBNET|" $OVPNCONF_PATH
    perl -p -i -e "s|#VM_SUBNET_BASE#|$VPN_SUBNET_BASE|" $OVPNCONF_PATH
    perl -p -i -e "s|#VM_SUBNET_MASK#|$VPN_SUBNET_MASK|" $OVPNCONF_PATH
    #perl -p -i -e "s|#VM_SUBNET_MASK_BITS#|$VPN_SUBNET_MASK_BITS|" $OVPNCONF_PATH

    perl -p -i -e "s|#PROTO#|$PROTO|" $OVPNCONF_PATH

    systemctl restart openvpn

}

tweak_network() {

    NetTweaks_PATH="$OPENVPN_PATH/bin/network_tweaks.sh"
    cp "$OPENVPN_PATH/bin/templates/network_tweaks.sh.template" "$NetTweaks_PATH"
    perl -p -i -e "s|#VPN_SUBNET#|$VPN_SUBNET|" $NetTweaks_PATH
    #perl -p -i -e "s|#VPN_SUBNET_BASE#|$VPN_SUBNET_BASE|" $NetTweaks_PATH
    #perl -p -i -e "s|#VPN_SUBMASK#|$VPN_SUBNET_MASK|" $NetTweaks_PATH
    #perl -p -i -e "s|#VPN_SUBNET_MASK_BITS#|$VPN_SUBNET_MASK_BITS|" $NetTweaks_PATH

    perl -p -i -e "s|#VM_SUBNET#|$VPN_SUBNET|" $NetTweaks_PATH
    #perl -p -i -e "s|#VM_SUBNET_BASE#|$VPN_SUBNET_BASE|" $NetTweaks_PATH
    #perl -p -i -e "s|#VM_SUBMASK#|$VPN_SUBNET_MASK|" $NetTweaks_PATH
    #perl -p -i -e "s|#VM_SUBNET_MASK_BITS#|$VPN_SUBNET_MASK_BITS|" $NetTweaks_PATH

    perl -p -i -e "s|#PROTO#|$PROTO|" $NetTweaks_PATH

    chmod +x $NetTweaks_PATH
    $NetTweaks_PATH
    perl -p -i.bak -e 's|exit 0|/etc/openvpn/bin/network_tweaks.sh\nexit 0|' /etc/rc.local
    

}

install_webserver() {
    #Webserver used for QRCodes
    apt-get install -y lighttpd
    cp "$OPENVPN_PATH/bin/templates/lighttpd.conf.template"  /etc/lighttpd/lighttpd.conf

    mkdir -p --mode=750 /var/www/qrcode
    chown openvpn:www-data /var/www/qrcode
    
    if [ -f $SERVER_PEM ]
    then
        mkdir --mode=700 /etc/lighttpd/certs
        cp $SERVER_PEM /etc/lighttpd/certs/server.pem
        service lighttpd restart
    fi

}


install_cron() {
    cp "$OPENVPN_PATH/bin/templates/cron.template"  /etc/cron.d/openvpn
}

    

misc() {
    cd $OPENVPN_PATH
    mkdir easy-rsa/keys/ovpn_files
    mkdir easy-rsa/keys/user_certs
    ln -s easy-rsa/keys/ovpn_files
    mkdir clients.d/
    mkdir clients.d/tmp/
    mkdir easy-rsa/keys/ovpn_files_seperated/
    mkdir easy-rsa/keys/ovpn_files_systemd/
    mkdir easy-rsa/keys/ovpn_files_resolvconf/
    touch user_passwd.csv
    chown openvpn:openvpn /etc/openvpn -R
}

    print_help
    prep_env
set -e
set -u
    install_pkgs
    install_custom_scripts
    install_easyrsa
    install_settings
    build_PKI
    configure_ovpn
    tweak_network
    install_webserver
    install_cron
    misc


