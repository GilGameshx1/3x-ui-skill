#!/usr/bin/env bash
# Создать клиента в 3x-ui: лимиты по трафику/сроку/IP, subId и готовые ссылки.
#
#   scripts/add_client.sh --inbound 1 --email ivan --expiry-days 30 --quota-gb 100
#   scripts/add_client.sh --inbound VLESS-443 --email ivan --limit-ip 2 --json
#   scripts/add_client.sh --inbound 1 --email ivan --update --quota-gb 200
#
# Пароль панели — из --password, XUI_PASSWORD или запросом без эха. В файлы не
# пишется. Клиента создаёт API панели, а не SQL: иначе нормализованные таблицы
# clients/client_inbounds и статистика разъедутся с тем, что видит панель.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PY=${PYTHON:-python3}

command -v "$PY" >/dev/null || { echo "ОШИБКА: нет $PY" >&2; exit 1; }
[[ -f "$HERE/lib/xui.py" ]] || { echo "ОШИБКА: нет $HERE/lib/xui.py" >&2; exit 1; }

exec "$PY" "$HERE/lib/xui.py" add "$@"
