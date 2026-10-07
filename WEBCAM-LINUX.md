# Usar o Manual7 como webcam no Linux

O Manual7 0.6.0 transmite o mesmo `AVCaptureVideoDataOutput` usado pelo visor e pelos controles da câmera. ISO, shutter, EV, foco manual, AE-L/AF-L, lente e rastreamento afetam os frames da webcam imediatamente. O M7 codifica MJPEG a 10 fps e oferece uma saída horizontal 1280 × 720 ou vertical 720 × 1280.

O fluxo permanece dentro do SSH: o iPhone cria `/var/tmp/Manual7-webcam.sock` com permissão `0600`, exige o PIN do painel M7 e não abre uma porta de rede própria. O cliente encaminha esse socket para `127.0.0.1:17838`; o FFmpeg lê o MJPEG autenticado e grava em um dispositivo virtual `v4l2loopback`.

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
python3 tools/manual7_remote.py tunnel 192.168.1.50
```

Esse comando encaminha os dois sockets na mesma sessão SSH:

```text
127.0.0.1:17837 -> /var/tmp/Manual7-api.sock
127.0.0.1:17838 -> /var/tmp/Manual7-webcam.sock
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

Para Reframe acompanhado por pessoa, ative o modo Vídeo e o rastreamento. A gravação local não precisa ser iniciada:

```sh
python3 tools/manual7_remote.py set captureMode video
python3 tools/manual7_remote.py set tracking true
python3 tools/manual7_remote.py webcam start --format vertical
```

Também é possível usar os controles diretamente no painel M7. Para trocar **WC formato** entre 16:9 e 9:16, pare `webcam-feed`, escolha o novo formato e inicie novamente. O túnel SSH pode permanecer aberto. Essa sequência mantém a resolução V4L2 estável durante cada conexão.

## Diagnóstico

```sh
python3 tools/manual7_remote.py state
python3 tools/manual7_remote.py diagnostic --output relatorio-m7.json
```

`state.webcam` e `report.webcam` registram formato, dimensões, estado solicitado/ativo, codificação, frames ignorados por carga, último erro, clientes, bytes e frames enviados, permissões e caminho do socket. Eventos como `webcamStarted`, `webcamStopped`, `webcamStartFailed` e `webcamEncodeError` ficam em `sessionEvents`.

Se não houver imagem, confirme nesta ordem: M7 em primeiro plano, túnel ainda aberto, PIN atual, `state.webcam.server.running: true`, `clientCount` maior que zero, `framesPublished` aumentando e `/dev/video10` existente. A Câmera em segundo plano encerra a API e a webcam de forma intencional.

Referências: [OpenSSH `ssh(1)` e encaminhamento `-L`](https://man.openbsd.org/ssh), [v4l2loopback — instalação, `video_nr`, `card_label` e `exclusive_caps`](https://github.com/v4l2loopback/v4l2loopback/blob/main/README.md) e [FFmpeg — dispositivos de entrada/saída](https://ffmpeg.org/ffmpeg-devices.html).
