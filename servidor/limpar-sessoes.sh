#!/usr/bin/env bash
# limpar-sessoes.sh — higiene: revoga chaves com mais de 2h (sessao baixada
# e nunca usada, por exemplo) e apaga pastas de sessao com mais de 24h.
# Chamado pelo web.py a cada download.
set -euo pipefail
BASE=$(cd "$(dirname "$0")" && pwd)
AK=/home/suporte/.ssh/authorized_keys
LIMITE=$(date -d '2 hours ago' +%Y%m%d-%H%M%S)

if [ -f "$AK" ]; then
    while read -r linha; do
        case "$linha" in
            *sessao:*)
                # extrai "20261026-195303-6b78" do comentario da chave
                ID=$(printf '%s' "$linha" | sed 's/.*sessao:\([^:]*\):.*/\1/')
                TS=$(printf '%s' "$ID" | cut -d- -f1,2)
                if [[ "$TS" < "$LIMITE" ]]; then
                    "$BASE/encerrar-sessao.sh" "$ID" >/dev/null
                fi
                ;;
        esac
    done < "$AK"
fi

find "$BASE/sessoes" -maxdepth 1 -type d -name '20*' -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
