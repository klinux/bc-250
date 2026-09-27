# Unlock 24 → 40 CU no Bazzite, sem patch de kernel

Aplicado e validado em 27/set/2026: BC-250, Bazzite Deck 44, kernel 7.2.4,
8 cores, GTT 12 GiB, dissipador com aletas abertas + 2x fan 120 mm.

## Por que não o patch de kernel

O caminho conhecido (`duggasco/bc250-40cu-unlock`) patcheia o **amdgpu**, que em
ostree vive em `/usr/lib/modules` (read-only) e sobe pelo initramfs. A estratégia
que funciona para um módulo **novo** (como o WiFi AIC8800, carregado de `/var`)
não serve aqui, porque seria **substituir** um módulo do early boot.

Solução: **`WinnieLV/bc250-cu-live-manager`**, que escreve os registradores em
runtime via `umr` e não toca no amdgpu:

- `mmCC_GC_SHADER_ARRAY_CONFIG` → `0xfff80000` (24 CU) vira `0xffe00000` (40 CU)
- `mmSPI_PG_ENABLE_STATIC_WGP_MASK` → `0x07` (WGP0-2) vira `0x1f` (WGP0-4)
- `mmRLC_PG_ALWAYS_ON_WGP_MASK`

## Passos

```bash
curl -sL -o cu.sh https://raw.githubusercontent.com/WinnieLV/bc250-cu-live-manager/refs/heads/main/bc250-cu-live-manager.sh
chmod +x cu.sh
sudo ./cu.sh install-umr      # em ostree: faz layer de umr -> exige reboot
sudo systemctl reboot

sudo ./cu.sh status           # dashboard: WGP por shader array
sudo ./cu.sh --yes enable all # aplica (temporario)
# valida, e so depois:
sudo ./cu.sh --yes write-service-table
sudo ./cu.sh --yes install-service   # systemd oneshot reaplica no boot
```

`--yes` pula o disclaimer interativo (o script fica em loop sem ele e não aplica
nada). Sem `write-service-table` + `install-service`, um reboot volta a 24 CU —
o que é o escape hatch.

## Ganho medido com `llama-bench` (Qwen3.5-9B Q6_K, `-p 512 -n 128 -ngl 99 -r 3`)

| | 24 CU | 40 CU | Ganho |
|---|---|---|---|
| **pp512** (prefill) | 206,14 ± 0,06 | **332,85 ± 0,05** | **+61,5%** |
| **tg128** (geração) | 38,23 ± 0,19 | **46,42 ± 0,09** | **+21,4%** |

Estável em 5 repetições: pp512 332,76 ± 0,06 / tg256 46,47 ± 0,10.
Pelo `llama-server` (KV q8_0, ctx 16k): 42,9 tok/s de geração.

Térmico após o unlock, com as aletas abertas: **edge 58-63 °C, Tctl 63-72 °C,
PPT ~60 W**. Antes do mod de cooling a placa estava em 79-81 °C sob carga — o
unlock ali teria levado a ~85 °C, que é onde o throttle começa. **Faça o cooling
antes.**

## Use llama-bench, não o servidor, para medir

Medir pelo `llama-server` deu números erráticos (19 a 35 tok/s) e me levou a
conclusões erradas duas vezes. Duas causas:

- **contexto acumulado no slot**: cada requisição soma ao `n_past` e a geração
  desacelera. `cache_prompt: false` **não** zera isso — é preciso
  `POST /slots/0?action=erase` entre medições.
- **cache de prompt**: repetir o mesmo prompt faz o prefill medir 4 tokens em vez
  de 1900, inflando o resultado.

`llama-bench` controla as duas coisas e entrega desvio de ±0,06.

## Validação de saúde dos CUs

Os 16 CU liberados podem ser defeituosos (loteria de silício). Como conferir:

1. **Benchmark estável** — desvio baixo em várias repetições (±0,06 aqui).
2. **`dmesg` limpo** — sem `ring timeout`, `GPU reset`, `page fault` **após** o
   unlock. Atenção: a BC-250 sempre loga erros de display no boot
   (`dal_irq_service_dummy_set`, `Failed to clear hpd(rx)`, `Unsupported clock
   type`) — são benignos, confira o timestamp antes de se assustar.
3. **Correção computacional** — peça algo verificável ao modelo (ex.: primos até
   50). Corrupção de compute aparece como texto quebrado ou resultado errado.
4. **Artefato visual** (pontos verdes) é o sintoma clássico — exige olhar a tela.
   Mesmo sintoma de GDDR6 superaquecida, então resolva o cooling do backplate
   antes para não confundir as duas causas.

CU ruim se mascara individualmente: `sudo ./cu.sh disable-wgp SE.SH.WGP`
(ex.: `1.0.4`). Um WGP são 2 CUs; não há controle de CU individual.

## O driver continua reportando 24 — e isso é esperado

```
amdgpu : active_cu_number=24
RADV   : num_cu = 24
```

O amdgpu enumera a topologia no boot e não re-enumera. O que importa é o
roteamento do SPI, que o dashboard mostra como `S+`:

```
| Row     | WGP0 | WGP1 | WGP2 | WGP3 | WGP4 | SPI  | CC         | CUs   |
| SE0.SH0 |  D+  |  D+  |  D+  |  S+  |  S+  | 0x1f | 0xffe00000 | 10/10 |
```

`D+` = conhecido pelo driver e roteado; `S+` = roteado só via SPI. O hardware
despacha waves para os `S+` de qualquer forma — os +61,5% de prefill provam isso.

## Reverter

```bash
sudo ./cu.sh --yes stock-dispatch    # volta a 24 CU agora
sudo ./cu.sh uninstall-service       # remove a persistencia
```
Corte de energia também volta ao estoque.
