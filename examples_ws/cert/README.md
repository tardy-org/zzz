# how to wildcard certs
how to wildcard certs for localhost ssl-http-wss tests --  
tested on (l)ubuntu 22.04 LTS but possible on any linux
```
sudo vim /etc/hosts

# add next lines
127.0.0.1 test1.ls
127.0.0.1 en.test1.ls
127.0.0.1 test2.ls
127.0.0.1 subdomain.test2.ls

# apply changes without reboot (few commands - latest is newest)
sudo /etc/init.d/networking restart
# or
sudo service networking restart
# or
sudo /etc/init.d/network-manager restart
# or
sudo service network-manager restart
# or
sudo systemctl restart NetworkManager.service

# next lets create certs
mkdir certs
cd certs
vim ssl.conf

# add and save next lines
[ req ]
default_bits      = 4096
distinguished_name = req_distinguished_name
req_extensions    = req_extensions_section

[ req_distinguished_name ]
countryName                    = Country Name (2 letter code)
countryName_min                = 2
countryName_max                = 2
countryName_default            = UA
stateOrProvinceName            = State or Province Name (full name)
stateOrProvinceName_default    = Lviv
localityName                    = Locality Name (eg, city)
localityName_default            = Lviv
organizationName                = Organization Name (eg, company)
organizationName_default        = Test
organizationalUnitName          = Organizational Unit Name (eg, section)
organizationalUnitName_default  = IT
commonName                      = Common Name (e.g. server FQDN or YOUR name)
commonName_max                  = 64
commonName_default              = localhost
emailAddress                    = Email Address (eg, admin@example.com)
emailAddress_max                = 64
emailAddress_default            = info@test.com

[ req_extensions_section ]
subjectAltName = @subject_alternative_name_section

[ subject_alternative_name_section ]
DNS.1  = test1.ls
DNS.2  = *.test1.ls
DNS.3  = test2.ls
DNS.4  = *.test2.ls

# save file in vim and exit = CTRL + I for editing, next Esc, :w! for save and :q! for exit

# next generate privkey
openssl genrsa -out private.key 4096

# generate CSR (Certificate Signing Request) - "Common name" is your project name
openssl req -new -sha256   -out private.csr   -key private.key   -config ssl.conf

# check CSR
openssl req -text -noout -in private.csr

# we will see something like next
...
X509v3 Subject Alternative Name: DNS:test1.ls
...
Signature Algorithm: sha256WithRSAEncryption
...

# generate cert
openssl x509 -req   -sha256   -days 3650   -in private.csr   -signkey private.key   -out private.crt   -extensions req_extensions_section   -extfile ssl.conf

# install cert as trusted in system
sudo mkdir /usr/share/ca-certificates/extra
sudo cp private.crt /usr/share/ca-certificates/extra/private.crt

sudo dpkg-reconfigure ca-certificates
# or
sudo update-ca-certificates

# next we can use cert, for example, in nginx
server{
  listen 443 ssl http2;
  ssl_certificate /home/user/certs/private.crt;
  ssl_certificate_key /home/user/certs/private.key;
  ssl_dhparam /home/user/certs/dhparams.pem;
  
  ...
  server_name www.test1.ls;
  return 301 https://test1.ls$request_uri;
}

# or use without nginx
# we can see cert usage in 2nd ws example

# if we have private.csr, private.crt and private.key
#  but needs fullchain.pem and privkey.pem - just copy:

cp private.key privkey.pem
cp private.crt fullchain.pem
```

