# Переезд VPN-сервера на новый IP

## Что реально зависит от IP

Пройтись по списку, иначе что-то останется на старом адресе:

| Зависимость | Где смотреть | Чинится |
|---|---|---|
| Исходящий IP хоста | `ip route get 1.1.1.1` | `post-up ip route replace ... src NEW` |
| Исходящий IP контейнеров | `docker exec <c> curl -s https://ifconfig.me` | SNAT-правило (ниже) |
| Клиентские ссылки vless:// | БД 3x-ui, ранее выданные ссылки | новые ссылки (xray-3xui-operations) |
| Сертификат панели/подписки | `settings.webCertFile`, `openssl x509 -ext subjectAltName` | LE на новый IP |
| MTProto `--nat-info` | `ps -o args= -C mtproto-proxy` | пересоздать контейнер |
| AmneziaWG Endpoint | клиентский конфиг на устройстве | правит пользователь |
| Firewall/cloud-фильтр провайдера | `ufw status`, панель хостера | правила на новый IP |

## Порядок

1. Убедиться, что новый IP уже на интерфейсе и живой в обе стороны:
   ```bash
   ip -4 addr show; ip route
   curl -s --interface NEW_IP https://ifconfig.me   # должно вернуть NEW_IP
   ```
   Если `--interface` не работает — провайдер ещё не маршрутизирует, дальше не идти.
2. Основной источник для исходящего: предпочтительный адрес маршрута по умолчанию.
   В ifupdown-системах (`/etc/network/interfaces`) — в стезе алиаса, чтобы адрес уже был:
   ```
   auto ens3:0
   iface ens3:0 inet static
       address   <NEW_IP>
       netmask   255.255.255.0
       post-up ip route replace default via <GW> dev ens3 onlink src <NEW_IP>
   ```
   Живьём: `ip route replace default via <GW> dev ens3 onlink src NEW_IP`.
   Проверка: `ip route get 1.1.1.1` показывает `src NEW_IP`, `curl https://ifconfig.me` — NEW_IP.
3. Контейнеры: добавить SNAT на новый IP (иначе MASQUERADE даст старый).
   ```bash
   iptables -t nat -I POSTROUTING 1 -s 172.17.0.0/16 -o ens3 -j SNAT --to-source NEW_IP
   ```
   Постоянно — через drop-in, потому что docker переставляет свои правила при старте:
   ```
   # /etc/systemd/system/docker.service.d/10-snat-newip.conf
   [Service]
   ExecStartPost=/usr/local/sbin/docker-snat-newip.sh
   ```
   Скрипт должен быть идемпотентным: `iptables -C ... || iptables -I POSTROUTING 1 ...`.
   После `ufw`-операций правило перепроверить — reload/reset может его снести.
4. Пересоздать контейнеры, которые сами узнают внешний IP при старте (MTProto-прокси,
   разные «умные» образы). Секрет/ключи сохранять из `docker inspect` и передавать те же,
   иначе у пользователей отвалятся уже выданные ссылки.
5. Сертификат на новый IP (см. xray-3xui-operations) и переключить панель/подписку.
6. Сквозная проверка: `scripts/verify_vless.py` — exit IP должен быть NEW_IP.
7. Только после этого остановить автооткат-таймер и удалять старый серт из автопродления
   (`acme.sh --remove -d OLD_IP --ecc`, файлы оставить).

## Осторожно

- Смена IP не рвёт уже установленные SSH-сессии (conntrack), но рвёт новые подключения
  к старому адресу — предупреди пользователя до, а не после.
- Полная замена основного адреса на интерфейсе (а не `src` маршрута) чинит NAT сама,
  но может уронить SSH-сессию, пришедшую на старый IP. Сначала проверь, на какой адрес
  висит текущая сессия (`ss -tn state established '( sport = :22 )'`).
- После переезда пройтись по конфигам на старый IP:
  `grep -rn OLD_IP /etc /root --include=*.sh --include=*.conf --include=*.md`.
- Упоминания старого адреса вне сети тоже ломают жизнь: `/etc/hosts` и
  `fail2ban/jail.local` (`ignoreip`) правятся в том же проходе.
- Перед `ifdown/ifup` почистить `/run/network/ifstate`: с устаревшей записью
  ifupdown падает с «Cannot assign requested address» и интерфейс остаётся лежать.
- Шлюз в чужой подсети (не из сети нового адреса) ⇒ строку `gateway` в
  `/etc/network/interfaces` не писать, только `post-up ip route replace default ...
  onlink src <NEW_IP>`; иначе маршрут после ребута не поднимется.
