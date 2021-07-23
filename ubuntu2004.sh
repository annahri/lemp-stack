#/usr/bin/env bash
set -o errexit
set -o pipefail

cmd=$(basename $0)
err_count=0
msg() {
    if [[ -n "$2" && "$2" == "-n" ]]; then
        echo -en "$1" | tee -a lemp_install.log
    else
        echo -e "$1" | tee -a lemp_install.log
    fi
}
ok() { msg "  $(tput setaf 3)${@}$(tput sgr0)"; }
err() {
    msg "  $(tput setaf 1)${@}$(tput sgr0)" >&2
    ((err_count++))
}
err_exit() { err "$@ Exiting..."; exit 1; }

test $EUID -ne 0 &&
    err_exit "Please run this as root."

grep -qi ubuntu /etc/os-release ||
    err_exit "OS not Ubuntu."

#---[ Env Variables ]-----------------------------------------------#
PHP_VER=7.2

#---[ Variables ]---------------------------------------------------#
packages=()
php_mods_invalid=()

#---[ Argument Parsing ]--------------------------------------------#
while [ $# -gt 0 ]; do case "$1" in
    --no-mariadb-secure) INSECURE_MARIADB=true;;
    --php-modules=*)     PHP_MOD="${1#*=}" ;;
    --php-no-socket)   PHP_NO_SOCKET=true ;;
    --php[0-9]*)      PHP_VER="${1#--php}" ;;
    --debug) __funct="$2"; shift;;
    --debug=*)  __funct="${1#*=}";;
    *) err "No such option. Ignored."
esac; shift; done

#---[ Sanitize Input ]----------------------------------------------#
if [[ ! $PHP_VER =~ [0-9]\.[0-9] ]]; then
    err_exit "Invalid php version."
fi

if [[ "$PHP_VER" == "7.2" ]]; then PHP_VER="7.4"; fi

#---[ Functions ]---------------------------------------------------#
query() { $(command -v mariadb) -e "$@"; }
genpasswd() {  tr -dc A-Za-z0-9 < /dev/urandom | head -c 12 | xargs || test $? -eq 141; }
nginx_startstop() { nginx -t > /dev/null 2>&1 && nginx -s reload > /dev/null 2>&1; }
build_pkglist() {
    msg "Checking packages..."
    # Construct main php packages
    php_pkgs=(`eval echo "php$PHP_VER{,-fpm,-common,-cli,-mysql}"`)
    # Php modules
    IFS=',' read -r -a php_mods <<< "$PHP_MOD"
    # Verify if php module exists in repo to avoid install failure
    for pkg in "${php_mods[@]}"; do
        php_mod="php${PHP_VER}-${pkg}"
        msg "Checking if $php_mod exists in repo... " -n
        pkg_exist=$(apt-cache search --names-only "$php_mod")
        # If the module doesn't exist on repo, remove from array.
        if [[ -z "$pkg_exist" ]]; then
            msg "Doesn't exist. Added to invalid mods."
            php_mods=( "${php_mods[@]/$pkg}" )
            php_mods_invalid+=("$php_mod")
        else
            msg "Exists!"
            php_pkgs+=("$php_mod")
        fi
    done

    packages+=( nginx mariadb-server mariadb-common "${php_pkgs[@]}" )
}

configure_fw() {
    # Configure firewall
    if command -v ufw > /dev/null 2>&1; then
        if ufw status | grep -q 'Status: active'; then
            ufw allow proto tcp from any to any port 80,443 > /dev/null 2>&1
            ok "Ufw enabled, port 80, 443 allowed"
        else
            msg "Ufw is disabled.."
        fi
    else
        msg "No firewall detected. Either you are not using one or you need to configure it manually later..."
        msg "Please enable port: 80 (HTTP) and 443 (HTTPS)"
    fi
}

verify_services() {
    check_status() {
        local srv_status=$(systemctl status "$1" 2> /dev/null | awk '/Active:/ {print $2}')
        if [[ $srv_status != active ]]; then
            return 1
        fi
        return 0
    }
    # Verify services
    for service in nginx mariadb php${PHP_VER}-fpm; do
        if ! check_status "$service"; then
            msg "Service $service is not started yet. Starting..."
            systemctl enable "$service" --now > /dev/null 2>&1
            check_status "$service" || err "Please investigate $service service manually."
        fi
    done
}

secure_mariadb() {
    temp_passwd=$(genpasswd)
    # Change root password
    msg "Securing mariadb installation..."
    auth_method=$(query "SELECT plugin FROM mysql.user WHERE User='root'")
    if ! grep -qi 'socket' <<< "$auth_method"; then
        msg "Changing mariadb root password to: $temp_passwd"
        query "UPDATE mysql.user SET Password=PASSWORD('$temp_passwd') WHERE User='root'"
        if [[ $? -eq 0 ]]; then
            # Flush privileges
            query "FLUSH PRIVILEGES"
            if [[ $? -eq 1 ]]; then
                err "Failed!"
                msg "Please secure mariadb installation manually."
            fi
        else
            err "Failed!"
            msg "Please secure mariadb installation manually."
        fi
    fi

    msg "Deleting anonymous users."
    query "DELETE FROM mysql.user WHERE User=''"
    if [[ $? -eq 1 ]]; then
        err "Failed to delete anonymous users.!"
        msg "Please secure mariadb installation manually."
    fi

    msg "Restricting root login to allow local only"
    query "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    if [ $? -eq 1 ]; then
        err "Failed to configure root local only!"
        msg "Please secure mariadb installation manually."
    fi

    query "DROP DATABASE IF EXISTS test" && query "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
    query "FLUSH PRIVILEGES"

    ok "Done securing mariadb installation."
}

