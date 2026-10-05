# PRD: "Conectado, mas sem tráfego"

**Status:** rascunho · **Base:** evidências deste lab (ver README)

## Problema

O app mostra "Conectado", mas as páginas não carregam ou carregam pela metade, principalmente em rede móvel. Não há erro na tela nem evento registrado: não sabemos com que frequência acontece.

## Por que importa

Acontece no momento mais caro, a primeira conexão, e pesa em **ativação**, **cancelamento nos primeiros dias**, **reembolso** e **avaliação na loja**. **Métrica de negócio:** retenção D7 do grupo A contra a do grupo B (ver Lançamento). Por ser um teste sorteado, o resultado mostra causa, e não só correlação.

## Evidência do lab

- **MTU no 4G:** o caminho aceitou no máximo 1376 bytes no túnel, contra 1420 configurados; acima disso, os pacotes sumiram sem aviso (2.222 de 3.710 numa página). No Wi-Fi, funcionou.
- **DNS herdado da operadora:** não responde a quem chega pela VPN. Com kill switch, nada abre; sem ele, o DNS vaza.
- **Causa sobreposta:** a CDN de um portal recusou o IP de data center (14 de 15 imagens com 403; 15 de 15 com 200 por IP residencial).

## Definições e métrica

- **Sessão:** do primeiro handshake depois que o usuário toca em "Conectar" até ele desconectar.
- **Sem tráfego:** nos primeiros 60 s da sessão, o cliente envia ≥ 20 pacotes e recebe < 10 KB. Os 20 pacotes excluem sessões em que só o keepalive trafega.
- **Fonte:** bytes por peer já existem no servidor (`wg show wg0 transfer`, por chave de aparelho, em memória); pacotes são contados no app. Nenhum grava IP ou destino.
- **Métrica principal:** % de sessões sem tráfego, agregada e anônima, por grupo, tipo de rede (Wi-Fi ou celular) e operadora. O grupo B serve de linha de base.

## Critérios de aceite

1. O servidor aplica MSS clamping compatível com o menor caminho medido nas principais operadoras móveis (no lab, numa operadora, 1316 bytes).
2. Em rede celular, o app usa por padrão MTU de no máximo 1280.
3. O app sempre define DNS dentro do túnel. Com kill switch ligado, a resolução de nomes funciona em Wi-Fi e em 4G.
4. O evento "conectado_sem_trafego" leva só grupo (A/B), tipo de rede, operadora e versão do app: sem IP, sem domínio, sem identificador de usuário. Sem exceção.
5. O suporte tem um roteiro de diagnóstico com o `scripts/mtu-probe.sh`.

## Lançamento

Antes de conectar, cada usuário é sorteado, como configuração de produto, para o **grupo A** (servidores com MSS clamping e MTU móvel 1280) ou o **grupo B** (sem as mudanças). O grupo é configuração, não registro de atividade de rede. Entram usuários por **2 semanas**; a D7 do último dia de entrada fecha no dia 21, quando A e B são comparados. **Expande para todos** se, em rede celular, A tiver menos sessões sem tráfego de forma consistente, retenção D7 igual ou maior e throughput médio no máximo 5% abaixo de B (métrica de proteção); se cair mais, reverte.

**Plano B**, se o teste não tiver volume: marcar na conta só "teve sessão sem tráfego na primeira semana: sim/não", sem dado de rede. Antes de ser usado, precisa ser revisado contra a política de no-logs.

## Fora do escopo

- **Bloqueio por reputação de IP:** outra causa, outro PRD.
- **UDP grande que desce para o celular** (QUIC, chamadas): exige baixar o MTU do túnel no servidor, para todos. **Decisão: medir antes.** Sem histórico nem risco iminente, não se antecipa um custo que recai sobre todos; exceção: sem janela de correção depois (alocação da equipe ou entrega com data fixa), antecipa-se com o trade-off explícito.
- **Ofuscação e bloqueio por país** (AmneziaWG, VLESS + REALITY).
