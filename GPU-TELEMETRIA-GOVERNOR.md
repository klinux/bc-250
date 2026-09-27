# O unlock de 8 cores quebra a telemetria do SMU — e isso inviabiliza o governor

Medido em 27/set/2026: BC-250, Bazzite Deck 44, kernel 7.2.4, BIOS MeiMeiDXE v3
(8 cores + ACPI Patch), 24 CU, `cyan-skillfish-governor-smu` v0.4.13.

## O sintoma

Depois de habilitar o Core Unlock, a telemetria da GPU passa a reportar lixo:

```
$ cat /sys/class/drm/card*/device/pp_dpm_sclk
0: 1000Mhz
1: 26Mhz *        <- deveria ser 1500Mhz
2: 2000Mhz

$ cat /sys/class/drm/card*/device/gpu_busy_percent
                  <- vazio
```

Antes do unlock, o mesmo comando reportava `1: 1500Mhz *` corretamente.
A causa é conhecida: com 8 cores as arrays do SMU deslocam o campo
`GfxclkFrequency` na tabela de telemetria.

## Por que isso importa: o governor fica cego

O `cyan-skillfish-governor-smu` detecta carga por `method = "busy-flag"`, que lê
justamente `gpu_busy_percent`. Sem esse sinal ele não sobe o clock — e o efeito
na inferência é brutal. Mesmo prompt, mesmo modelo (Qwen3.5-9B Q6_K, 24 CU):

| Configuração | Prompt | Geração |
|---|---|---|
| **Sem governor** | 58,3 tok/s | **33,9 tok/s** |
| Governor, `method = "busy-flag"` | 1,3 | 15,3 |
| Governor, `method = "kernel"` | 0,9 | **5,8** |

6× mais lento no pior caso, e a temperatura subiu a 85 °C.

## Três tentativas de correção, nenhuma funcionou

**1. `SMU Reporting Patch` da BIOS** (`MeiMeiDXEv3SmuPatchVar`) — o mod traz um
driver DXE exatamente pra isso. Não corrigiu: mudou o desalinhamento em vez de
resolver, e **zerou a leitura de potência**, que era a única confiável.

| Leitura | Patch OFF | Patch ON |
|---|---|---|
| `pp_dpm_sclk` | 26-100 MHz ❌ | 6425-6925 MHz ❌ |
| `power1_average` | **65-74 W** ✅ | **0 W** ❌ |
| `gpu_busy_percent` | vazio | vazio |

6900 MHz é fisicamente impossível nessa GPU (teto ~2300 MHz; acima de 2400 o OCP
trava a placa). Conclusão: deixe o patch **desligado** — ao menos a potência funciona.

**2. `fix-freq = true`** no `config.toml` do governor — sem efeito.

**3. `method = "kernel"`** em vez de `busy-flag` — piorou (5,8 tok/s).

## A causa raiz do governor: `mount --bind` em /sys falha

```
Error: Io(Custom { kind: Other, error:
  "mount --bind /dev/shm/patched_gpu_metrics
   /sys/bus/pci/devices/0000:01:00.0/gpu_metrics failed: exit status: 32" })
```

O `fix-metrics = true` funciona fazendo **bind-mount de um `gpu_metrics`
corrigido sobre o do sysfs**. Isso falha nesta máquina (exit 32), então o
governor nunca consegue enxergar as métricas corretas. Suspeita: ostree/SELinux
ou restrição de bind mount sobre `/sys` — não investigado a fundo.

## Cadeia causal

```
unlock de 8 cores
  -> desloca campos na tabela de telemetria do SMU
  -> gpu_busy_percent vazio, pp_dpm_sclk com lixo
  -> governor nao le carga (e o fix-metrics nao consegue montar)
  -> clock nao sobe
  -> inferencia 6x mais lenta
```

## Estado recomendado hoje

**Governor instalado mas `disabled`.** A GPU fica no DPM state 1 sem escalonamento,
o que custa consumo em idle — mas entrega 34 tok/s em vez de 15.

```bash
sudo systemctl disable --now cyan-skillfish-governor-smu
```

O trade-off real, ainda não resolvido: **8 cores** ou **governor funcionando**.
Quem prioriza GPU (jogos, inferência) talvez prefira 6 cores + governor;
quem prioriza CPU fica com 8 cores sem governor.

## Baseline térmico (dissipador stock, aletas fechadas, 2x fan 120 sem shroud)

Sob carga mista (Steam + modelo carregado), **sem throttle ativo**:

| Sensor | Valor | Target |
|---|---|---|
| GPU `edge` | 81 °C | 65-80 °C gaming, máx 90 |
| CPU `Tctl` | 80 °C | 70-85 °C, máx 95 |
| `PPT` | 82 W (média 58,6) | — |
| `vddgfx` | 912 mV | — |
| CPU clock real | **3493 MHz** | — |

> `scaling_max_freq` diz 3200 MHz, mas isso é o P-state base: o boost real chega
> a 3493 MHz com 8 cores. Não confunda um com o outro.

Sem margem para os 40 CU (+30 W / +4 °C pelas medições da comunidade), que
levariam a ~85 °C. Prioridade é o cooling: o dissipador stock foi feito para
fluxo de rack, e fan sem shroud deixa o ar escapar pelas laterais (shroud rende
20-30 °C; endireitar aletas tortas, 5-10 °C).

## Como medir

Use `sensors`, **não** só o `hwmon` do amdgpu:
```bash
sudo sensors | grep -E "edge:|Tctl:|PPT:|vddgfx:"
```
E lembre que `gpu_busy_percent` e `pp_dpm_sclk` **não são confiáveis** com 8
cores — não tire conclusão de performance a partir deles.
