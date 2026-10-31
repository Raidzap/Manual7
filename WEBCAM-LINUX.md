# Usar o Manual7 como webcam no Linux

O Manual7 0.7.5 transmite o mesmo `AVCaptureVideoDataOutput` usado pelo visor e pelos controles da câmera através do bridge `launchd` em `127.0.0.1:27840`. ISO, shutter, EV, foco manual, AE-L/AF-L, lente e rastreamento afetam os frames da webcam imediatamente. O M7 tenta codificar MJPEG na cadência de 30 fps da câmera e oferece uma saída horizontal 1280 × 720 ou vertical 720 × 1280.

Ativar a webcam muda o M7 para Vídeo antes de abrir o stream. O controle Foto/Vídeo fica bloqueado até a webcam ser desligada. Sob pressão do encoder ou da rede, o M7 conserva somente o frame mais recente: a imagem pode ter atraso de transporte, mas a fila não cresce indefinidamente. O diagnóstico separa frames recebidos, codificados, publicados e substituídos.

Enquanto a webcam transmite, o M7 impede o bloqueio automático da tela, que suspenderia a Câmera e encerraria o stream; ao desligar a webcam, a configuração anterior é restaurada (`webcam.screenKeptAwake` no diagnóstico). No Manual7 Studio, o visor e a câmera virtual compartilham uma única conexão com o iPhone, e uma queda do Wi-Fi é detectada em cerca de 15 segundos.

No Manual7 Studio 0.1.2, selecione **Horizontal 16:9** ou **Vertical 9:16** em **Formato do retorno** antes de iniciar. Essa escolha controla o visor e o `v4l2loopback`. O seletor **Formato da gravação (Reframe)** é independente e controla os arquivos salvos no iPhone.

O fluxo permanece dentro do SSH: o bridge escuta apenas em `127.0.0.1:27840` no iPhone e exige o PIN do painel M7 na requisição MJPEG. O pareamento informa a porta ao cliente, que a encaminha para `127.0.0.1:17838`; o FFmpeg lê o MJPEG autenticado e grava em um dispositivo virtual `v4l2loopback`.

Esta primeira versão transmite somente vídeo. O focus peaking continua como guia no visor do iPhone e não é gravado no sinal da webcam. O Reframe da webcam produz um formato por vez; a opção **Ambos** continua disponível para gravações de vídeo locais.

## Dependências no notebook

Em Debian ou Ubuntu:

```sh
sudo apt update
sudo apt install ffmpeg v4l2loopback-dkms v4l2loopback-utils
sudo modprobe v4l2loopback video_nr=10 card_label="Manual7 Webcam" exclusive_caps=1
ls -l /dev/video10
```

`exclusive_caps=1` faz o dispositivo anunciar primeiro capacidade de saída e, depois que o FFmpeg começa a alimentá-lo, capacidade de captura. Esse modo é recomendado pelo projeto v4l2loopback para programas baseados em Chrome/WebRTC. Se o usuário atual não puder escrever em `/dev/video10`, inclua-o no grupo que possui o dispositivo, geralmente `video`, e inicie uma nova sessão.

## Abrir o túnel

Abra o M7 no iPhone, mantenha a Câmera em primeiro plano e anote o PIN. No primeiro terminal:

```sh
python3 tools/manual7_pair.py
```

Esse comando encaminha os dois sockets na mesma sessão SSH:

```text
127.0.0.1:17837 -> <temporário da Câmera>/m7a
127.0.0.1:17838 -> <temporário da Câmera>/m7w
```

O cliente testa as portas SSH 22 e 2222. Use `--ssh-port 2222` para escolher explicitamente.

### Pelo cabo USB

Com o iPhone ligado por cabo ao notebook, o mesmo SSH pode passar pelo `usbmuxd` em vez do Wi-Fi: a latência fica estável, a banda não disputa a rede e o aparelho carrega durante a chamada. O QR continua sendo lido pelo Wi-Fi, porque é ele que entrega o PIN.

```sh
sudo apt install usbmuxd
python3 tools/manual7_pair.py --usb
# ou, com o PIN já conhecido:
python3 tools/manual7_remote.py tunnel --usb
```

O `ssh` usa `manual7_remote.py usb-proxy` como `ProxyCommand` e guarda a chave em `known_hosts` sob o nome `manual7-usb`. Se o iPhone pedir, toque em **Confiar neste computador**. Com mais de um iPhone no USB, o túnel recusa a escolha e é preciso usar o Wi-Fi.

## Alimentar a webcam virtual

Em outro terminal:

```sh
export MANUAL7_PIN=123456
python3 tools/manual7_remote.py webcam-feed --device /dev/video10 --format horizontal
```

Para a saída vertical:

```sh
python3 tools/manual7_remote.py webcam-feed --device /dev/video10 --format vertical
```

O comando configura o formato, liga a saída no iPhone, espera o endpoint de vídeo, inicia o FFmpeg e desliga a saída ao terminar. `Ctrl+C` encerra. Use `--keep-enabled` somente quando quiser manter o socket de vídeo ativo para outro consumidor.

### Montagem do iPhone

O ajuste **Montagem** (painel M7 → Conexão com o PC, ou **Montagem do iPhone** no Studio) define a orientação dos frames de vídeo e é lembrado entre aberturas do M7:

| Montagem | Buffer | 16:9 | 9:16 |
| --- | --- | --- | --- |
| **Paisagem** (padrão, botão Home à direita) | 1920 × 1440, orientação nativa do sensor, sem rotação | 1920 × 1080 nativo | 720 × 1280 |
| **Invertida** (botão Home à esquerda) | 1920 × 1440 girado 180° | 1920 × 1080 nativo | 720 × 1280 |
| **Retrato** | 1440 × 1920 | 1280 × 720 | 1080 × 1920 nativo |

