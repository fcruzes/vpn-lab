# vpn-lab

Laboratório de VPN com WireGuard: servidor Linux, NAT com nftables, kill switch, prevenção de DNS leak e diagnóstico de MTU no 4G.

## O problema

"A VPN conecta, mas no 4G as páginas não carregam; no Wi-Fi funciona." É uma das reclamações mais comuns de um produto VPN, e as causas (MTU, DNS, IPv6, NAT da operadora) só ficam claras quando se vê cada uma quebrar. Este lab monta uma VPN do zero, provoca essas falhas de propósito, mede e corrige, com comando e saída como prova.

## Resumo em 30 segundos

- **MTU no 4G, reproduzido com números da operadora:** o caminho móvel aceitava no máximo 1376 bytes dentro do túnel, o túnel estava em 1420, e os pacotes grandes sumiam sem aviso (buraco negro de PMTU). Corrigido com MSS clamping no servidor + MTU conservador no celular.
- **"Conecta mas não carrega" tinha duas causas sobrepostas:** além do MTU, a CDN de um portal bloqueava o IP de data center da VPN (14 de 15 imagens com HTTP 403; 15 de 15 com 200 a partir de IP residencial).
- **O kill switch "derrubou a internet", mas o culpado era o DNS:** o cliente herdava o resolver da operadora, que não responde a quem chega pela VPN.
- **O próprio firewall do lab tirou o IPv6 do servidor:** o conntrack não reconhece a resposta DHCPv6 a um pedido multicast. Achado com `tcpdump`, depois de uma hipótese errada.
- **Medição:** +6 ms de latência; o download com VPN (~46 Mbit/s) ficou colado no teto de banda da VM gratuita (~48 Mbit/s), com a CPU 95% ociosa: no download, o WireGuard não era o gargalo. O upload com VPN (~34) ficou abaixo do esperado, sem causa confirmada.
- **Custo:** R$ 0 (Oracle Cloud Always Free).

