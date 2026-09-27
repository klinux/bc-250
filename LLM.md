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
CTX=65536
PORT=8080
EXTRA=-ngl 99 -fa on -ctk q8_0 -ctv q8_0 -np 1 --reasoning off --keep 256
```
Custo do contexto: 64k com KV `q8_0` consumiu só **0,64 GiB** de GTT
(7,20 -> 7,84 de 12).

Duas pegadinhas na unit systemd:
- **`$EXTRA`, não `${EXTRA}`**: no systemd `$VAR` faz word-splitting e
  `${VAR}` passa tudo como **um** argumento (dá `invalid argument: -ngl 99 ...`).
- `--no-mmap` não existe nessa build; e mmap é desejável aqui (economiza RAM).

`systemctl enable --now llama-server`, depois `curl localhost:8080/health`.

### Contexto: três armadilhas que fazem "estourar o tempo todo"

**1. O `-np` default fatia o contexto.** Com `-c 16384` e `-np` em auto o servidor
cria 4 slots e divide: **4.096 tokens efetivos por conversa**. Use `-np 1` para
uso pessoal — o `/props` deve mostrar `slots: 1`.

**2. O Qwen3.5 é um modelo *thinking*.** Sem controle, ele gasta centenas de
tokens raciocinando antes de responder — e pode devolver `content` **vazio** com
`finish_reason: length`, porque o orçamento acabou no raciocínio. Medido: pedir
"diga apenas: ola" consumiu **300 tokens** e 1044 caracteres de
`reasoning_content`, com `content` vazio. Com `--reasoning off`: **2 tokens** e
`content = "ola"`. Para tarefas complexas, troque por `--reasoning on`.

**3. `--context-shift` não funciona com esse modelo.** A flag é aceita e o
llama.cpp a desativa sozinho:
```
W common_init_: KV cache shifting is not supported for this context, disabling...
```
Não é erro de config. Testei a hipótese de que o KV quantizado (`-ctk q8_0`)
impedia — **não é**: com KV `f16` dá a mesma mensagem. É a arquitetura do modelo
(atenção com janela deslizante), para a qual `llama_memory_can_shift` é falso.

### O que acontece quando o contexto acaba

São **dois** comportamentos distintos:

**Conversa que cresceu até encher** — erro só naquela requisição, servidor
intacto, modelo continua carregado:
```
error: task id = 2041, error: Context size has been exceeded.
```
A requisição seguinte funciona normalmente. O que fica inutilizável é aquela
conversa (o histórico já não cabe); **conversa nova resolve na hora**.

**Prompt gigante de uma vez** (colar um documento de centenas de KB) — sem
proteção, isso **não** dá erro de contexto: o servidor tenta alocar tudo antes de
descobrir que não cabe e o **OOM killer do kernel mata o processo**:
```
Out of memory: Killed process (llama-server) total-vm:18048040kB
```
Pior: o OOM killer é **global** e escolhe a vítima pelo consumo — podia matar o
Steam ou algo do sistema em vez do servidor.

A proteção é limitar a memória do container na unit:
```
--memory=11g --memory-swap=11g
```
Com isso o estouro fica contido e vira um erro limpo (testado com 90k tokens):
```json
{"error":{"message":"request (90013 tokens) exceeds the available context size
 (65536 tokens), try increasing it","type":"exceed_context_size_error"}}
```
Servidor sobrevive, `restarts: 0`, próxima requisição normal.

### Limpar o contexto
A WebUI é **stateless do lado do servidor**: guarda a conversa no navegador e
reenvia o histórico inteiro a cada mensagem. "Nova conversa" na WebUI descarta o
histórico e resolve. O cache de KV do slot é outra coisa, e se limpa por API:
```bash
curl -X POST "http://<ip>:8080/slots/0?action=erase"
```
Necessário para medições comparáveis; no uso normal, a WebUI basta.

### Modo agente
`--agent` liga o proxy CORS **e todas** as built-in tools (`read_file`,
`file_glob_search`, `grep_search`, ...). O upstream avisa: *"do not enable in
untrusted environments"*. Como o server escuta em `0.0.0.0` sem autenticação,
qualquer host da LAN pode usar essas tools — feche com `--api-key <segredo>`.

Para dar acesso sem liberar tudo, prefira `--tools` com uma lista enxuta
(ex.: `--tools grep_search,read_file`) em vez de `--agent`, que habilita todas.

> `--model` (ou `-m`) é apenas o caminho do GGUF. Não tem relação com limitar o
> que o agente lê — isso é o que `--tools` controla.

## 4. Números medidos (Qwen3.5-9B abliterated Q6_K)

| Métrica | Valor |
|---|---|
| Prompt (prefill) | 62,9 (24 CU) -> 75,9 (40 CU) |
| Geração | 34,8 (24 CU) -> **42,9** (40 CU) |
| GTT usado | 7,57 / 12,00 GiB (modelo 6,85 + KV q8_0 @ 16k) |
| RAM total usada | 10 / 14 GiB |
| GPU | 74 W, 67 °C |

Números limpos de `llama-bench` (a forma correta de medir — ver
[CU-UNLOCK-40.md](CU-UNLOCK-40.md)): pp512 206 -> **333 t/s** (+61,5%),
tg128 38,2 -> **46,4 t/s** (+21,4%) com o unlock de 40 CU aplicado.
Com o governor ativo por cima: pp512 **400,1 t/s** e tg128 **47,8 t/s** —
**+94% e +25%** sobre o estoque.

> **Não meça pelo `llama-server`.** O contexto acumula no slot e a geração
> desacelera; `cache_prompt: false` não zera isso (use
> `POST /slots/0?action=erase`), e repetir o mesmo prompt faz o prefill medir
> 4 tokens em vez de 1900. Isso me levou a duas conclusões erradas.

> **Instale o governor**, mas não toque no `fix-freq`. Ele rende +20% de prefill
> e derruba o idle de 60 para 41 W. Habilitar `fix-freq = true` faz o governor
> descartar o config inteiro e a performance colapsar — foi o que me levou a
> concluir errado que ele era incompatível com 8 cores. Medições em
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

## Cuidado: um modelo por vez

A GPU tem 12 GiB de GTT e o modelo ocupa 6,85. Subir um **segundo** servidor com
o mesmo modelo estoura, e o efeito não é um erro limpo — derruba o contexto
Vulkan do servidor que já estava rodando:

```
W ggml_vulkan: Failed to allocate pinned memory (vk::Device::allocateMemory:
               ErrorOutOfDeviceMemory)
E llama_model_load: error loading model: vk::Queue::submit: ErrorDeviceLost
```

Antes de testar outra configuração, pare o serviço (`systemctl stop llama-server`)
ou confira `podman ps` por containers órfãos.
