# Ссылка VLESS Reality — шпаргалка

```
vless://<UUID>@<HOST>:<PORT>?type=tcp&security=reality&pbk=<PBK>&fp=chrome&sni=<SNI>&sid=<SID>&spx=%2F&flow=xtls-rprx-vision#<TAG>
```

| Параметр | Откуда брать |
|---|---|
| UUID | `inbounds.settings.clients[].id` |
| HOST | публичный IP (после переезда — новый) |
| PORT | `inbounds.port` |
| PBK | `xray x25519 -i <privateKey>` → строка `Password`, base64url без `=` |
| SNI | `realitySettings.serverNames[0]` (обычно `dest` без порта) |
| SID | `realitySettings.shortIds[0]` |
| flow | `clients[].flow`; если пусто — параметр не добавлять |

Проверка без клиента: `scripts/verify_vless.py` с теми же значениями — печатает exit IP.