> Endereços neste documento usam faixas reservadas para documentação (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`, `2001:db8::/32`). Nenhuma chave, IP real ou configuração de cliente é versionada.

## Estrutura do repositório

```
server/nftables.conf                       firewall final: NAT44/NAT66, DHCPv6, MSS clamping (comentado)
server/sshd_config.d/00-hardening.conf     SSH só por chave, root bloqueado
server/sysctl.d/99-vpn-forwarding.conf     forwarding IPv4/IPv6
examples/wg0.conf.example                  servidor WireGuard (chave privada lida de arquivo no PostUp)
examples/pc-windows.conf.example           cliente Windows com kill switch e DNS no túnel
examples/celular.conf.example              cliente iOS (QR code), MTU automático
scripts/mtu-probe.sh                       acha o MTU efetivo até um cliente por busca binária com ping DF
LICENSE                                    MIT
```

Chaves, IPs reais e configs de cliente nunca entram no git (`.gitignore` desde o primeiro commit; os `.conf` do servidor são liberados um a um).

### `scripts/mtu-probe.sh`

Automatiza o diagnóstico do "conecta mas não carrega". Rodando no servidor contra o IP de um cliente dentro do túnel, diz o maior pacote que chega a ele na rede em que está agora:

```
$ ./mtu-probe.sh 1.1.1.1 1280 9000
destino: 1.1.1.1 (IPv4), testando entre 1280 e 9000 bytes...
maior pacote que passa sem fragmentar: 1500 bytes
primeiro tamanho que falha:            1501 bytes
MSS TCP que cabe (IPv4):              1460 bytes
...
dele comporta 1440 (transporte IPv4) ou 1420 (transporte IPv6).

$ ./mtu-probe.sh 10.66.66.3        # cliente desligado
nem 1280 bytes passam: destino fora do ar, ICMP bloqueado ou caminho menor que 1280.
```

Contra o celular no 4G, o mesmo método achou 1376 (seção de MTU abaixo).

## Arquitetura

```
 Celular (4G / Wi-Fi) ─┐
                       ├── UDP 51820 ──► Oracle Cloud, São Paulo ──► Internet
 PC Windows ───────────┘                 VM Ubuntu 24.04 (E2.1.Micro, Always Free)
                                         IPv4: privado 10.0.0.0/24 + IP público via NAT 1:1 da Oracle
                                         IPv6: /64 público direto na interface (sem NAT)
```

Dois firewalls em camadas: a **security list** da VCN (nuvem) e o **nftables** do host.

## Decisões

| Decisão | Por quê |
|---|---|
| Oracle Cloud Always Free, região São Paulo | Custo zero e ~15 ms de Curitiba; servidor longe esconderia o overhead do túnel atrás da latência geográfica |
| VCN criada antes da VM, com IPv6 (/56 da Oracle, /64 na sub-rede pública) | Entender cada peça (sub-rede, internet gateway, rota) em vez de deixar o assistente esconder |
| Chave SSH ed25519 gerada no PC, só a pública vai para a nuvem | Quem gera a chave privada deve ser o único a possuí-la |
| `PermitRootLogin no` em `sshd_config.d/00-hardening.conf` | No sshd o **primeiro** valor lido vence; `00-` garante precedência sobre o `50-cloud-init.conf` |
| `table inet filter` no nftables, `policy drop` em input e forward | Uma tabela para IPv4 e IPv6; lista de permissão, não de bloqueio |
| ICMP e ICMPv6 liberados | Sem ICMPv6 não há Neighbor Discovery nem "Packet Too Big", e o Path MTU Discovery quebra |
| Regra explícita para respostas DHCPv6 (`ip6 saddr fe80::/10 udp sport 547 udp dport 546`) | O conntrack não associa a resposta unicast ao pedido enviado em multicast; sem a regra, o servidor perde o IPv6 quando o aluguel vence |
| WireGuard com `MTU = 1420` fixo no servidor | A placa da Oracle usa MTU 9000 (jumbo frames); no automático o `wg-quick` calcularia 8920, irreal para a internet |
| Clientes em `10.66.66.0/24` + ULA `fd66:66:66::/64` com NAT66 | Não colide com a VCN nem com redes domésticas; garante que o IPv6 do cliente sai pelo túnel sem rotear um /64 público até a VM |
| `AllowedIPs = 0.0.0.0/0, ::/0` no cliente | Sem o `::/0`, a VPN mostra "conectado" e o IPv6 vaza pela operadora |
| PC gera a própria chave; celular recebe chave gerada no servidor via QR, e a cópia é apagada depois | No PC, a privada nunca sai do aparelho. No celular, o QR é o padrão de mercado pela praticidade, com custo: a privada existiu em disco no servidor e passou pelo terminal SSH (scrollback). `rm` em disco de nuvem não garante apagamento físico. A alternativa mais segura é gerar o par no próprio app iOS e cadastrar só a pública |
| Forward só `wg0 → ens3`, com bloqueio de redes privadas e do metadata (`169.254.0.0/16`) | Cliente da VPN sai para a internet, não para dentro da nuvem: sem isso ele alcançaria a VCN e o serviço de metadados da instância |
| SSH com `AllowUsers`, `AuthenticationMethods publickey` e limite de conexões novas por origem no nftables | O usuário padrão da imagem tem sudo sem senha, então a chave SSH é a única barreira do host; o limite por origem só poupa CPU e log contra robôs |
| Novo peer adicionado com `wg set` + arquivo, sem reiniciar o serviço | Reiniciar o `wg-quick` derrubaria o túnel dos clientes já conectados |
| Security list da Oracle: UDP 51820 de `0.0.0.0/0` e `::/0`, stateful | Celular muda de IP o tempo todo; quem protege é a chave do WireGuard, que não responde a quem não a tem |
| Timer de rollback (`systemd-run --on-active=180 nft flush ruleset`) ao aplicar firewall remoto | Mudar firewall por SSH sem rede de segurança é como se tranca o próprio acesso |

## Testes com prova

### SSH: root bloqueado, senha desligada

```
$ sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication) '
permitrootlogin no
passwordauthentication no

