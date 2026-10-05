#!/usr/bin/env bash
# mtu-probe.sh: descobre o maior pacote que chega a um destino sem fragmentar.
#
# Faz busca binária com ping "não fragmente" (bit DF, ping -M do). Rodando no
# servidor contra o IP de um cliente DENTRO do túnel (ex.: 10.66.66.3), o
# resultado é o MTU efetivo do túnel até aquele cliente, na rede em que ele
# está agora (Wi-Fi, 4G...). É o diagnóstico do "conecta mas não carrega".
#
# Uso: mtu-probe.sh <IP de destino> [mínimo] [máximo]
#   mtu-probe.sh 10.66.66.3
#   mtu-probe.sh fd66:66:66::3 1280 1420
#
# Requer o ping do iputils (Linux). Tamanhos são do pacote IP inteiro.
# Se o resultado for igual ao MTU da interface de saída (1420 no wg0), o
# limite medido é o da própria interface, não o do caminho.

set -euo pipefail

usage() {
    sed -n '2,16p' "$0" | sed -E 's/^# ?//'
    exit "${1:-0}"
}

die() {
    echo "erro: $*" >&2
    echo "uso: $0 <IP de destino> [mínimo] [máximo]   (--help para detalhes)" >&2
    exit 1
}

[[ $# -ge 1 ]] || die "informe o IP de destino"
[[ $1 == -h || $1 == --help ]] && usage 0
[[ $# -le 3 ]] || die "argumentos demais"

target=$1
[[ $target =~ ^[0-9A-Fa-f.:]+$ ]] || die "destino deve ser um endereço IPv4 ou IPv6: '$target'"
if [[ $target == *:* ]]; then
    family=-6; label=IPv6; ip_header=40
else
    family=-4; label=IPv4; ip_header=20
fi
icmp_header=8
tcp_header=20
overhead=$((ip_header + icmp_header))

lo=${2:-1280}   # tamanho que se espera que passe
hi=${3:-1500}   # tamanho máximo a testar
[[ $lo =~ ^[0-9]+$ && $hi =~ ^[0-9]+$ ]] || die "mínimo e máximo devem ser números inteiros"
((lo > overhead)) || die "mínimo precisa ser maior que $overhead (cabeçalhos IP + ICMP)"
((lo < hi)) || die "mínimo ($lo) precisa ser menor que máximo ($hi)"

# Passa se ao menos 1 de 3 pings com DF voltar. Pacote maior que o MTU da
# própria interface falha localmente ("message too long"), o que também conta
# como "não passa".
passes() {
    ping "$family" -c 3 -i 0.2 -W 2 -M "do" -s "$(($1 - overhead))" -- "$target" >/dev/null 2>&1
}

echo "destino: $target ($label), testando entre $lo e $hi bytes..."

if ! passes "$lo"; then
    echo "nem $lo bytes passam: destino fora do ar, ICMP bloqueado ou caminho menor que $lo." >&2
    echo "tente um mínimo menor, por exemplo: $0 $target 576 $lo" >&2
    exit 2
fi
if passes "$hi"; then
    echo "pacotes de $hi bytes passam; o limite é $hi ou maior (aumente o máximo)."
    exit 0
fi

while ((hi - lo > 1)); do
    mid=$(((lo + hi) / 2))
    if passes "$mid"; then lo=$mid; else hi=$mid; fi
done

cat <<EOF
maior pacote que passa sem fragmentar: $lo bytes
primeiro tamanho que falha:            $hi bytes
MSS TCP que cabe ($label):              $((lo - ip_header - tcp_header)) bytes

Se o destino é um IP de DENTRO do túnel, $lo é o MTU efetivo do túnel até ele:
ajuste o MTU do cliente para no máximo $lo, ou faça MSS clamping no servidor.
Se é um endereço da internet, $lo é o MTU do caminho; o WireGuard por cima
dele comporta $((lo - 60)) (transporte IPv4) ou $((lo - 80)) (transporte IPv6).
EOF
