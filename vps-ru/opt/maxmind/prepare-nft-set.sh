#!/bin/bash

cd /opt/maxmind || exit 1

if [ ! -f 'GeoLite2-Country-Blocks-IPv4.csv' ]; then
    echo 'GeoLite2-Country-Blocks-IPv4.csv is not found in /opt/maxmind'
    exit 1
fi

if [ ! -f 'GeoLite2-Country-Locations-en.csv' ]; then
    echo 'GeoLite2-Country-Locations-en.csv is not found in /opt/maxmind'
    exit 1
fi

echo 'Parsing Russian IP addresses from CSVs'

grep -E ',RU,' GeoLite2-Country-Locations-en.csv | awk -F',' '{print $1}' > ru_ids.txt

grep -f ru_ids.txt GeoLite2-Country-Blocks-IPv4.csv | awk -F',' '{print $1}' > ips.txt

rm -f ru_ids.txt

if [ ! -s ips.txt ]; then
    echo 'Failed preparing set of Russian IP addresses'
    exit 1
fi

CIDR_LIST=$(awk '{
    gsub(/^[ \t\r]+/, "")
    gsub(/[ \t\r]+$/, "")

    if (length($0) >= 9) {
        if (count++ > 0) printf ",\n  "
        printf "%s", $0
    }
}' ips.txt)

cat <<EOF > /etc/nftables.russia.zone
elements = {
  $CIDR_LIST
}
EOF

rm -f ips.txt

echo "You can now restart nftables to apply changes"