$ ssh root@203.0.113.10
root@203.0.113.10: Permission denied (publickey).
```

Minutos depois de subir, o log já mostrava robôs tentando usuários inventados, o motivo de não existir login por senha:

```
sshd: Connection closed by invalid user sol 192.0.2.50 port 60946 [preauth]
```

### Firewall: só a nossa tabela, servidor sai por IPv4 e IPv6

```
$ sudo nft list tables
table inet filter
$ curl -4 ... https://ubuntu.com   -> IPv4 HTTP 200
$ curl -6 ... https://ubuntu.com   -> IPv6 HTTP 200
```

### WireGuard: PC Windows sai pelo servidor em IPv4 e IPv6

```
# no PC, sem VPN
$ curl -4 ifconfig.me  ->  198.51.100.20        (IP de casa)
$ curl -6 ifconfig.me  ->  2001:db8:aaaa::20    (IPv6 de casa)

# no PC, com VPN
$ curl -4 ifconfig.me  ->  203.0.113.10         (IP do servidor)
$ curl -6 ifconfig.me  ->  2001:db8:bbbb::10    (IPv6 do servidor, via NAT66)

# no servidor
$ sudo wg show
peer: <chave pública do PC>
  endpoint: 198.51.100.20:1137        <- porta reescrita pelo NAT de casa
  allowed ips: 10.66.66.2/32, fd66:66:66::2/128
  latest handshake: 11 seconds ago
  transfer: 37.36 KiB received, 56.37 KiB sent
```

### Kill switch (WireGuard para Windows, "Bloquear tráfego fora do túnel")

Teste de fuga: um programa pedindo para sair direto pela placa Wi-Fi, com a VPN ativa.

```
# kill switch DESLIGADO (o app grava AllowedIPs como 0.0.0.0/1 + 128.0.0.0/1)
$ curl -4 --interface 192.168.1.20 https://ifconfig.me   ->  198.51.100.20   (IP de casa: vazou)

# kill switch LIGADO (AllowedIPs 0.0.0.0/0, ::/0 + regras na Windows Filtering Platform)
$ curl -4 --interface 192.168.1.20 https://ifconfig.me   ->  BLOQUEADO
```

Teste de queda do servidor, com religamento agendado antes (`systemd-run --on-active`):

```
18:53:48  servidor: systemctl stop wg-quick@wg0
          PC: curl -4 ifconfig.me  -> sem saída (não voltou a sair por casa)
          PC: curl -6 ifconfig.me  -> sem saída
          PC: curl --interface <Wi-Fi> -> BLOQUEADO
18:54:45  servidor: wg-quick@wg0 de volta
18:54:59  PC navegando pela VPN de novo (~14 s, sem intervenção); celular também
```

### DNS dentro do túnel

```
# Resolver da operadora consultado a partir do servidor
$ dig @<DNS da operadora> example.com   ->  timed out
# Cloudflare a partir do servidor
$ dig @1.1.1.1 example.com              ->  172.66.147.243 ...

