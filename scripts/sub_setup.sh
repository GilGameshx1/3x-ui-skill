#!/usr/bin/env bash
# Подписка 3x-ui: включить, выдать subId старым клиентам, проверить по факту.
#
#   scripts/sub_setup.sh                       включить подписку и проверить её
#   scripts/sub_setup.sh --sub-port 2096 --sub-path /sub/
#   scripts/sub_setup.sh --assign-subids       выдать subId тем, у кого его нет
#   scripts/sub_setup.sh --dry-run             показать настройки, ничего не менять
#
# После включения ссылки не рассылаются вручную: клиент получает один URL
# подписки, и после смены IP панель отдаёт в нём уже новый адрес.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PY=${PYTHON:-python3}

command -v "$PY" >/dev/null || { echo "ОШИБКА: нет $PY" >&2; exit 1; }
[[ -f "$HERE/lib/xui.py" ]] || { echo "ОШИБКА: нет $HERE/lib/xui.py" >&2; exit 1; }

if [[ "${1:-}" == "--assign-subids" ]]; then
    shift
    exec "$PY" "$HERE/lib/xui.py" assign-subids "$@"
fi

exec "$PY" "$HERE/lib/xui.py" sub-setup "$@"
