#!/bin/bash
# apt-get install -y software-properties-common

MYSQL_ROOT_PASS='the_password'
MYSQL_USER_NAME='a_user'
MYSQL_USER_PASS='a_password'
MYSQL_USER_DB='a_db'
INNODB_BUFFER_POOL_SIZE='128M'

# Get paths of repo lists.
REPOS='/etc/apt/sources.list'
if [ -d /etc/apt/sources.list.d ]; then
	REPOS+=' /etc/apt/sources.list.d/*'
fi

# Check if mariadb repo is in the repo list.
grep mariadb $REPOS > /dev/null 2>&1
echo $?

# If the repo does not exist, add it.
if [ $? -ne 0 ]; then
	echo '=> Add mariadb repo.'
	apt-key adv --recv-keys --keyserver hkp://keyserver.ubuntu.com:80 0xcbcb082a1bb943db
	add-apt-repository 'deb http://nyc2.mirrors.digitalocean.com/mariadb/repo/10.0/ubuntu trusty main'
fi

# Make sure mariadb installs without prompts, and set the root password automatically.
export DEBIAN_FRONTEND=noninteractive
debconf-set-selections <<< "mariadb-server-10.0 mysql-server/root_password password $MYSQL_ROOT_PASS"
debconf-set-selections <<< "mariadb-server-10.0 mysql-server/root_password_again password $MYSQL_ROOT_PASS"
#mysql -uroot -pPASS -e "SET PASSWORD = PASSWORD('');"

apt-get update
echo '=> Install mariadb.'
apt-get install -y mariadb-server
echo '=> Install htop.'
apt-get install -y htop
echo '=> Install ufw.'
apt-get install -y ufw
echo '=> Install fail2ban.'
apt-get install -y fail2ban
echo '=> Install nginx.'
apt-get install -y nginx-full
echo '=> Install php5-fpm and extras.'
apt-get install -y php5-fpm php5-mysql php5-mcrypt php5-gd php5-curl php5-common php5-json
echo '=> Done installing.'

echo '=> Configure firewall (UFW).'
sed -ie "s/^IPV6=.*/IPV6=yes/" /etc/default/ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 2222/tcp
ufw allow www
ufw allow https
ufw disable
echo "y" | ufw enable

echo '=> Setup web directories.'
mkdir -p /etc/nginx/presets
mkdir -p /var/web/logs
mkdir -p /var/web/sites/site1.com
mkdir -p /var/web/sites/site2.com

echo '=> Edit php5-fpm config.'
sed -ie "s/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/" /etc/php5/fpm/php.ini

echo '=> Prep nginx conf.'
file=/etc/nginx/fastcgi.conf
if [ ! -f "$file" ]; then
	ln -s /etc/nginx/fastcgi_params "$file"
fi

# Change the innodb_buffer_pool_size (default is 256M, INNODB_BUFFER_POOL_SIZE default is 128M).
sed -i -e 's/^innodb_buffer_pool_size\s*=.*/innodb_buffer_pool_size = '$INNODB_BUFFER_POOL_SIZE'/' /etc/mysql/my.cnf

echo '=> Restart services.'
service mysql restart
service nginx restart

--------------------MARIADB CONF--------------------
echo '=> MariaDB database setup.'

# Make sure mariadb-server is running.
RET=1
while [[ RET -ne 0 ]]; do
	echo "=> Waiting for confirmation of MariaDB service startup..."
	sleep 5
	mysql -u'root' -p"$MYSQL_ROOT_PASS" -e "status" > /dev/null 2>&1
	RET=$?
done

# Clear the mysql.user table of all users except root.
echo "=> Clear mysql.user table (except root)."
mysql -u'root' -p"$MYSQL_ROOT_PASS" -e "DELETE FROM mysql.user WHERE User NOT IN ('root', 'debian-sys-maint'); FLUSH PRIVILEGES;"
#mysql -u'root' -p"$MYSQL_ROOT_PASS" -e "DROP USER IF EXISTS (SELECT GROUP_CONCAT(User) FROM mysql.user WHERE User NOT IN ('root', 'debian-sys-maint') GROUP BY User);"

