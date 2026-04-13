# AS Network List Block

Блокировка сетей по списку [C24Be/AS_Network_List](https://github.com/C24Be/AS_Network_List) через nftables.

## Запуск

```bash
bash <(wget -O - https://raw.githubusercontent.com/archicodee/AS-Network-List-Block/refs/heads/main/asnl-block.sh)
```

Меню:

| Пункт | Действие |
|-------|----------|
| 1 | Установить |
| 2 | Обновить |
| 3 | Удалить |
| 4 | Статус |

## Автообновление (cron)

При установке скрипт предложит добавить cron-задачу (ежедневно в 04:30).  
Ручной запуск для cron:

```bash
/usr/local/bin/asnl-block-update --update
```

## Что делает установка

1. Проверяет/устанавливает зависимости (`nftables`, `curl`, `jq`, `aggregate`)
2. Если нет таблицы `inet filter` — создаёт базовый конфиг (policy drop), открывая только порты реально слушающих сервисов (SSH определяется через `ss`, 80/443 — только если есть слушатель)
3. Если таблица есть — добавляет sets и правила в существующую конфигурацию
4. Скачивает списки подсетей, агрегирует пересекающиеся CIDR (IPv4 — `aggregate`, IPv6 — `python3 ipaddress`)
5. Предлагает настроить автообновление через cron

## Требования

- Debian 12+ / Ubuntu 22.04+
- nftables, curl, jq, aggregate (установятся автоматически)
