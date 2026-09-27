# BC-250 — plano de tuning (set/2026)

Uso: Bazzite (Steam) + servidor LLM interno (llama.cpp Vulkan).

## 0. Hardware antes de tudo
- PSU com 300 W+ no rail de 12 V (mínimo 250 W). Com 8c + 40 CU o consumo sobe ~30 W.
- Fan 120 mm alta pressão estática (Arctic P12) + backplate/ventilação na GDDR6.
- Saída: DisplayPort (ou adaptador DP→HDMI passivo).
- **Programador CH347T** (não use CH341A de PCB preto — 5 V mata o chip). Chip: BIOS_A1 (W25Q128JVSQ, 16 MB, header J4004). NUNCA flashe o SIO1_R.

## 1. Backup da BIOS (obrigatório)
```bash
sudo flashrom -p ch347_spi -r backup-stock.bin     # via programador
# ou, de dentro do Linux (validado pela comunidade, não oficial):
sudo flashrom -p internal -r backup-stock.bin
```
Se a placa veio com **P4.00 stock**, troque — é instável (3D crasha).

## 2. Núcleos: 6 → 8 (SMU mask, não é fuse)
Ordem: **testar em runtime primeiro, só depois gravar na BIOS**.
```bash
git clone https://github.com/GabriWar/bc250-core-cu-unlock
cd bc250-core-cu-unlock
sudo ./bc250-8core-unlock.sh status   # mask deve ser 0x77
sudo ./bc250-8core-unlock.sh apply && sudo reboot   # warm reboot preserva
./test-cores.sh 60                    # stress por core; ~80% das placas passam
```
- Todos passaram → BIOS permanente: **Forbidden-Darkness MeiMeiDXE-T-v2** (base P3.00, toggle no menu UEFI)
  https://github.com/Forbidden-Darkness/AMD-BC-250-UEFI-v2.2-Firmware-Menu-Script
- Um core ruim → não flashe; use `install` (systemd) e mascare o core (0x7F / 0xF7).
- Cold boot (desligar da tomada) sempre volta a 6 cores = escape hatch.
- Depois: `sudo ./bc250-acpi-fix.sh install` (C-states das threads 12-15, senão gasta energia idle).
- Espere +10–12 °C; OC de CPU cai de ~4.0 para 3.5–3.85 GHz all-core.

## 3. CUs: 24 → 40 (driver amdgpu, precisa kernel patch)
Registradores CC_GC_SHADER_ARRAY_CONFIG + SPI_PG_ENABLE_STATIC_WGP_MASK, param `bc250_cc_write_mode=3`.
- Patch: https://github.com/duggasco/bc250-40cu-unlock (CachyOS/Arch: `bc250-enable-40cu.sh build && enable`)
- Bazzite (imutável): usar imagem patched (`ghcr.io/vietsman/bazzite-{gnome,kde,deck}-patched`) e verificar se inclui o patch, ou o runtime manager WinnieLV/bc250-cu-live-manager.
- Verificar: `dmesg | grep active_cu_number` → 40
- CU ruim = pontos verdes/artefatos imediatos → `amdgpu.disable_cu=SE.SH.WGP` para mascarar.
- Ganho LLM: +32 % geração / +50 % prefill; +30 W. Ponto ótimo 1500 MHz @ 900 mV. Não passe de 2300 MHz / 1025 mV (OCP trava a placa).

## 4. BIOS settings (após flash + CLEAR CMOS obrigatório)
```
Chipset → GFX: Integrated Graphics = Forces; UMA Mode = UMA_SPECIFIED; UMA Frame Buffer = 512M (dinâmico, ~12 GB GTT p/ GPU)
Advanced → CPU: IOMMU = Disabled   ← quebrado na BC-250
Boot: UEFI
```
Clear CMOS: bateria fora 60 s + 5× botão power, ou jumper CLRCMOS1 (2-3) 20 s.

## 5. Bazzite
- Imagem **Deck** (UI Steam) ou KDE. Boot sem parâmetros especiais.
- Governor (sem patch de kernel):
```bash
sudo dnf copr enable filippor/bazzite
rpm-ostree install cyan-skillfish-governor-smu && systemctl reboot
sudo systemctl enable --now cyan-skillfish-governor-smu.service
# /etc/cyan-skillfish-governor-smu/config.toml → voltage 1000 mV (testar 900 depois)
```
- Sensores: `nct6683` com `force=true`. Micro-stutter: `systemctl mask hhd`.
- Opcional gaming: `rpm-ostree kargs --append-if-missing=mitigations=off`.

