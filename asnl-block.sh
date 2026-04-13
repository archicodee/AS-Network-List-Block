#!/bin/bash

# AS Network List Block — блокировка сетей обнаружения через nftables
# Данные: C24Be/AS_Network_List (обновляются ежедневно на GitHub)
# Версия: 1.0

version="1.0"
BLACKLIST_URL="https://raw.githubusercontent.com/C24Be/AS_Network_List/main/blacklists"
NFT_CONF="/etc/nftables.conf"
LOG_FILE="/var/log/asnl-block.log"
CRON_MARKER="asnl-block-update"

textcolor='\033[1;36m'
red='\033[1;31m'
green='\033[1;32m'
grey='\033[1;30m'
clear='\033[0m'

# ─── Утилиты ───────────────────────────────────────────────────────────────

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"; }

check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${red}Запустите от root${clear}"; exit 1; }
}

check_deps() {
    local to_install=()
    command -v nft      &>/dev/null || to_install+=("nftables")
    command -v curl     &>/dev/null || to_install+=("curl")
    command -v jq       &>/dev/null || to_install+=("jq")
    command -v aggregate &>/dev/null || to_install+=("aggregate")

    if [[ ${#to_install[@]} -gt 0 ]]; then
        echo -e "${textcolor}Устанавливаю зависимости: ${to_install[*]}${clear}"
        apt update -qq && apt install -y -qq "${to_install[@]}"
    fi
}

is_installed() {
    nft list set inet filter blacklist_v4 &>/dev/null
}

get_counts() {
    local v4=0 v6=0
    if is_installed; then
        v4=$(nft -j list set inet filter blacklist_v4 2>/dev/null | jq '.nftables[1].set.elem | length' 2>/dev/null || echo 0)
        v6=$(nft -j list set inet filter blacklist_v6 2>/dev/null | jq '.nftables[1].set.elem | length' 2>/dev/null || echo 0)
    fi
    echo "$v4 $v6"
}

get_last_update() {
    tail -1 "$LOG_FILE" 2>/dev/null | cut -d' ' -f1-2 || echo "N/A"
}

is_cron_enabled() {
    crontab -l 2>/dev/null | grep -q "$CRON_MARKER"
}

get_ssh_port() {
    # 1. Что sshd реально слушает — самый надёжный способ
    local port
    port=$(ss -tlnp 2>/dev/null | grep 'users:.*sshd' | awk '{print $4}' | awk -F: '{print $NF}' | sort -u | head -1)
    [[ -n "$port" ]] && { echo "$port"; return; }

    # 2. sshd_config (основной + drop-in'ы)
    port=$(grep -rE "^Port " /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | awk '{print $2}' | head -1)
    [[ -n "$port" ]] && { echo "$port"; return; }

    # 3. По умолчанию
    echo "22"
}

is_port_listening() {
    ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE ":${1}$"
}

# Агрегация пересекающихся CIDR (nftables не терпит overlapping intervals)
merge_v4() {
    aggregate 2>/dev/null
}

merge_v6() {
    # ipaddress.collapse_addresses — убирает пересечения и объединяет смежные
    python3 -c "
import sys, ipaddress
nets = sorted([ipaddress.ip_network(l.strip()) for l in sys.stdin if l.strip()], key=lambda n: n.prefixlen)
for n in ipaddress.collapse_addresses(nets):
    print(n)
" 2>/dev/null || cat
}

# ─── Обновление sets ──────────────────────────────────────────────────────

update_set() {
    local set_name=$1
    local url=$2
    local tmp_file="/tmp/asnl-${set_name}.txt"

    if ! curl -fsSL --connect-timeout 30 --max-time 120 "$url" -o "$tmp_file"; then
        log "ERROR: failed to download $url"
        rm -f "$tmp_file"
        return 1
    fi

    [[ ! -s "$tmp_file" ]] && { log "WARNING: empty file for $set_name"; rm -f "$tmp_file"; return 1; }

    # Агрегация пересекающихся CIDR (nftables не терпит overlapping intervals)
    local merger
    [[ "$set_name" == *v6 ]] && merger="merge_v6" || merger="merge_v4"
    local merged_file="/tmp/asnl-merged-${set_name}.txt"
    sort "$tmp_file" | "$merger" > "$merged_file"
    [[ ! -s "$merged_file" ]] && { log "WARNING: aggregation produced empty result for $set_name"; rm -f "$tmp_file" "$merged_file"; return 1; }

    local count
    count=$(grep -c '.' "$merged_file")

    nft flush set inet filter "$set_name" 2>/dev/null || { log "ERROR: set $set_name not found"; rm -f "$tmp_file" "$merged_file"; return 1; }

    {
        echo "add element inet filter $set_name {"
        paste -sd, "$merged_file"
        echo "}"
    } > /tmp/asnl-load-${set_name}.nft

    if nft -f /tmp/asnl-load-${set_name}.nft; then
        log "OK: $set_name updated ($count entries)"
    else
        log "ERROR: failed to load $set_name"
    fi

    rm -f "$tmp_file" "$merged_file" /tmp/asnl-load-${set_name}.nft
    return 0
}

do_update() {
    if ! is_installed; then
        echo -e "${red}Блокировка не установлена${clear}"
        return 1
    fi

    log "--- Starting update ---"
    local errors=0

    update_set "blacklist_v4" "${BLACKLIST_URL}/blacklist-v4.txt" || ((errors++))
    update_set "blacklist_v6" "${BLACKLIST_URL}/blacklist-v6.txt" || ((errors++))

    log "--- Update complete (errors: $errors) ---"

    if [[ $errors -eq 0 ]]; then
        echo -e "${green}Списки обновлены${clear}"
    else
        echo -e "${red}Обновление завершено с ошибками ($errors). Смотрите $LOG_FILE${clear}"
    fi
}

# ─── Install ──────────────────────────────────────────────────────────────

do_install() {
    if is_installed; then
        echo -e "${red}Блокировка уже установлена${clear}"
        echo -e "Используйте пункт 2 для обновления списков"
        return
    fi

    echo ""
    echo -e "${textcolor}Установка блокировки сетей обнаружения${clear}"
    echo -e "Данные: C24Be/AS_Network_List (1146+ IPv4, 22+ IPv6 подсетей)"
    echo ""

    # Создать nftables конфигурацию если таблицы нет
    if ! nft list table inet filter &>/dev/null; then
        echo -e "${textcolor}Создаю базовую конфигурацию nftables...${clear}"

        # Определить порты
        local ssh_port
        ssh_port=$(get_ssh_port)

        # Собрать правила для разрешённых сервисов (только реально слушающие)
        local allow_rules
        allow_rules="        tcp dport ${ssh_port} accept"
        if is_port_listening 80; then
            allow_rules="${allow_rules}
        tcp dport 80 accept"
        fi
        if is_port_listening 443; then
            allow_rules="${allow_rules}
        tcp dport 443 accept"
        fi

        cat > "$NFT_CONF" <<NFTCONF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        ct state established,related accept
        iif lo accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        # Блокировка сетей обнаружения
        ip saddr @blacklist_v4 counter drop
        ip6 saddr @blacklist_v6 counter drop

        # Разрешённые сервисы
${allow_rules}
    }

    chain forward {
        type filter hook forward priority 0; policy accept;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }

    set blacklist_v4 {
        type ipv4_addr
        flags interval
    }

    set blacklist_v6 {
        type ipv6_addr
        flags interval
    }
}
NFTCONF

        systemctl enable nftables
        systemctl restart nftables
        local opened="SSH:${ssh_port}"
        is_port_listening 80  && opened="${opened}, HTTP:80"
        is_port_listening 443 && opened="${opened}, HTTPS:443"
        echo -e "${green}nftables настроен (разрешены: ${opened})${clear}"
    else
        # Таблица существует — добавить sets и правила
        echo -e "${textcolor}Добавляю sets в существующую конфигурацию nftables...${clear}"

        if ! nft list set inet filter blacklist_v4 &>/dev/null; then
            nft add set inet filter blacklist_v4 '{ type ipv4_addr; flags interval; }'
        fi
        if ! nft list set inet filter blacklist_v6 &>/dev/null; then
            nft add set inet filter blacklist_v6 '{ type ipv6_addr; flags interval; }'
        fi

        # Вставить правила после ct state established (перед accept правилами)
        local handle
        handle=$(nft -a list chain inet filter input 2>/dev/null | grep "ct state" | tail -1 | awk '{print $NF}')
        if [[ -n $handle ]]; then
            nft insert rule inet filter input position "$handle" ip saddr @blacklist_v4 counter drop 2>/dev/null
            nft insert rule inet filter input position "$handle" ip6 saddr @blacklist_v6 counter drop 2>/dev/null
        else
            # Fallback — добавить в начало цепочки
            nft add rule inet filter input ip saddr @blacklist_v4 counter drop 2>/dev/null
            nft add rule inet filter input ip6 saddr @blacklist_v6 counter drop 2>/dev/null
        fi
        echo -e "${green}Sets и правила добавлены${clear}"
    fi

    # Скачать списки
    echo -e "${textcolor}Загрузка списков блокировки...${clear}"
    log "--- Initial install ---"
    update_set "blacklist_v4" "${BLACKLIST_URL}/blacklist-v4.txt"
    update_set "blacklist_v6" "${BLACKLIST_URL}/blacklist-v6.txt"
    log "--- Install complete ---"

    local counts
    counts=$(get_counts)
    local v4_count=${counts%% *}
    local v6_count=${counts##* }

    echo ""
    echo -e "${green}Блокировка установлена${clear}"
    echo -e "  IPv4 подсетей: ${v4_count}"
    echo -e "  IPv6 подсетей: ${v6_count}"

    # Предложить автообновление
    echo ""
    echo -e "${textcolor}[?]${clear} Настроить автоматическое ежедневное обновление списков?"
    echo "1 - Да (cron, ежедневно в 04:30)"
    echo "2 - Нет"
    read -r cron_choice
    [[ -n $cron_choice ]] && echo ""

    if [[ "$cron_choice" != "2" ]]; then
        setup_cron
    fi

    echo ""
}

setup_cron() {
    # Установить скрипт в систему
    local script_path="/usr/local/bin/asnl-block-update"
    cp -f "$0" "$script_path"
    chmod +x "$script_path"

    # Добавить в crontab
    (crontab -l 2>/dev/null | grep -v "$CRON_MARKER"; echo "30 4 * * * ${script_path} --update #$CRON_MARKER") | crontab -

    echo -e "${green}Автообновление настроено (ежедневно 04:30)${clear}"
}

remove_cron() {
    crontab -l 2>/dev/null | grep -v "$CRON_MARKER" | crontab -
    rm -f /usr/local/bin/asnl-block-update
    echo -e "${green}Автообновление удалено${clear}"
}

# ─── Delete ────────────────────────────────────────────────────────────────

do_delete() {
    if ! is_installed; then
        echo -e "${red}Блокировка не установлена${clear}"
        return
    fi

    echo ""
    echo -e "${red}ВНИМАНИЕ!${clear} Это удалит блокировку сетей обнаружения и все связанные списки"
    echo -e "${textcolor}[?]${clear} Вы уверены?"
    echo "1 - Да, удалить"
    echo "2 - Нет, отмена"
    read -r del_choice
    [[ -n $del_choice ]] && echo ""

    if [[ "$del_choice" != "1" ]]; then
        echo "Отмена"
        return
    fi

    # Удалить правила из цепочки
    nft delete rule inet filter input handle $(nft -a list chain inet filter input 2>/dev/null | grep "@blacklist_v4" | awk '{print $NF}') 2>/dev/null
    nft delete rule inet filter input handle $(nft -a list chain inet filter input 2>/dev/null | grep "@blacklist_v6" | awk '{print $NF}') 2>/dev/null

    # Удалить sets
    nft delete set inet filter blacklist_v4 2>/dev/null
    nft delete set inet filter blacklist_v6 2>/dev/null

    # Удалить cron
    remove_cron 2>/dev/null

    # Удалить лог
    rm -f "$LOG_FILE"

    echo -e "${green}Блокировка удалена${clear}"
    echo ""
}

# ─── Status ───────────────────────────────────────────────────────────────

show_status() {
    echo ""
    echo -e "${textcolor}Статус блокировки:${clear}"
    echo ""

    if ! is_installed; then
        echo -e "  Состояние: ${red}не установлена${clear}"
        echo ""
        return
    fi

    local counts
    counts=$(get_counts)
    local v4_count=${counts%% *}
    local v6_count=${counts##* }
    local last_update
    last_update=$(get_last_update)
    local cron_status
    if is_cron_enabled; then cron_status="${green}включено${clear}"; else cron_status="${grey}выключено${clear}"; fi

    echo -e "  Состояние:       ${green}установлена${clear}"
    echo -e "  IPv4 подсетей:   ${v4_count}"
    echo -e "  IPv6 подсетей:   ${v6_count}"
    echo -e "  Последнее обновление: ${last_update}"
    echo -e "  Автообновление:  ${cron_status}"

    # Счётчики заблокированных
    local blocked_v4 blocked_v6
    blocked_v4=$(nft list chain inet filter input 2>/dev/null | grep "@blacklist_v4" | grep -o 'packets [0-9]*' | head -1 | awk '{print $2}')
    blocked_v6=$(nft list chain inet filter input 2>/dev/null | grep "@blacklist_v6" | grep -o 'packets [0-9]*' | head -1 | awk '{print $2}')
    [[ -n $blocked_v4 ]] && echo -e "  Заблокировано (IPv4): ${blocked_v4} пакетов"
    [[ -n $blocked_v6 ]] && echo -e "  Заблокировано (IPv6): ${blocked_v6} пакетов"

    echo ""
}

# ─── Меню ─────────────────────────────────────────────────────────────────

show_banner() {
    echo ""
    echo -e "  ${textcolor}AS Network List Block${clear} ${grey}v${version}${clear}"
    echo -e "  ${grey}Блокировка сетей обнаружения через nftables${clear}"
    echo ""
}

show_menu() {
    echo -e "${textcolor}Выберите действие:${clear}"
    echo "1 - Установить блокировку"
    echo "2 - Обновить списки"
    echo "3 - Удалить блокировку"
    echo "4 - Статус"
    echo "0 - Выход"
    echo ""
    read -r choice
    [[ -n $choice ]] && echo ""
}

main() {
    check_root
    check_deps

    # CLI mode: --update for cron
    if [[ "$1" == "--update" ]]; then
        do_update
        exit $?
    fi

    while true; do
        show_banner
        show_status
        show_menu

        case $choice in
            1) do_install ;;
            2) do_update ;;
            3) do_delete ;;
            4) show_status ;;
            0) exit 0 ;;
            *) exit 0 ;;
        esac

        echo -e "${textcolor}Нажмите Enter для продолжения...${clear}"
        read -r
    done
}

main "$@"
