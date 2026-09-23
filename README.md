## Вступление
Данная инструкция описывает настройку double-hop VPN-сервера на базе AmneziaWG 3.1, `nftables` и `WGDashboard`.

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
Необходимо настроить несколько параметров ядра.

Первый — стандартный для VPN-серверов форвардинг пакетов.

Второй — включение алгоритма управления перегрузкой TCP BBR, разработанного Google. На практике оказалось, что для double-hop схемы это критически важно: без BBR скорость через два туннеля может падать до 3–7 Мбит/с. Для включения BBR необходимо изменить и `default_qdisc`.

И последний — увеличивает лимит для `conntrack`.

В Debian 13 (и других системах, использующих `systemd` версии 256 и новее) файл `/etc/sysctl.conf` более не обрабатывается системой при загрузке, теперь служба `systemd-sysctl` читает конфигурационные файлы только из папки `/etc/sysctl.d`.
Запишите следующие параметры в файл `/etc/sysctl.d/sysctl.conf`:
```ini
net.ipv4.ip_forward = 1

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.netfilter.nf_conntrack_max = 1048576
net.nf_conntrack_max = 1048576
```
Проверьте, что модуль ядра для отслеживания соединений `nf_conntrack` загружен:
```bash
lsmod | grep nf_conntrack
```
Если вывод предыдущей команды пустой, включите загрузку модуля при старте системы и загрузите модуль вручную:
```bash
echo "nf_conntrack" | tee /etc/modules-load.d/nf_conntrack.conf
modprobe nf_conntrack
```
Примените новые параметры ядра:
```bash
systemctl restart systemd-sysctl
```

## Настройка AmneziaWG на VPS-EU
Ниже приведен пример настройки интерфейса `awg0`, который используется для туннеля между VPS-EU и VPS-RU.

