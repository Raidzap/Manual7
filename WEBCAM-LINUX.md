# Usar o Manual7 como webcam no Linux

O Manual7 0.7.5 transmite o mesmo `AVCaptureVideoDataOutput` usado pelo visor e pelos controles da câmera através do bridge `launchd` em `127.0.0.1:27840`. ISO, shutter, EV, foco manual, AE-L/AF-L, lente e rastreamento afetam os frames da webcam imediatamente. O M7 tenta codificar MJPEG na cadência de 30 fps da câmera e oferece uma saída horizontal 1280 × 720 ou vertical 720 × 1280.

Ativar a webcam muda o M7 para Vídeo antes de abrir o stream. O controle Foto/Vídeo fica bloqueado até a webcam ser desligada. Sob pressão do encoder ou da rede, o M7 conserva somente o frame mais recente: a imagem pode ter atraso de transporte, mas a fila não cresce indefinidamente. O diagnóstico separa frames recebidos, codificados, publicados e substituídos.

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

O comando configura o formato, liga a saída no iPhone, espera o endpoint MJPEG, inicia o FFmpeg e desliga a saída ao terminar. `Ctrl+C` encerra. Use `--keep-enabled` somente quando quiser manter o socket de vídeo ativo para outro consumidor.

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