# PC com DNS = 1.1.1.1, 2606:4700:4700::1111 no túnel
$ nslookup example.com
Servidor:  one.one.one.one
Address:   2606:4700:4700::1111
```

### MTU no 4G: "conecta mas não carrega", reproduzido e corrigido

Método: ping "não fragmente" (`ping -M do -s <payload>`) do servidor até o IP do celular **dentro do túnel**, aumentando o tamanho até achar o corte. Pacote interno = payload + 28; pacote externo (WireGuard sobre IPv4) = interno + 60.

| Cenário | Maior pacote interno que passa | Conclusão |
|---|---|---|
| iPhone, MTU automático, 4G | 1280 | corte redondo demais para ser a rede |
| iPhone, MTU automático, **Wi-Fi** | 1280 | igual no Wi-Fi → o limite é o próprio app |
| iPhone, MTU 1420, Wi-Fi | 1420 | caminho de casa aguenta o túnel inteiro |
| iPhone, MTU 1420, **4G** | **1376** (externo 1436) | **limite real do 4G da operadora** |

O 1280 vem do app oficial para iOS ([código-fonte](https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardKit/PacketTunnelSettingsGenerator.swift)): em "automático" ele fixa 1280 de propósito, com o comentário *"in practice there are too many broken networks out there. Instead set it to 1280. Boohoo."*

Com MTU 1420 no 4G, o sintoma apareceu: página do portal de notícias abrindo pela metade. Nenhum ICMP "fragmentation needed" voltou ao servidor pela placa da nuvem (`tcpdump -i ens3 'icmp[icmptype]==3 and icmp[icmpcode]==4'` → 0 pacotes). O experimento mostra o efeito, não o mecanismo exato dentro da operadora: o pacote externo grande some sem aviso, seja descartado por tamanho, seja fragmentado e com os fragmentos perdidos no caminho (CGNAT costuma descartar fragmentos). Para quem está nas pontas, o resultado é o mesmo de um **buraco negro de PMTU**. Captura no `wg0` durante o carregamento:

```
SYN do celular:                          79 x "mss 1380"   (1420 - 40)
pacotes servidor -> celular <= 1376:     1488
pacotes servidor -> celular  > 1376:     2222              (não cabem no 4G)
```

Correção em duas camadas:

1. **MSS clamping no servidor** (só TCP, vale para todos os clientes sem tocar no aparelho):
   ```
   iifname "wg0" tcp flags & syn == syn tcp option maxseg size > 1316 tcp option maxseg size set 1316
   oifname "wg0" tcp flags & syn == syn tcp option maxseg size > 1316 tcp option maxseg size set 1316
   ```
   1316 = 1376 medido − 60 (IPv6 + TCP), serve para IPv4 e IPv6. Prova: SYN do celular com `mss 1380`, SYN-ACK entregue a ele com `mss 1316`.
2. **MTU conservador no cliente móvel** (cobre também UDP: QUIC, chamadas, jogos): voltar o iPhone ao automático (1280).

### Imagens com "?" no portal: não era a rede, era reputação de IP

Depois da correção de MTU o texto carregava, mas parte das imagens aparecia como "?". Teste das mesmas 15 URLs do host de imagens, a partir de cada saída:

```
saída pela VPN (IP de data center):   14 x HTTP 403 "Access Denied" (errors.edgesuite.net, Akamai)   1 x 200
saída por casa (IP residencial):      15 x HTTP 200
```

A CDN do portal recusa IP de data center. Não se resolve com configuração de rede; em produto se resolve com reputação e rotação de IPs de saída e monitoramento dos grandes sites que bloqueiam a frota.

### Reboot: tudo volta sozinho

```
$ sudo systemctl reboot        # depois de 17 h no ar
$ systemctl is-enabled nftables wg-quick@wg0 netfilter-persistent
enabled / enabled / disabled
$ sudo nft list tables                       -> table inet filter, table inet nat
$ nft list chain inet filter forward         -> 2 regras de MSS clamping
$ sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding   -> 1 / 1
$ ip -6 addr show ens3 scope global          -> 1 endereço global (DHCPv6 ok)
$ curl -4 / curl -6 https://ubuntu.com       -> HTTP 200 / HTTP 200
$ sudo wg show                               -> listening port 51820, 2 peers, mtu 1420
```

## Medição: com e sem túnel

PC Windows em Wi-Fi residencial (Curitiba), servidor em São Paulo. Latência: `ping -n 20 1.1.1.1`. Throughput: `curl` contra `speed.cloudflare.com` (download 50 MB, upload 20 MB, 3 rodadas). No download sem VPN a primeira rodada (104 Mbit/s) ficou fora da média por destoar das outras duas (226 e 219); com VPN as três rodadas foram estáveis (46, 46, 45) e todas entraram. Uma única sessão de medição, num domingo à tarde: é ordem de grandeza, não benchmark.

| | Sem VPN | Com VPN | Diferença |
|---|---|---|---|
| Latência média até 1.1.1.1 | 16 ms | 22 ms | +6 ms |
| Download | ~220 Mbit/s | ~46 Mbit/s | −79% |
| Upload | ~52 Mbit/s | ~34 Mbit/s | −35% |
| Servidor sozinho, sem túnel (teto do provedor) | download ~48 Mbit/s, upload ~48–55 Mbit/s | | |
| CPU do servidor durante download pela VPN | | 94–96% ociosa, steal 0 | |

Leitura: no download, o overhead do WireGuard é pequeno (46 vs ~48 Mbit/s no teto do servidor), e o gargalo é a banda de internet da VM gratuita, apesar de o console anunciar 0,48 Gbps. **O upload não fecha:** 34 Mbit/s com VPN ficou abaixo tanto do upload de casa (~52) quanto do teto do servidor (~48–55), e a causa não foi confirmada nesta rodada. A primeira hipótese (CPU "burstable" insuficiente para a criptografia) caiu com o `vmstat`. Implicação de produto: banda por PoP e tipo de instância são decisão de custo, não detalhe de infraestrutura.

## O que quebrou (e como resolvemos)

1. **A imagem Ubuntu da Oracle vem com firewall próprio que mataria a VPN.** Regras iptables (via `iptables-nft`) aceitavam só SSH e ICMP no INPUT e tinham `reject with icmp type host-prohibited` no **FORWARD**. Um servidor VPN existe para encaminhar pacotes: o túnel subiria e nada navegaria. Resolução: substituímos tudo por um ruleset nftables próprio (`flush ruleset` + `table inet filter`). O original ficou salvo para comparação.
2. **O firewall novo sumiria no reboot.** `netfilter-persistent` estava habilitado e recarregaria `/etc/iptables/rules.v4` da Oracle no boot; `nftables.service` estava desabilitado. Resolução: `systemctl disable netfilter-persistent && systemctl enable nftables`.
3. **O servidor perdeu o IPv6 depois que trocamos o firewall.** Sintoma: `curl -6` voltando `000`; a rota padrão IPv6 existia e o gateway respondia ping, mas a interface só tinha endereço `fe80::`. Primeira hipótese (errada): ligar o forwarding faz o `systemd-networkd` parar de aceitar Router Advertisements. É verdade segundo o manual, mas a rota estava lá. O `tcpdump` mostrou a causa real:

   ```
   IP6 fe80::<servidor>.546 > ff02::1:2.547: dhcp6 solicit
   IP6 fe80::<gateway>.547 > fe80::<servidor>.546: dhcp6 reply
   ```

   A resposta chegava na placa e o nosso `policy drop` a descartava: o pedido sai para um endereço multicast e a resposta volta de um unicast, então o conntrack a marca como `new`, não como `established`. O IPv6 já estava condenado desde a troca do firewall; o reload só antecipou a queda, que viria quando o aluguel DHCPv6 (1 dia) vencesse. Resolução: aceitar UDP 547→546 vindo de `fe80::/10`. Lição: hipótese plausível não é diagnóstico; o pacote na interface é.
4. **Liguei o kill switch e "a internet caiu" — mas não era o kill switch, era o DNS.** O cliente do PC não definia DNS e herdava o resolver da operadora. Pelo túnel, a consulta chega à operadora vindo do IP da Oracle, e resolvers de operadora só atendem a própria rede. A captura no `wg0` mostrou o PC repetindo a mesma pergunta a cada 2 s, sem resposta. Sem kill switch o problema ficava escondido (navegadores com DNS próprio e outros caminhos); o kill switch fechou as saídas e expôs a dependência. Resolução: `DNS = 1.1.1.1, 2606:4700:4700::1111` no cliente. Lição de produto: cliente VPN que não define o próprio DNS ou quebra ou vaza.
5. **Meu primeiro teste de queda do servidor mediu a coisa errada.** A sessão SSH de controle passava pelo túnel, congelou junto com o WireGuard, e o `curl` só rodou depois do religamento. Refeito agendando queda e religamento no servidor (`systemd-run`) antes de sair, e testando só depois.
6. **"Conecta mas não carrega" no 4G tinha duas causas sobrepostas.** (a) MTU: túnel em 1420, caminho do 4G aceitando no máximo 1376 internos, sem ICMP de volta; resolvido com MSS clamping + MTU 1280 no móvel. (b) Imagens bloqueadas pela CDN por o IP ser de data center. Minha hipótese intermediária (imagens vindo por QUIC/UDP, imunes ao clamping) caiu quando o MTU 1280 não mudou nada; e minha primeira conclusão sobre o 403 veio de uma única URL, um ícone. Só a amostra de 15 URLs com controle residencial fechou o diagnóstico.
7. **Um ajuste de rede "preventivo" que nunca foi necessário.** No meio do problema do IPv6, criei um drop-in do `systemd-networkd` forçando `IPv6AcceptRA=yes`, por ter lido no manual que o RA é desligado quando há forwarding. A gravação do arquivo falhou (ficou com 0 bytes) e ninguém percebeu; depois do reboot, com forwarding ligado, a rota `proto ra` estava lá. O ajuste era desnecessário e foi removido. Lição: o teste de reboot serve também para descobrir o que sobra.
8. **SSH caindo por inatividade.** A sessão parada era derrubada no caminho (timeout de NAT). Resolução: `ServerAliveInterval 30` no `~/.ssh/config` do cliente. É o mesmo problema que o `PersistentKeepalive` do WireGuard resolve.

## Revisão independente

Antes da publicação, o repositório passou por uma revisão cega (um revisor sem acesso ao contexto, só ao disco e ao histórico git), com foco em segurança e boas práticas. Nenhum segredo foi encontrado. O que ela apontou e foi corrigido:

- **IP da rede doméstica no histórico:** um IP de LAN real tinha ficado no primeiro commit, embora já trocado no seguinte. O histórico foi reescrito antes do primeiro push.
- **Cliente da VPN alcançando a nuvem por dentro:** o forward permitia ao cliente chegar à rede privada da VCN e ao serviço de metadados da instância. Bloqueado no nftables.
- **SSH:** `AllowUsers`, `AuthenticationMethods publickey`, `MaxAuthTries` e limite de conexões novas por origem.
- **`.gitignore`:** padrões para o que as próximas fases vão gerar (chaves de API, `*.tfvars`, capturas `*.pcap`, imagens de QR).
- **`mtu-probe.sh`:** validação de argumentos (inclusive tentativa de injeção via expressão aritmética), `--` antes do destino, erros em stderr; `shellcheck` sem avisos.
- **README:** contradição sobre onde a chave do celular é gerada, upload sem explicação apresentado como se fechasse, afirmação de "no-logs" ampla demais, mecanismo do buraco negro de PMTU afirmado além da evidência e afirmação sobre o iOS sem fonte.

## Cobertura: tópicos de um produto VPN × o que o lab exercitou

| Tópico | Onde aparece neste lab |
|---|---|
| WireGuard, wg-quick, wireguard-go | Servidor com `wg-quick`; o app iOS roda `wireguard-go` dentro de uma NetworkExtension |
| nftables, NAT, roteamento, IPv6 | `table inet` com NAT44 e NAT66, forwarding, DHCPv6 e Router Advertisements |
| MTU | Limite do 4G medido (1376), MSS clamping, MTU 1280 no móvel |
| Kill switch e DNS leak | Teste de fuga pela placa Wi-Fi, queda do servidor, DNS dentro do túnel |
| NetworkExtension (iOS), drivers de túnel no Windows | MTU 1280 decidido no código da NetworkExtension; o cliente Windows atual usa o WireGuardNT (driver de kernel), e não o Wintun, que é a opção em espaço de usuário usada pelo `wireguard-go` |
| Gestão de chaves, secure storage | PC: chave privada gerada no aparelho. Celular: gerada no servidor, entregue por QR e com a cópia apagada (com as limitações da tabela de decisões); config do cliente Windows guardada com DPAPI em `C:\Program Files\WireGuard\Data` ([doc oficial](https://github.com/WireGuard/wireguard-windows/blob/master/docs/attacksurface.md)) |
| Hardening | SSH só por chave, root bloqueado, `policy drop`, firewall de nuvem + host |
| Latência, throughput, custo de banda | Tabela de medição; gargalo no teto de banda da instância, não na criptografia |
| Privacidade / no-logs | O WireGuard em si não grava nada em disco: mantém só último handshake e último endpoint, em memória. O host não é "no-logs" por padrão: conntrack, journald e o log do sshd registram IPs, e uma política de no-logs precisa tratar cada um |
| Provedores e PoPs | Escolha de região por latência; CDN bloqueando IP de data center |

## Próximas fases

- **Provisionamento:** Terraform (rede, instância, security list) + Ansible (hardening, nftables, WireGuard), para subir um servidor novo com um comando. Hoje o lab foi montado à mão de propósito, para entender cada peça.
- **Observabilidade:** Prometheus + Grafana com node exporter e um exporter do WireGuard (handshakes, bytes por peer, peers ativos). Métrica de produto derivada: "conectado mas sem tráfego" por tipo de rede.
- **CI no GitHub Actions:** shellcheck, ansible-lint, terraform validate.
- **Comparativo com OpenVPN:** TCP/UDP, TUN/TAP, custo de CPU, quando ainda faz sentido (redes que só deixam passar TCP 443).
- **Contorno de bloqueio e DPI:** WireGuard tem assinatura fácil de reconhecer e é bloqueado em alguns países. **AmneziaWG** ofusca o handshake do WireGuard; **sing-box** é a plataforma que fala vários protocolos; **VLESS + REALITY** disfarça o túnel de tráfego TLS para um site real; **Hysteria2** usa QUIC e tolera redes com perda. Em produto, o app troca de protocolo quando detecta bloqueio.

## 10 perguntas que este lab responde

1. **A VPN conecta, mas no 4G as páginas não carregam; no Wi-Fi funcionam. Por onde começa?** Pelo que muda entre as redes: o caminho. Aqui o 4G aceitava 1376 bytes dentro do túnel contra 1420 configurados, sem ICMP de volta. MSS clamping no servidor + MTU conservador no móvel. E checar causas sobrepostas: no mesmo sintoma havia uma CDN bloqueando o IP de data center.
2. **O handshake acontece, mas nada navega. O que olhar?** O que vem depois do túnel: forwarding no kernel, regra de forward no firewall e NAT de saída. A imagem da Oracle vinha com `FORWARD reject`, exatamente esse sintoma.
3. **Por que o `AllowedIPs` precisa de `0.0.0.0/0` e `::/0`?** Sem o `::/0`, a VPN mostra "conectado" e o IPv6 sai pela operadora: vazamento silencioso, pior do que não conectar.
4. **Ligar o kill switch derrubou a internet do usuário. É defeito?** Provavelmente não: o kill switch revela dependências. Aqui era o DNS da operadora, que não responde a quem vem pela VPN. O app precisa sempre definir DNS dentro do túnel.
5. **O que é kill switch e por que difere entre Windows e iOS?** "Se o túnel cair, corta, em vez de sair desprotegido." No Windows o app tranca as saídas com a Windows Filtering Platform; no iOS depende do que a NetworkExtension permite. Exemplo documentado: o iOS não encerra conexões abertas antes de a VPN subir, e algumas seguem fora do túnel por minutos ou horas ([Proton VPN, 2020](https://protonvpn.com/blog/apple-ios-vulnerability-disclosure)).
6. **Por que o celular precisa de `PersistentKeepalive`, principalmente no 4G?** Quem escolhe a porta externa é o NAT da operadora (CGNAT), e o mapeamento expira se ficar parado. O keepalive o mantém vivo para o servidor conseguir falar com o celular.
7. **Por que o app iOS do WireGuard usa MTU 1280 no automático?** Decisão de compatibilidade acima de desempenho: 1280 é o mínimo garantido do IPv6 e passa em quase qualquer rede. Medido aqui: com 1420 no 4G, as páginas quebravam.
8. **Com a VPN, um site carrega sem imagens. É a rede?** Nem sempre. Comparar a mesma URL saindo por IP de data center e por IP residencial: aqui deu 403 contra 200. Reputação de IP é problema de produto (rotação, faixas, monitoramento), não de configuração.
9. **A VPN ficou lenta. É o protocolo?** Medir antes de concluir: no download, a CPU estava 95% ociosa e o servidor sozinho já batia no teto de ~48 Mbit/s da instância. Banda por PoP é decisão de custo. E dizer o que a medição não explicou: aqui, a perda no upload.
10. **Como mudar firewall de um servidor remoto sem se trancar para fora?** Validar a sintaxe antes (`nft -c`), agendar rollback automático (`systemd-run --on-active`) e testar uma conexão nova antes de cancelar o rollback.
