# PRD: "Conectado, mas sem tráfego"

**Status:** rascunho · **Base:** evidências deste lab (ver README)

## Problema

O app mostra "Conectado", mas as páginas não carregam ou carregam pela metade, principalmente em rede móvel. Não aparece erro nenhum: para o usuário, "a VPN não funciona". Hoje não sabemos com que frequência isso acontece, porque o sintoma não gera evento.

## Evidência do lab

- **MTU no 4G:** o caminho móvel aceitou no máximo 1376 bytes dentro do túnel, contra 1420 configurados. Acima disso os pacotes sumiram sem aviso (nenhum ICMP de volta). Ao carregar uma página, 2.222 de 3.710 pacotes enviados ao celular passavam do limite. No Wi-Fi, o mesmo túnel funcionou.
- **DNS herdado da operadora:** o resolver da operadora não responde a quem chega pela VPN. Com kill switch, o usuário fica sem nenhum site; sem ele, o DNS vaza.
- **Causa sobreposta, fora da rede:** a CDN de um portal recusou o IP de data center da VPN (14 de 15 imagens com HTTP 403; 15 de 15 com 200 a partir de IP residencial). Mesmo sintoma, outra causa.

## Objetivo e métrica de sucesso

- **Métrica principal:** % de sessões "conectado sem tráfego": handshake concluído, o cliente envia tráfego, mas recebe menos de 10 KB nos primeiros 60 s. Segmentada por tipo de rede (Wi-Fi ou celular) e por operadora.
- **Primeira entrega:** medir a linha de base por 2 semanas. A meta de redução é definida sobre ela.
- **Métrica de proteção:** throughput médio por sessão não cai mais de 5% após as mudanças de MTU.

## Critérios de aceite

1. O servidor aplica MSS clamping compatível com o menor caminho móvel medido (no lab, 1316 bytes).
2. Em rede celular, o app usa por padrão MTU de no máximo 1280.
3. O app sempre define DNS dentro do túnel. Teste: com kill switch ligado, a resolução de nomes funciona em Wi-Fi e em 4G.
4. O evento "conectado_sem_trafego" é registrado só com tipo de rede, operadora e versão do app. Sem IP, sem domínio, sem identificador de usuário, coerente com a política de no-logs.
5. O suporte tem um roteiro de diagnóstico com o `scripts/mtu-probe.sh` para casos reportados.

## Fora do escopo

- **Bloqueio por reputação de IP** (CDN recusando IP de data center): é outra causa e merece outro PRD (rotação de IPs, faixas, monitoramento de grandes sites).
- **UDP grande que desce para o celular** (QUIC, chamadas): só se resolve baixando o MTU do túnel no servidor, o que afeta todos os usuários. **Decisão: medir antes.** Sem histórico nem risco iminente, não se antecipa um custo que recai sobre todos. Exceção: se não houver janela de correção depois (alocação futura da equipe ou entrega com data fixa que precise provar a solução), a decisão é antecipada, com o trade-off explícito.
- **Ofuscação e bloqueio por país** (AmneziaWG, VLESS + REALITY).
