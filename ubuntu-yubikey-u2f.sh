#/bin/bash

trap "echo 'interruption not possible'" INT

# check that command exists
check_command() {
    if command -v "$1" &> /dev/null
    then
        return 0   # true
    fi

    return 1   # false
}

# check that an op was successful,
# otherwise print error and exit
check_operation(){
	if [ "0" != "$?" ]; then
		echo "$1"
		exit 1
	fi
}


ENROLL_USER=$(who | grep tty | awk -F ' ' '{print $1}')
if [ "${ENROLL_USER}" == "" ]; then
	ENROLL_USER=$(who | grep seat | awk -F ' ' '{print $1}')
fi

if [ "${ENROLL_USER}" == "" ]; then
    echo "Unable to determine user"
    exit 1
fi

echo "IMPORTANT this script will enable yubikey fido2 for login for user ${ENROLL_USER}"

if [ $(id -u) -ne 0 ]
  then echo Please run this script as root or using sudo!
  exit 1
fi

read -p "Do you want to continue? (y/N) " SURE
if [ "Y" != "$SURE" ] && [ "y" != "$SURE" ]; then
	exit 1
fi

echo "Updating repos"
apt update -qq
apt install -y libpam-u2f
check_operation "Unable to install libpam-u2f"

YUBIKEYDEV=$(fido2-token -L | awk -F ":" '{print $1}')

while [ "${YUBIKEYDEV}" == "" ]; do
    echo "unable to find yubikey, please insert yubikey and please enter"
    read 
    YUBIKEYDEV=$(fido2-token -L | awk -F ":" '{print $1}')
done

echo "found yubikey at ${YUBIKEYDEV}"

fido2-token -S -u "${YUBIKEYDEV}"

echo "You may need to touch your yubikey if it blinks"
pamu2fcfg -P -u "${ENROLL_USER}" > u2f_keys
check_operation "Unable to create u2f file"

fido2-token -D -u "${YUBIKEYDEV}"

chmod 444 u2f_keys
check_operation "Unable to change u2f file permission"

chown root:root u2f_keys
check_operation "Unable to change u2f file owner"

mkdir -p /etc/u2f
mv u2f_keys /etc/u2f
check_operation "Unable to move file"

sudo -u gdm env -u XDG_RUNTIME_DIR -u DISPLAY DCONF_PROFILE=gdm dbus-run-session \
  gsettings set org.gnome.login-screen enable-smartcard-authentication false

pam-auth-update --disable unix sss
check_operation "Unable to remove unix and sss authentication"

sed -i '0,/^$/ s&^$&auth    required pam_u2f.so authfile=/etc/u2f/u2f_keys pinverification=1 userpresence=0&' /etc/pam.d/common-auth
check_operation "Unable to enable libpam_u2f"

