# Servidor LLM na BC-250 — llama.cpp + Vulkan

Validado em 27/set/2026: Bazzite Deck 44, kernel 7.2.4, **8 cores**, **24 CU**
(unlock de 40 CU ainda não aplicado), GTT 12 GiB.

## 1. O bloqueio que vem antes de tudo: GTT

A GPU não vê "16 GB". Ela vê `VRAM` (o framebuffer UMA, 512 MB) mais o `GTT`
(RAM do sistema mapeada pra GPU) — e **o GTT nasce limitado a metade da RAM**:

```
mem_info_gtt_total = 7,41 GiB     # antes
```

Com isso nenhum modelo acima de ~7 GiB carrega, por mais que sobre RAM.

`/etc/modprobe.d/` **não resolve**: o `ttm` sobe pelo initramfs, antes de o
arquivo ser lido. O que funciona em ostree é kernel cmdline:

```bash
sudo rpm-ostree kargs \
  --append-if-missing=ttm.pages_limit=4194304 \
  --append-if-missing=ttm.page_pool_size=4194304 \
  --append-if-missing=amdgpu.gttsize=12288
sudo systemctl reboot
```

Resultado: **GTT = 12,00 GiB**. Confirme com:
```bash
cat /sys/class/drm/card*/device/mem_info_gtt_total   # /1073741824 = GiB
```
E o llama.cpp deve reportar:
```
Vulkan0: AMD BC-250 (RADV GFX1013) (12800 MiB, 12139 MiB free)
```

> `gttsize` é um **teto**, não reserva: a RAM só é consumida quando usada.
> Mantenha o UMA da BIOS em **512M dinâmico** — fixar 6-8 GB rouba RAM do
> sistema e entrega menos que o GTT dinâmico.

## 2. Vulkan, não ROCm

A gfx1013 não tem ROCm viável (falta rocBLAS). Tudo roda em Vulkan/RADV.
Em OS imutável, container é mais limpo que compilar:

```bash
podman pull ghcr.io/ggml-org/llama.cpp:server-vulkan
podman run --rm --device /dev/dri --group-add keep-groups \
  --entrypoint /app/llama-server ghcr.io/ggml-org/llama.cpp:server-vulkan --list-devices
```

`--device /dev/dri --group-add keep-groups` é o que dá acesso à GPU.

## 3. Serviço

`/etc/llama-server.env` (trocar de modelo = editar aqui e reiniciar):
```
MODEL=Huihui-Qwen3.5-9B-abliterated.i1-Q6_K.gguf
CTX=16384
PORT=8080
EXTRA=-ngl 99 -fa on -ctk q8_0 -ctv q8_0
```

Duas pegadinhas na unit systemd:
- **`$EXTRA`, não `${EXTRA}`**: no systemd `$VAR` faz word-splitting e
  `${VAR}` passa tudo como **um** argumento (dá `invalid argument: -ngl 99 ...`).
- `--no-mmap` não existe nessa build; e mmap é desejável aqui (economiza RAM).

`systemctl enable --now llama-server`, depois `curl localhost:8080/health`.

### Modo agente
`--agent` liga o proxy CORS **e todas** as built-in tools (`read_file`,
`file_glob_search`, `grep_search`, ...). O upstream avisa: *"do not enable in
untrusted environments"*. Como o server escuta em `0.0.0.0` sem autenticação,
qualquer host da LAN pode usar essas tools — feche com `--api-key <segredo>`.

Para dar acesso sem liberar tudo, prefira `--tools` com uma lista enxuta
(ex.: `--tools grep_search,read_file`) em vez de `--agent`, que habilita todas.

> `--model` (ou `-m`) é apenas o caminho do GGUF. Não tem relação com limitar o
> que o agente lê — isso é o que `--tools` controla.

## 4. Números medidos (Qwen3.5-9B abliterated Q6_K, 24 CU)

| Métrica | Valor |
|---|---|
| Prompt (prefill) | **62,9 tok/s** |
| Geração | **34,8 tok/s** |
| GTT usado | 7,57 / 12,00 GiB (modelo 6,85 + KV q8_0 @ 16k) |
| RAM total usada | 10 / 14 GiB |
| GPU | 74 W, 67 °C |

Com o unlock de 40 CU a expectativa é +32% geração / +50% prefill.

> **Não instale o governor de GPU esperando ganho aqui.** Com 8 cores ativos ele
> fica cego (telemetria do SMU quebrada) e a geração cai para 15 tok/s — ou 5,8
> com `method = "kernel"`. Detalhes e medições em
> [GPU-TELEMETRIA-GOVERNOR.md](GPU-TELEMETRIA-GOVERNOR.md).

## 5. Escolha de modelo: por que MoE

A placa tem banda de GDDR6 boa e compute fraco (24 CU, 40 no máximo). MoE lê
muitos pesos mas computa só uma fração por token — é o formato ideal. Um denso
de 26B seria arrastado; o mesmo 26B em MoE com 4B ativos voa.

Orçamento real: **~10,5 GiB** para o modelo (12 GiB de GTT menos KV e overhead).

| Modelo (abliterated) | Quant | GiB | Nota |
|---|---|---|---|
| `Huihui-Qwen3.5-9B` | Q6_K | 6,85 | **validado aqui**; denso, nunca dá OOM |
| `gemma-4-26B-A4B-it` (groxaxo) | UD-IQ3_S | 10,45 | MoE 4B ativos + visão; melhor qualidade que cabe |
| `Huihui-Qwen3.5-35B-A3B` | i1-IQ2_S | 9,79 | 35B mas IQ2 degrada num MoE de 3B ativos |
| `Huihui-gpt-oss-20b-mxfp4` | MXFP4 | 12,85 | o mais rápido, mas **não cabe** |

Sobre o gpt-oss: os experts já são MXFP4 nativos, então requantizar **não
encolhe** — todos os quants i1 ficam em 11,2-11,4 GiB. Não é questão de achar
o quant certo.

E o **GLM 5.1 abliterated são 754B / 236 GB** — 20× a placa, nenhum quant resolve.
Isso vale pra esse modelo, não pra família GLM inteira.

## Reverter
```bash
sudo systemctl disable --now llama-server
sudo rm -f /etc/systemd/system/llama-server.service /etc/llama-server.env
sudo rpm-ostree kargs --delete=ttm.pages_limit=4194304 \
  --delete=ttm.page_pool_size=4194304 --delete=amdgpu.gttsize=12288
```