`PostUp` хук увеличивает размер очереди передачи пакетов для интерфейса `awg0`. По умолчанию в Linux это значение равно 500.
```ini
# /etc/amnezia/amneziawg/awg0.conf

[Interface]
Address = 10.0.1.1/24
ListenPort = 32304
PrivateKey = <VPS-EU-AWG0-PRIVATE-KEY>

PostUp = ip link set dev awg0 txqueuelen 10000

Jc = 
Jmin = 
Jmax = 

S1 = 
S2 = 
S3 = 
S4 = 

H1 = 
H2 = 
H3 = 
H4 = 

I1 = 
I2 = 
I3 = 
I4 = 
I5 =

HeaderProtectionKey = 
ContentPaddingAddition = 
RekeyAfterTime = 
RekeyTimeout = 
RejectAfterTime = 
KeepaliveTimeout = 
MaxHandshakeAttempts = 

[Peer]
PublicKey = <VPS-RU-AWG0-PUBLIC-KEY>
AllowedIPs = 10.0.1.2/32
```
Для генерации конфига AmneziaWG 3.1 можно использовать [AmneziaWG Architect](https://architect.vai-rice.space/amneziawg).

Из сгенерированного конфига нужно перенести параметы `Jc`, `Jmin`, `Jmax`, `S1-S4`, `H1-H4`, `I1-I5`, `ContentPaddingAddition`, `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout`, `MaxHandshakeAttempts` в пример выше, а также заполнить параметры `PrivateKey` и `HeaderProtectionKey` в секции `[Interface]` и `PublicKey` в секции `[Peer]`.
`HeaderProtectionKey` можно сгенерировать так:
```bash
openssl rand -base64 32
```
Пары ключей можно сгенерировать так:
```bash
awg genkey | tee private.key | awg pubkey > public.key
```
После завершения редактирования конфига запустите сервис:
```bash
systemctl enable --now awg-quick@awg0.service
```
Проверьте, что интерфейс поднялся:
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

Параметры `Jc`, `Jmin`, `Jmax`, `S1-S4`, `H1-H4`, `I1-I5`, `HeaderProtectionKey`, `ContentPaddingAddition`, `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout`, `MaxHandshakeAttempts` должны совпадать с параметрами, указанными в конфиге `awg0` на VPS-EU.

Параметр `Table = off` нужен для того, чтобы `awg-quick` не создавал маршрут по умолчанию через туннель. В противном случае можно потерять доступ к серверу по SSH.

Немаркированный трафик из клиентской сети `awg1` будет направляться в туннель `awg0` с помощью `PostUp` хуков.
```ini
# /etc/amnezia/amneziawg/awg0.conf

[Interface]
Address = 10.0.1.2/24
PrivateKey = <VPS-RU-AWG0-PRIVATE-KEY>
Table = off

PostUp = ip link set dev awg0 txqueuelen 10000
PostUp = ip route add default dev awg0 table 200
PostUp = ip rule add fwmark 2 table main priority 90
PostDown = ip rule delete fwmark 2 table main priority 90
PostDown = ip route del default dev awg0 table 200

Jc =
Jmin =
Jmax =

S1 =
S2 =
S3 =
S4 =

H1 =
H2 =
H3 =
H4 =

I1 =
I2 =
I3 =
I4 =
I5 =

HeaderProtectionKey =
ContentPaddingAddition =
RekeyAfterTime =
RekeyTimeout =
RejectAfterTime =
KeepaliveTimeout =
MaxHandshakeAttempts =

[Peer]
PublicKey = <VPS-EU-AWG0-PUBLIC-KEY>
AllowedIPs = 10.0.1.1/32, 0.0.0.0/0
Endpoint = <VPS-EU-EXTERNAL-IP>:32304
PersistentKeepalive = 22-30
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

Для этого интерфейса лучше сгенерировать отдельный набор параметров `Jc`, `Jmin`, `Jmax`, `S1-S4`, `H1-H4`, `I1-I5`, `HeaderProtectionKey`, `ContentPaddingAddition`, `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout`, `MaxHandshakeAttempts`.

Также немного уменьшаем `MTU`. На практике это помогает избежать просадок скорости. 
```ini
# /etc/amnezia/amneziawg/awg1.conf

[Interface]
Address = 10.0.2.1/24
MTU = 1280
Table = off
PostUp = ip link set dev awg1 txqueuelen 10000
PostUp = ip rule add from 10.0.2.0/24 table 200 priority 100
PostDown = ip rule del from 10.0.2.0/24 table 200 priority 100

ListenPort = 36712
PrivateKey = <VPS-RU-AWG1-PRIVATE-KEY>

Jc = 
Jmin = 
Jmax = 

S1 = 
S2 = 
S3 = 
S4 = 

H1 = 
H2 = 
H3 = 
H4 = 

I1 = 
I2 = 
I3 = 
I4 = 
I5 =

HeaderProtectionKey =
ContentPaddingAddition =
RekeyAfterTime =
RekeyTimeout =
RejectAfterTime =
KeepaliveTimeout =
MaxHandshakeAttempts = 
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

В цепочках `forward` таблицы `inet filter ` и `postrouting` таблицы `inet nat` нужно указать значение `MTU` интерфейса `awg1`, уменьшенное на 40 (в примере это 1240):
```
tcp flags syn tcp option maxseg size set 1240
```
```
oifname $WAN_IF tcp flags syn tcp option maxseg size set 1240
```

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
        ip protocol icmp icmp type { destination-unreachable, time-exceeded } accept
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
        ip protocol icmp icmp type { destination-unreachable, time-exceeded } accept
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
        meta mark set ct mark
        ip daddr { $AWG_OUT_NET, $AWG_IN_NET } accept
        iifname $AWG_IN_IF ip daddr @russia ct state new ct mark set 2 meta mark set 2
    }
}

table inet nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname $WAN_IF tcp flags syn tcp option maxseg size set 1240
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
Так как на данный момент AmneziaWG 3.0/3.1 не поддерживается в `WGDashboard`, можно использовать мой форк. Установка аналогична официальной инструкции с некоторыми дополнениями - вам понадобится npm (Node.js package manager):
```bash
git clone https://github.com/evgenyvolferts/WGDashboard.git /opt/wgd && \
cd /opt/wgd/src/static/app && \
npm install && \
npm run build && \
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
```ini
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

После входа в разделе `WGDashboard` → `Settings` → `Peer Settings` очистите `DNS`, `MTU`, поменяйте `Persistent Keepalive` на `25` (значение из [документации WireGuard](https://www.wireguard.com/quickstart/#nat-and-firewall-traversal-persistence)). В случае использования доменного имени вместо IP адреса для подключения клиентов - введите его в поле `Peer Remote Endpoint`.

Далее в списке конфигураций выберите `awg1`, откройте `Configuration Settings` и укажите значение `1280` в поле `MTU`, а также `DNS` по желанию.  Следующим шагом добавьте пиров (клиентов). `WGDashboard` позволяет экспортировать клиентские конфиги как файлами, так и QR-кодами.

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