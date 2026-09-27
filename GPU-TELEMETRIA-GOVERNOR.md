# Governor de GPU na BC-250: o que quebra, o que não, e um erro meu

Medido em 27/set/2026: BC-250, Bazzite Deck 44, kernel 7.2.4, BIOS MeiMeiDXE v3
(8 cores + ACPI Patch), 40 CU, `cyan-skillfish-governor-smu` v0.4.13.

## Conclusão primeiro

**O governor funciona com 8 cores ativos.** Se você leu em algum lugar (inclusive
numa versão anterior deste arquivo) que o unlock de 8 cores inviabiliza o
governor, está errado — eu mesmo escrevi isso e a causa era outra.

**A armadilha é `fix-freq = true`.** Habilitar essa opção faz o governor
**descartar silenciosamente o resto do config** e cair em defaults conservadores.
Deixe em `false`, que é o default do pacote.

## O sintoma real

Com `fix-freq = true`, o governor loga tudo como ausente, mesmo estando no arquivo:

```
WARN config] load-target.upper is missing , using default 0.95
WARN config] safe-points undefined, using conservative defaults:
         * 350 MHz @ 700 mV
         * 2000 MHz @ 1000 mV
WARN config] frequency-range.min is missing , disabled
ERROR mount --bind /dev/shm/patched_gpu_metrics
      /sys/bus/pci/devices/0000:01:00.0/gpu_metrics failed: exit status: 32
```

Com `fix-freq = false` (mesmo arquivo, só essa linha diferente):

```
INFO config] allowed frequency range 500..=2000
INFO config] initial frequency range: 1000..=1850
```

Zero warnings, zero erro de mount. Confirmado por `diff` contra o config extraído
do RPM: **a única diferença entre funcionar e não funcionar era essa linha.**

## Impacto medido (`llama-bench`, Qwen3.5-9B Q6_K, `-p 512 -n 128 -r 3`)

| Configuração | pp512 | tg128 |
|---|---|---|
| 24 CU, sem governor | 206,14 ± 0,06 | 38,23 ± 0,19 |
| 40 CU, sem governor | 332,85 ± 0,05 | 46,42 ± 0,09 |
| **40 CU + governor** | **400,12 ± 0,22** | **47,84 ± 0,05** |
| 40 CU, governor com `fix-freq=true` | ~1 (colapso) | 15,3 |
| 40 CU, governor com `method="kernel"` | ~1 | 5,8 |

Ganho total sobre o estoque: **+94% de prefill e +25% de geração.**
O governor sozinho adiciona +20% de prefill sobre os 40 CU.

Consumo em idle caiu de ~60 W para **41 W**; temperatura de 58 para **52 °C**.

## O que continua quebrado (e não tem solução aqui)

A telemetria de clock por sysfs segue inútil com 8 cores:

```
$ cat /sys/class/drm/card*/device/pp_dpm_sclk
1: 100Mhz *          # lixo; antes do unlock de 8 cores reportava 1500Mhz
$ cat /sys/class/drm/card*/device/gpu_busy_percent
                     # vazio
```

O unlock de 8 cores desloca `GfxclkFrequency` na tabela de telemetria do SMU.
Isso **não impede o governor de funcionar** — ele conversa com o SMU direto
(`set-method = "smu"`, e o log confirma `SMU communication verified`).

O `fix-freq` existe justamente para corrigir esse campo, e é ele que está com
bug nesta versão. O **`SMU Reporting Patch` da BIOS** também não resolve:

| Leitura | Patch OFF | Patch ON |
|---|---|---|
| `pp_dpm_sclk` | 26-100 MHz ❌ | 6425-6925 MHz ❌ |
| `power1_average` | **65-74 W** ✅ | **0 W** ❌ |

6900 MHz é impossível nessa GPU (teto ~2300 MHz). Deixe o patch **desligado**:
ao menos a leitura de potência funciona, e é a que serve para tuning.

## Config recomendada

Use o config que vem no pacote, sem editar. Se quiser conferir:

```bash
rpm -V cyan-skillfish-governor-smu      # S.5....T. = config modificado
sudo systemctl start cyan-skillfish-governor-smu
journalctl -u cyan-skillfish-governor-smu -b | grep -iE "WARN|error"
```

**Qualquer `WARN ... is missing` significa que o config não foi aceito.** Um
governor saudável loga só as duas linhas de `frequency range` e nada mais.

Para restaurar o original depois de estragar:
```bash
cd /tmp && dnf download cyan-skillfish-governor-smu
rpm2cpio cyan-skillfish-governor-smu-*.x86_64.rpm | cpio -idm
sudo cp etc/cyan-skillfish-governor-smu/config.toml /etc/cyan-skillfish-governor-smu/
sudo systemctl restart cyan-skillfish-governor-smu
```

## Lição de método

Duas conclusões erradas nesta investigação, pelo mesmo motivo: **mudei uma
variável e culpei outra.** Habilitei `fix-freq` junto de ativar o governor, vi a
performance colapsar e concluí que o governor era incompatível com 8 cores.
O certo é uma variável por vez, e ler os warnings antes de teorizar — eles
diziam exatamente o que estava errado desde a primeira execução.