# Add the database if MYSQL_USER_DB is set.
if [ ! -z "$MYSQL_USER_DB" ]; then
	echo "=> Creating $MYSQL_USER_DB."
	mysql -u'root' -p"$MYSQL_ROOT_PASS" -e "CREATE DATABASE IF NOT EXISTS \`$MYSQL_USER_DB\`;"
fi

# Add the MYSQL_USER_DB user if it exists and the user vars are set.
if [ ! -z "$MYSQL_USER_NAME" -a ! -z "$MYSQL_USER_PASS" -a ! -z "$MYSQL_USER_DB" ]; then
	echo "=> Creating $MYSQL_USER_NAME and granting privileges on $MYSQL_USER_DB."
	echo 'Creating user.'
	mysql -u'root' -p"$MYSQL_ROOT_PASS" -e "CREATE USER '$MYSQL_USER_NAME'@'%' IDENTIFIED BY '$MYSQL_USER_PASS';"
	echo 'Created user.'
	echo 'Granting user.'
	mysql -u'root' -p"$MYSQL_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON \`$MYSQL_USER_DB\`.* TO '$MYSQL_USER_NAME'@'%' WITH GRANT OPTION;"
	echo 'Granted user.'
fi

#--------------------NGINX CONF--------------------
echo '=> Nginx setup.'

echo '=> Write nginx security preset conf file.'
cat > /etc/nginx/presets/security <<'EOTB'
## Deny certain Referers ###
if ( $http_referer ~* (babes|forsale|girl|jewelry|love|nudit|organic|poker|porn|sex|teen) )
{
   return 404;
   return 403;
}
location = /favicon.ico {
  log_not_found off;
  access_log off;
}
location = /robots.txt {
  allow all;
  log_not_found off;
  access_log off;
}
# Deny all attempts to access hidden files such as .htaccess, .htpasswd, .DS_Store (Mac).
# Keep logging the requests to parse later (or to pass to firewall utilities such as fail2ban)
location ~ /\. {
  deny all;
}
# Deny access to any files with a .php extension in the uploads directory
# Works in sub-directory installs and also in multisite network
# Keep logging the requests to parse later (or to pass to firewall utilities such as fail2ban)
location ~* /(?:uploads|files)/.*\.php$ {
  deny all;
}
EOTB

echo '=> Write nginx wordpress preset conf file.'
cat > /etc/nginx/presets/wordpress <<'EOTB'
error_page 404 /404.html;
error_page 500 502 503 504 /50x.html;
location = /50x.html {
    root /usr/share/nginx/html;
}
# Redirect WordPress Multisite file requests to the file handler script.
rewrite /files/(.+) /wp-includes/ms-files.php?file=$1;
location / {
  index   index.php index.html;
  try_files $uri $uri/ /index.php?q=$uri&$args;
}
# Serve static files directly.
location ~* ^.+.(jpg|jpeg|gif|css|png|js|ico|html|xml|txt)$ {
  access_log        off;
  expires           max;
}
# Processes php.
location ~* \.php$ {
  try_files	$uri $uri/ =404;
  fastcgi_split_path_info ^(.+\.php)(/.+)$;
  fastcgi_pass unix:/var/run/php5-fpm.sock;
  fastcgi_index index.php;
  include fastcgi.conf;
}
EOTB

echo '=> Write nginx site conf.'
cat > /etc/nginx/sites-available/site1.com <<'EOTB'
server {
  listen 80 default_server;
  listen [::]:80 default_server ipv6only=off;
  root /var/web/sites/site1.com;
  index index.php index.html index.htm;
  server_name .site1.com;
  access_log  /var/web/logs/site1.com.access.log;
  error_log  /var/web/logs/site1.com.error.log notice;
  include /etc/nginx/presets/wordpress;
}
EOTB

echo '=> Write nginx site conf.'
cat > /etc/nginx/sites-available/site1.com <<'EOTB'
server {
  listen 80;
  listen [::]:80 ipv6only=off;
  root /var/web/sites/site2.com;
  index index.php index.html index.htm;
  server_name .site2.com;
  access_log  /var/web/logs/site2.com.access.log;
  error_log  /var/web/logs/site2.com.error.log notice;
  include /etc/nginx/presets/wordpress;
}
EOTB

echo '=> Reload nginx conf.'
nginx -s reload