## 6. LLM (llama.cpp + Vulkan; ROCm NÃO)
- TTM limit (persistir em /etc/modprobe.d/ttm-gpu-memory.conf):
```bash
echo 4194304 | sudo tee /sys/module/ttm/parameters/pages_limit
echo 4194304 | sudo tee /sys/module/ttm/parameters/page_pool_size
```
- Build (em distrobox/podman com /dev/dri): `cmake -B build -DGGML_VULKAN=1 && cmake --build build --config Release`
- Servir: `llama-server -m modelo.gguf -ngl 99 -fa on -ctk q8_0 -ctv q8_0 -c 32768`
- llama.cpp é 2–3× mais rápido que Ollama em MoE aqui. OOM é o modo de falha padrão: 1 modelo carregado por vez.

### Modelos abliterated — budget ~12 GB
| Modelo | Quant | ~GB | tok/s (24→40 CU) | Uso |
|---|---|---|---|---|
| Huihui-Qwen3.5-35B-A3B-abliterated (MoE) | IQ2_M/IQ3 | 11 | 59→78 | assistente geral, rápido |
| Huihui-gpt-oss-20b-abliterated (MoE) | MXFP4 | 12 | 66→87 | raciocínio, tools |
| gemma-4-26B-A4B heretic/uncensored (MoE) | Q3_K_M | 11 | ~39→52 | geral + visão |
| Qwen3.6-14B abliterated (denso) | Q4_K_M | 9 | ~25 | qualidade/tool-calling |
| Huihui-Qwen3.6-27B-abliterated (denso) | IQ3_XS | 11 | ~10 | máxima qualidade, lento |
| Huihui-Mistral-Small-3.2-24B-abliterated | IQ3_XS | 10 | ~12 | ficção/RP |
| Llama-3.1-8B-abliterated (mlabonne) | Q5_K_M | 5.7 | ~60 | fallback leve |

## Verificação das ROMs (21/set/2026, UEFIExtract NE A75)
- 17 variantes do release v0.5.0 são idênticas exceto o módulo de logo `7BB28B99-61BB-11D5-9A5D-0090273FC14D`.
- Stock P3.00 → MeiMeiDXEv3: +6 DXE (SMU_Unlock, SMU_Patch, SMU_Core_Unlock, ColdBoot, ACPI_AutoInject, Menu_Driver; EDK2 RELEASE_CLANGDWARF), AMITSE + Setup patchados, nada removido.
- Menu UEFI exposto: Core Unlock = Disabled/Enabled/Custom, Core 0–7 individual, ACPI Patch.
- Escolhida: `Firmware/BC250_3.00_MeiMeiDXEv3-SteamOS.M` (`menu 03`).
- Não desmontado; confiança = estrutura + strings + histórico público do repo.

## Rede (26/set/2026)
- Ethernet: **Realtek RTL8111/8168 Gigabit** (`10ec:8168`, driver `r8169`) — não é 10/100.
  Com o cabo fora, `ethtool` reporta `10baseT` e `Speed: Unknown!`; isso é o PHY sem
  link, não a capacidade da placa.
- WiFi/BT: dongle AIC8800D80 — ver [WIFI-AIC8800.md](WIFI-AIC8800.md).
- 8 cores ativos: `CoreVar=0x01`, `AcpiVar=0x01`, `nproc=16`. Máscara de fábrica
  aprendida = `0x77`.

## Pendente
- [ ] Unlock 24 -> 40 CU (patch de kernel; hoje: `active_cu_number 24`)
- [x] **SMU Reporting Patch** testado e **revertido**: não corrige a telemetria e
  zera a leitura de potência. Deixe desligado.
- [ ] **Cooling antes dos 40 CU**: 81 °C GPU / 80 °C CPU sob carga, sem margem
  para os +30 W do unlock. Dissipador stock é para fluxo de rack — fan sem
  shroud rende pouco.
- [x] Governor `cyan-skillfish-governor-smu`: instalado mas **desabilitado de
  propósito** — com 8 cores a telemetria do SMU quebra, o governor fica cego e a
  inferência cai de 34 para 15 tok/s. Ver [GPU-TELEMETRIA-GOVERNOR.md](GPU-TELEMETRIA-GOVERNOR.md)
- [x] TTM/GTT: 7,4 -> 12,0 GiB via kargs (ver [LLM.md](LLM.md))
- [x] llama.cpp + Vulkan + Qwen3.5-9B: 34,8 tok/s (ver [LLM.md](LLM.md))