check_listening_ports() {
    ports=( 80 3306 )
    msg "Checking ports..."
    for port in "${ports[@]}"; do
        if ss -tulpn | grep -q ":$port"; then
            ok "Port $port is listening."
        else
            err "Port $port is not listening."
        fi
    done

    # Checking port 9000
    if ! ss -tulpn | grep -q ':9000'; then
        msg "PHP FPM is probably using UNIX Socket. Checking... " -n
        if test -S /run/php/php${PHP_VER}-fpm.sock; then
            ok "It is."
        else
            err "Check configuration manually."
        fi
    fi
}

configure_phpfpm() {
    msg "Configuring php-fpm... " -n
    cat <<EOF > /etc/nginx/conf.d/php-fpm.conf
upstream php-fpm {
    server unix:/run/php/php${PHP_VER}-fpm.sock;
}
EOF
    if nginx -t > /dev/null 2>&1; then
        msg "done"
    else
        msg "failed"
    fi
}

test_http() {
    msg "Testing nginx webserver..."
    msg "From localhost..."
    if curl -s localhost | grep -qi 'welcome to nginx'; then
        ok "Localhost connection successful!"
    fi

    msg "From public IP..."
    public_ip=$(curl -s http://icanhazip.com)
    if curl -s "$public_ip" | grep -qi 'welcome to nginx'; then
        ok "Test via public IP successful."
    else
        msg "Timed out. It might be blocked from your firewall."
    fi
}

test_php_config() {
    cat <<EOF > /etc/nginx/conf.d/test-php.conf
server {
    listen 80;
    index index.php;
    location ~ \.php$ {
        fastcgi_pass php-fpm;
        fastcgi_index index.php;
        include fastcgi.conf;
    }
}
EOF
    nginx_startstop
}

test_php() {
    msg "Testing PHP-FPM..."
    test_php_config
    cat <<EOF > /var/www/html/test-php.php
<?php
    echo 'PHP-FPM is working';
?>
EOF
    chown www-data.www-data /var/www/html/test-php.php
    if curl -s localhost/test-php.php | grep -q 'PHP-FPM is working'; then
        ok "Nginx + PHP-FPM is working"
    else
        err "Nginx + PHP-FPM is not working."
    fi

    rm -f /var/www/html/test-php.php /etc/nginx/conf.d/test-php.conf
    nginx_startstop
}

test_mysql_php() {
    msg "Testing MariaDB + PHP connectivity..."
    # Create temporary database and database user
    test_pw=$(genpasswd)
    mariadb <<EOF
CREATE DATABASE IF NOT EXISTS tesdb;
CREATE USER dbuser@localhost IDENTIFIED BY '$test_pw';
GRANT ALL PRIVILEGES ON tesdb.* TO dbuser@localhost;
FLUSH PRIVILEGES;
EOF
    test_php_config
    cat <<EOF > /var/www/html/test-db.php
<?php
    \$con = mysqli_connect("localhost","dbuser","$test_pw","tesdb");

    if (mysqli_connect_errno()) {
        echo "Failed to connect to MySQL: " . mysqli_connect_error();
        exit();
    } else {
        echo "DB OK";
    }
?>
EOF
    chown www-data.www-data /var/www/html/test-db.php
    if curl -s localhost/test-db.php | grep -q 'DB OK'; then
        ok "PHP - MariaDB connection is working."
    else
        err "PHP - MariaDB connection is not working."
    fi

    rm -f /var/www/html/test-db.php /etc/nginx/conf.d/test-php.conf
    nginx_startstop

    mariadb <<EOF
DROP DATABASE tesdb;
DROP USER dbuser@localhost;
FLUSH PRIVILEGES
EOF
}

debug() {
    if declare -F "$__funct" > /dev/null && test "$__funct" != "main"; then
        $__funct
    else
        echo "Function undefined."
    fi
}

main() {
    : > lemp_install.log
    echo "=== LEMP STACK INSTALL LOG ============" >> lemp_install.log
    date --rfc-3339=s >> lemp_install.log
    msg "Installing LEMP stack..."
    msg "Upgrading current packages..."
    # Update repo & upgrade packages
    apt-get update > /dev/null 2>&1 && apt-get upgrade -y > /dev/null 2>&1

    build_pkglist

    # Install
    msg "Installing LEMP stack packages..."
    apt-get install -y ${packages[@]} > /dev/null 2>&1

    verify_services

    if [[ $insecure_mariadb -ne 1 ]]; then
        secure_mariadb
    else
        msg "Not securing mariadb installation."
    fi

    check_listening_ports
    configure_fw
    test_http
    test_php
    test_mysql_php

    if [[ $err_count -eq 0 ]]; then
        msg "Your LEMP stack is ready !!"
    else
        msg "LEMP stack installation is finished with errors. Need manual configuration."
    fi

    echo "=== FINISHED ==========================" >> lemp_install.log
}

debug "$@"