Os valores valem para H.264; o MJPEG continua em 1280 × 720 / 720 × 1280. A montagem também orienta a gravação e o Reframe: em paisagem, o master 4:3 sai deitado e o recorte 16:9 do Reframe fica nativo. Fotos continuam em retrato. O preview do iPhone mostra a cena correta em qualquer montagem; as guias de Reframe, o marcador do rastreamento e o focus peaking acompanham a rotação. A troca fica bloqueada enquanto a webcam transmite ou um vídeo é gravado/processado. Remotamente: `python3 tools/manual7_remote.py set cameraMount landscape` (`landscapeInverted`, `portrait`).

### Taxa de quadros

O modo Vídeo trava o sensor numa taxa fixa: **30 fps** (padrão) ou **24 fps**, para um visual de cinema. A escolha fica em **Captura → FPS** no iPhone e em **Captura e enquadramento → Taxa de quadros** no Studio, é lembrada e vale para a gravação, o Reframe e a webcam. Ela muda na hora, inclusive com a webcam transmitindo: o H.264 recomeça num keyframe e o FFmpeg segue a nova cadência sozinho (`-fps_mode passthrough`). Durante uma gravação a troca fica bloqueada, para o arquivo manter uma única taxa. Com 24 fps, o obturador perto de 1/50 (regra dos 180°) dá o borrão de movimento natural do cinema. Remotamente: `python3 tools/manual7_remote.py set frameRate 24`.

### H.264

Quando o M7 oferece `/v1/webcam.h264`, `webcam-feed` usa H.264 automaticamente (`--codec auto`). O encoder do iPhone roda em tempo real, sem B-frames, com keyframe a cada 2 s e a cerca de 0,1 bit por pixel: 2,8 Mbit/s em 1280 × 720 e 6,2 Mbit/s em 1080 × 1920, uma fração do MJPEG. As dimensões dependem da montagem (tabela acima): o formato que coincide com a montagem sai no recorte nativo e o cruzado fica em 720p, sem ampliação. O H.264 já chega em BT.709 de faixa limitada, então o FFmpeg não precisa do `zscale`. `--codec mjpeg` força o caminho anterior.

Se a fila H.264 passar de 2 MiB (rede lenta), o M7 a descarta, pede um keyframe imediato e os clientes retomam a partir dele, em vez de acumular atraso. `webcam.h264` no estado e `webcam.server.h264` no diagnóstico mostram disponibilidade, OSStatus, dimensões, bitrate, keyframes e transbordamentos.

Depois selecione **Manual7 Webcam** no OBS Studio, navegador, aplicativo de reunião ou gravador V4L2. Se o programa já estava aberto antes do FFmpeg, feche e abra novamente a lista de câmeras.

## Aplicar os controles durante o uso

Use um terceiro terminal com o mesmo `MANUAL7_PIN`. Os comandos alteram a mesma câmera física que produz a webcam:

```sh
python3 tools/manual7_remote.py set exposureMode manual
python3 tools/manual7_remote.py set iso 100
python3 tools/manual7_remote.py set shutterSeconds 0.0166667
python3 tools/manual7_remote.py set focusMode manual
python3 tools/manual7_remote.py set focusPosition 0.42
python3 tools/manual7_remote.py set lens wide
```

Ativar a webcam já coloca o M7 em Vídeo. Para Reframe acompanhado por pessoa, ative o rastreamento; a gravação local não precisa ser iniciada:

```sh
python3 tools/manual7_remote.py set tracking true
python3 tools/manual7_remote.py webcam start --format vertical
```

Também é possível usar os controles diretamente no painel M7. Para trocar **WC formato** entre 16:9 e 9:16, pare `webcam-feed`, escolha o novo formato e inicie novamente. O túnel SSH pode permanecer aberto. Essa sequência mantém a resolução V4L2 estável durante cada conexão.

## Diagnóstico

```sh
python3 tools/manual7_remote.py state
python3 tools/manual7_remote.py diagnostic --output relatorio-m7.json
```

`state.webcam` e `report.webcam` registram formato, dimensões, modo Vídeo, frames recebidos/codificados, tempo médio de JPEG e descartes por encoder ocupado. `server` acrescenta frames submetidos/publicados/substituídos, FPS efetivo, tamanho e bytes enviados. Eventos como `webcamVideoModeRequested`, `webcamStarted`, `webcamStopped`, `captureModeChangeBlocked`, `webcamStartFailed` e `webcamEncodeError` ficam em `sessionEvents`.

Os avisos `deprecated pixel format used` vinham do `swscale`: JPEG usa faixa completa e a saída V4L2 usa `yuv420p` de faixa limitada. O cliente 0.7.5 usa `zscale` com `in_range=full` e `out_range=limited`, seguido de `color_range=tv`. Assim a conversão fica explícita e o aviso desaparece. O pacote FFmpeg da distribuição precisa incluir o filtro `zscale`, como ocorre no pacote padrão do Ubuntu/Linux Mint.

Se não houver imagem, confirme nesta ordem: M7 em primeiro plano, túnel ainda aberto, PIN atual, `state.webcam.server.running: true`, `clientCount` maior que zero, `framesPublished` aumentando e `/dev/video10` existente. A Câmera em segundo plano encerra a API e a webcam de forma intencional.

Referências: [OpenSSH `ssh(1)` e encaminhamento `-L`](https://man.openbsd.org/ssh), [v4l2loopback — instalação, `video_nr`, `card_label` e `exclusive_caps`](https://github.com/v4l2loopback/v4l2loopback/blob/main/README.md) e [FFmpeg — dispositivos de entrada/saída](https://ffmpeg.org/ffmpeg-devices.html).
