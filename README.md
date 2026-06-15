## Вступление
Данная инструкция описывает настройку double-hop VPN-сервера на базе AmneziaWG 2.0, `nftables` и `WGDashboard`.

`nftables` используется не только как межсетевой экран, но и для хранения списка российских IP-адресов и подсетей. Трафик от клиентов к этим адресам маркируется и направляется напрямую через российский VPS, а остальной клиентский трафик уходит через внешний VPS.

Для настройки понадобятся два VPS:
- VPS-RU — сервер на территории РФ;
- VPS-EU — сервер за пределами РФ.

В инструкции используется [модуль ядра AmneziaWG](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module), но аналогичная схема должна работать и с [userspace реализацией на Go](https://github.com/amnezia-vpn/amneziawg-go).

Список российских IP-адресов берется из CSV-версии базы `GeoLite2-Country` от MaxMind. Вопрос получения самой базы в этой инструкции не рассматривается.

На обоих, используемых в инструкции, VPS установлен Debian 13. Для Ubuntu установка модуля ядра AmneziaWG обычно проще.

Инструкция охватывает только IPv4.

Все команды выполняются от имени `root`.

## Установка AmneziaWG на VPS-EU и VPS-RU
В Debian 13 модуль ядра устанавливается следующим образом:
```bash
apt update && apt install -y curl git gnupg2 linux-headers-amd64
mkdir -p /root/.gnupg && chmod 700 /root/.gnupg
gpg --no-default-keyring --keyring /tmp/amnezia-kbx.gpg --keyserver keyserver.ubuntu.com --recv-keys 57290828 \
  && gpg --no-default-keyring --keyring /tmp/amnezia-kbx.gpg --export 57290828 | tee /etc/apt/keyrings/amnezia.gpg > /dev/null \
  && rm -f /tmp/amnezia-kbx.gpg
chmod 644 /etc/apt/keyrings/amnezia.gpg
cat << 'EOF' | tee /etc/apt/sources.list.d/amnezia.sources > /dev/null
Types: deb deb-src
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/
Suites: noble
Components: main
Signed-By: /etc/apt/keyrings/amnezia.gpg
EOF
apt update && apt install -y amneziawg amneziawg-tools
```
Для более ранних версий Debian и других дистрибутивов используйте инструкцию из [официального репозитория](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module#installation).

## Настройка параметров ядра на VPS-EU и VPS-RU
Необходимо настроить два параметра ядра.

Первый — стандартный для VPN-серверов форвардинг пакетов.

Второй — включение алгоритма управления перегрузкой TCP BBR, разработанного Google. На практике оказалось, что для double-hop схемы это критически важно: без BBR скорость через два туннеля может падать до 3–7 Мбит/с.

В итоге в `/etc/sysctl.conf` должны присутствовать следующие параметры:
```
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```
Сохраните изменения и примените их:
```bash
sysctl -p
```

## Настройка AmneziaWG на VPS-EU
Ниже приведен пример настройки интерфейса `awg0`, который используется для туннеля между VPS-EU и VPS-RU.

`PostUp` хук увеличивает размер очереди передачи пакетов для интерфейса `awg0`. По умолчанию в Linux это значение равно 500.
```
# /etc/amnezia/amneziawg/awg0.conf

[Interface]
Address = 10.0.1.1/24
ListenPort = 32304
PrivateKey = <VPS-EU-AWG0-PRIVATE-KEY>

PostUp = ip link set dev awg0 txqueuelen 10000

Jc = 5
Jmin = 64
Jmax = 1024

S1 = 56
S2 = 64
S3 = 23
S4 = 6

H1 = 1199437766-1199437834
H2 = 1014306829-1014306972
H3 = 2039511259-2039511268
H4 = 587455332-646200865

I1 = <b 0xc200000001109ae33c30cb2166d67277406ca37fe3300f4f20619cb7084c7e33bebfa88a92270cc346ae159542288d25af11b8e12915d1><rc 8><t><r 96>
I2 = <b 0xc10000000108f8f944f8664e326710189301db483372bda1ca5ea8d3ba10f513aeb416b6b28fa181d7876d789b2bab0a8559fce0110d3e><rc 15><t><r 96>
I3 = <b 0xc2000000010cf55a38c2424858c8db1013d514b1708acb76b84436caca0d6c8b5ae6158a0c0fda00000157c1><rc 13><t><r 100>
I4 = <b 0xc000000001101343a082d9b74eeb9e106880edc8b9ee02413f00c74177ed><rc 14><t><r 104>
I5 = <b 0xc100000001086296da29b90dfbee116817633d1fe298718a72cb99b0dab876b30d6f0da03fac81e54d44914d52f26c1f6ae5><rc 13><t><r 118>

[Peer]
PublicKey = <VPS-RU-AWG0-PUBLIC-KEY>
AllowedIPs = 10.0.1.2/32
```
Для генерации конфига AmneziaWG 2.0 можно использовать [AmneziaWG Architect](https://architect.vai-rice.space).

Из сгенерированного конфига нужно перенести параметы `Jc`, `Jmin`, `Jmax`, `S1-S4`, `H1-H4`, `I1-I5` в пример выше, а также заполнить параметры `PrivateKey` в секции `[Interface]` и `PublicKey` в секции `[Peer]`.
Пары ключей можно сгенерировать так:
```bash
awg genkey | tee private.key | awg pubkey > public.key
```
После завершения редактирования конфига запустите сервис:
```bash
systemctl enable --now awg-quick@awg0.service
```
Проверить, что интерфейс поднялся, можно командой:
```bash
ip a
```
Также можно посмотреть состояние AmneziaWG:
```bash
awg show all
```

## Настройка файрволла на VPS-EU
На этом сервере `nftables` выполняет две задачи:
- работает как обычный межсетевой экран;
- выполняет masquerade для пакетов из туннеля `awg0`, подменяя адрес источника на адрес исходящего интерфейса.

Межсетевой экран разрешает:
- любые входящие подключения к `localhost`;
- входящие подключения к SSH (`22/tcp`);
- входящие подключения к AmneziaWG (`32304/udp`).

В этом примере необходимо актуализировать следующие значения:
- `AWG_PORT` — порт из конфига `/etc/amnezia/amneziawg/awg0.conf`;
- `AWG_NET` — сеть, используемая в туннеле `awg0`;
- `WAN_IF` — имя внешнего сетевого интерфейса на VPS-EU.

Имя сетевого интерфейса можно посмотреть командой:
```bash
ip a
```
Конфиг `/etc/nftables.conf`:
```
#!/usr/sbin/nft -f

flush ruleset

define WAN_IF = "eth0"
define AWG_IF = "awg0"
define AWG_PORT = 32304
define AWG_NET = 10.0.1.0/24

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname "lo" accept
        tcp dport 22 accept
        udp dport $AWG_PORT accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        iifname $AWG_IF oifname $WAN_IF accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table inet nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr $AWG_NET oifname $WAN_IF masquerade
    }
}
```
После сохранения конфига включите файрволл:
```bash
systemctl enable --now nftables.service
```

## Настройка AmneziaWG на VPS-RU

### Настройка туннеля между VPS-EU и VPS-RU
Ниже приведен пример настройки интерфейса `awg0`, который используется для туннеля между VPS-EU и VPS-RU.

Параметры `Jc`, `Jmin`, `Jmax`, `S1-S4`, `H1-H4`, `I1-I5` должны совпадать с параметрами, указанными в конфиге `awg0` на VPS-EU.

Параметр `Table = off` нужен для того, чтобы `awg-quick` не создавал маршрут по умолчанию через туннель. В противном случае можно потерять доступ к серверу по SSH.

Немаркированный трафик из клиентской сети `awg1` будет направляться в туннель `awg0` с помощью `PostUp` хуков.
```
# /etc/amnezia/amneziawg/awg0.conf

[Interface]
Address = 10.0.1.2/24
PrivateKey = <VPS-RU-AWG0-PRIVATE-KEY>
Table = off

PostUp = ip link set dev awg0 txqueuelen 10000
PostUp = ip route add default dev awg0 table 200
PostDown = ip route del default dev awg0 table 200

Jc = 5
Jmin = 64
Jmax = 1024

S1 = 56
S2 = 64
S3 = 23
S4 = 6

H1 = 1199437766-1199437834
H2 = 1014306829-1014306972
H3 = 2039511259-2039511268
H4 = 587455332-646200865

I1 = <b 0xc200000001109ae33c30cb2166d67277406ca37fe3300f4f20619cb7084c7e33bebfa88a92270cc346ae159542288d25af11b8e12915d1><rc 8><t><r 96>
I2 = <b 0xc10000000108f8f944f8664e326710189301db483372bda1ca5ea8d3ba10f513aeb416b6b28fa181d7876d789b2bab0a8559fce0110d3e><rc 15><t><r 96>
I3 = <b 0xc2000000010cf55a38c2424858c8db1013d514b1708acb76b84436caca0d6c8b5ae6158a0c0fda00000157c1><rc 13><t><r 100>
I4 = <b 0xc000000001101343a082d9b74eeb9e106880edc8b9ee02413f00c74177ed><rc 14><t><r 104>
I5 = <b 0xc100000001086296da29b90dfbee116817633d1fe298718a72cb99b0dab876b30d6f0da03fac81e54d44914d52f26c1f6ae5><rc 13><t><r 118>

[Peer]
PublicKey = <VPS-EU-AWG0-PUBLIC-KEY>
AllowedIPs = 10.0.1.1/32, 0.0.0.0/0
Endpoint = <VPS-EU-EXTERNAL-IP>:32304
PersistentKeepalive = 25
```
После завершения редактирования конфига запустите сервис:
```bash
systemctl enable --now awg-quick@awg0.service
```
Проверьте, что интерфейс активен:
```bash
ip a
```
Проверьте, что handshake проходит успешно:
```bash
awg show all
```
На этом настройка туннеля между VPS-EU и VPS-RU завершена.

Чтобы убедиться, что трафик через туннель проходит, а форвардинг на стороне VPS-EU работает корректно, выполните:
```bash
curl --interface awg0 https://checkip.amazonaws.com
```
В ответе должен быть внешний IP-адрес VPS-EU.

### Настройка туннеля для клиентов, подключающихся к VPS-RU
Ниже приведен пример настройки интерфейса `awg1`, который принимает подключения от клиентов.

В конфиге намеренно указана только секция `[Interface]`, так как клиентов удобнее добавлять позже через `WGDashboard`.

Для этого интерфейса лучше сгенерировать отдельный набор параметров `Jc`, `Jmin`, `Jmax`, `S1-S4`, `H1-H4`, `I1-I5`.

Также немного уменьшаем `MTU`. На практике это помогает избежать просадок скорости. 
```
# /etc/amnezia/amneziawg/awg1.conf

[Interface]
Address = 10.0.2.1/24
MTU = 1280
Table = off
PostUp = ip link set dev awg1 txqueuelen 10000
PostUp = ip rule add fwmark 2 table main priority 90
PostUp = ip rule add from 10.0.1.0/24 table 200 priority 100
PostDown = ip rule del from 10.0.1.0/24 table 200 priority 100
PostDown = ip rule delete fwmark 2 table main priority 90

ListenPort = 36712
PrivateKey = <VPS-RU-AWG1-PRIVATE-KEY>

Jc = 8
Jmin = 64
Jmax = 1024

S1 = 48
S2 = 4
S3 = 55
S4 = 8

H1 = 1619721451-1619721510
H2 = 1527340628-1527340686
H3 = 1186297813-1186297827
H4 = 487507927-536258719

I1 = <b 0xc3000000010cfa7f417734cc0c42ec07bd8f14e50e95bf89b25546312eaf72522f3bc75d1767c40aa4418f9374273c98349baa48b51c><rc 11><t><r 108>
I2 = <b 0xc0000000010cb79c92fc653c35fb9e89ca8a0a6dfc730ae72798da8e020e561bb5ab01a78a4e70b5a4a7424b77d877e1><rc 10><t><r 82>
I3 = <b 0xc2000000010e91a466bbe7d4f313b499db9af8f903834076185fe8cd857c630531faafa9554ebdca767d07fa442f7a9687d894fb40><rc 24><t><r 134>
I4 = <b 0xc0000000011428a5e87c3efacfd95fca246e3bb04d952c60c2250385ffa81185a15a1550746938a5581e91e8284a8a55b7d30b0a><rc 18><t><r 122>
I5 = <b 0xc0000000010cb45b9ab84724a7c6c49ed38111a248955b7885151b1a8fe04b822b50f1cb1e5cf994f4832d2f55ea9fc9ce998df187a92858e5414e5c6f2de1a964df4c14a486a0><rc 13><t><r 98>
```
Запустите сервис:
```bash
systemctl enable --now awg-quick@awg1.service
```

## Настройка файрволла на VPS-RU
На этом сервере `nftables` выполняет несколько задач:
- работает как межсетевой экран;
- выполняет masquerade для пакетов из туннеля `awg1`;
- маркирует трафик, адрес назначения которого находится в сете `russia`.

Маркированный трафик уходит напрямую через провайдера VPS-RU, а не через туннель `awg0`.

Межсетевой экран разрешает:
- любые входящие подключения к `localhost`;
- входящие подключения к SSH (`22/tcp`);
- входящие подключения к AmneziaWG (`36712/udp`);
- входящие подключения к Caddy (`80/tcp`, `443/tcp`, `443/udp`, `4443/tcp`).

Перед применением конфига подставьте актуальные значения:
- `WAN_IF` — имя внешнего сетевого интерфейса на VPS-RU;
- `AWG_IN_PORT` — порт из конфига `awg1`;
- `AWG_OUT_NET` — сеть из конфига `awg0`;
- `AWG_IN_NET` — сеть из конфига `awg1`.

Результат сохраните в `/etc/nftables.conf`.

Список российских IP-адресов и подсетей в формате `nftables` находится в файле `vps-ru/etc/nftables.russia.zone`. Скопируйте его в `/etc/nftables.russia.zone`.

В строке `tcp flags syn tcp option maxseg size set 1240` в цепи `forward` нужно указать значение `MTU` интерфейса `awg1`, уменьшенное на 40.

Порты 80 и 443 в этом конфиге разрешены для того, чтобы `Caddy` мог получить TLS-сертификат. Порт 4443 также используется `Caddy` — он проксирует запросы к `WGDashboard`.

Если вы не планируете использовать `Caddy`, удалите соответствующие правила для портов 80, 443 и 4443.

```
#!/usr/sbin/nft -f

flush ruleset

define WAN_IF = "eth0"
define AWG_OUT_IF = "awg0"
define AWG_IN_IF = "awg1"
define AWG_IN_PORT = 36712
define AWG_OUT_NET = 10.0.1.0/24
define AWG_IN_NET = 10.0.2.0/24

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif "lo" accept
        tcp dport 22 accept
        tcp dport 80 accept
        tcp dport 443 accept
        tcp dport 4443 accept
        udp dport 443 accept
        udp dport $AWG_IN_PORT accept
    }
    
    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        tcp flags syn tcp option maxseg size set 1240
        iifname $AWG_IN_IF oifname $WAN_IF accept
        iifname $AWG_IN_IF oifname $AWG_OUT_IF accept
    }
    
    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table ip mangle {
    set russia {
        type ipv4_addr
        flags interval
        include "/etc/nftables.russia.zone"
    }
    
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        ct state established,related accept
        ip daddr { $AWG_OUT_NET, $AWG_IN_NET } accept
        ip daddr @russia counter meta mark set 2
    }
}

table inet nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr $AWG_IN_NET oifname != $AWG_IN_IF masquerade
    }
}
```
Включите файрволл:
```bash
systemctl enable --now nftables.service
```

### Скрипт для формирования обновленного списка российских IP адресов
Скрипт `vps-ru/opt/maxmind/prepare-nft-set.sh` нужно скопировать в `/opt/maxmind`.

В этой же директории должны находиться файлы:
- `GeoLite2-Country-Locations-en.csv`;
- `GeoLite2-Country-Blocks-IPv4.csv`.

После запуска скрипта будет сформирован обновленный файл `/etc/nftables.russia.zone` со списком российских IP-адресов и подсетей в формате `nftables`.

Чтобы применить обновленный список, выполните:
```bash
nft -f /etc/nftables.conf
```

## Установка и настройка панели управления WGDashboard на VPS-RU
Установите `WGDashboard` аналогично официальной инструкции, но без установки пакетов оригинального `wireguard` и `iptables`:
```bash
git clone https://github.com/WGDashboard/WGDashboard.git /opt/wgd && \
cd /opt/wgd/src && \
chmod +x ./wgd.sh && \
./wgd.sh install
```
После установки нужно один раз запустить и остановить `WGDashboard`, чтобы был создан конфиг:
```bash
./wgd.sh start
./wgd.sh stop
```
Далее рекомендуется изменить параметр `app_ip` в файле `/opt/wgd/src/wg-dashboard.ini`:

`app_ip = 0.0.0.0` заменить на `app_ip = 127.0.0.1`.

После этого дашборд будет принимать подключения только с `localhost`.

Для доступа к нему можно использовать SSH local forwarding. При подключении добавьте параметр:
```
-L 127.0.0.1:8000:127.0.0.1:10086
```
Здесь:
- `127.0.0.1:8000` — локальный адрес на вашем компьютере;
- `127.0.0.1:10086` — адрес и порт на VPS-RU, где слушает `WGDashboard`.

После подключения дашборд будет доступен на вашем компьютере по адресу:
```
http://127.0.0.1:8000
```
Если для сервера уже настроен хост в SSH-конфиге, добавьте к нему строку:
```
LocalForward 127.0.0.1:8000 127.0.0.1:10086
```

Подготовьте unit-файл `/etc/systemd/system/wgd.service`:
```unit file (systemd)
[Unit]
After=syslog.target network-online.target
Wants=awg-quick.target
ConditionPathIsDirectory=/etc/amnezia/amneziawg

[Service]
Type=forking
PIDFile=/opt/wgd/src/gunicorn.pid
WorkingDirectory=/opt/wgd/src
ExecStart=/opt/wgd/src/wgd.sh start
ExecStop=/opt/wgd/src/wgd.sh stop
ExecReload=/opt/wgd/src/wgd.sh restart
TimeoutSec=120
PrivateTmp=yes
Restart=always

[Install]
WantedBy=multi-user.target
```
Запустите созданный сервис `wgd`
```bash
systemctl daemon-reload && systemctl enable --now wgd.service
```
Учетные данные по умолчанию для входа в `WGDashboard`:
- логин `admin`;
- пароль `admin`.

При первом входе система предложит изменить логин и пароль, а также настроить двухфакторную авторизацию.

После входа выберите `awg1` в списке конфигураций и добавьте пиров. `WGDashboard` позволяет экспортировать клиентские конфиги как файлами, так и QR-кодами.

Если вы открываете дашборд во внешнюю сеть, отключите `Client Side App` в разделе `WGDashboard` → `Clients` → `Settings`.

## Установка и настройка Caddy на VPS-RU
`Caddy` нужен в том случае, если `WGDashboard` должен быть доступен на внешнем интерфейсе VPS-RU по доменному имени, но вы не хотите отдельно настраивать `certbot` или `acme.sh`.

Доменное имя, которое будет использоваться, должно указывать на сервер VPS-RU (А запись).

Установите `Caddy`:
```bash
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
chmod o+r /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install caddy
```

Конфиг `/etc/caddy/Caddyfile`:
```caddyfile
# указывается email для выпуска сертификата
{
    email user@domain.com
}
# указывается доменное имя и порт, на которых должен быть доступен WGDashboard
# при изменении порта его нужно поменять и в конфиге nftables
https://your.domain.com:4443 {
    reverse_proxy 127.0.0.1:10086
}
```
Запустите `Caddy`:
```bash
systemctl enable --now caddy.service
```