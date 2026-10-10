# Manual7 Studio para Linux

Aplicativo gráfico para parear o M7 por QR, abrir o túnel SSH, acompanhar o retorno MJPEG e ajustar a câmera do iPhone em tempo real. O AppImage não precisa instalar o Electron no sistema.

Baixe `Manual7-Studio-0.1.2-x86_64.AppImage` na [release desktop-v0.1.2](https://github.com/Raidzap/Manual7/releases/tag/desktop-v0.1.2), torne-o executável e abra:

```sh
chmod +x Manual7-Studio-0.1.2-x86_64.AppImage
./Manual7-Studio-0.1.2-x86_64.AppImage
```

## Fluxo de uso

1. Abra o M7 no iPhone e mantenha a Câmera em primeiro plano.
2. Abra o AppImage e clique em **Parear iPhone**.
3. No M7, use **Conexão → Ler QR do PC** e leia o código exibido.
4. Digite a senha SSH do usuário `mobile`. Na primeira conexão, confira e aceite a impressão digital da chave do iPhone.
5. Em **Formato do retorno**, escolha **Horizontal 16:9** ou **Vertical 9:16**.
6. Clique em **Iniciar retorno**. O Studio confere o formato e as dimensões confirmados pelo iPhone antes de abrir o visor.
7. ISO, shutter, EV, foco, peaking, RAW/JPEG, lente, vídeo, Reframe e rastreamento passam a usar a mesma API do painel do iPhone.

**Formato do retorno** define a imagem enviada ao visor e à câmera virtual Linux. **Formato da gravação (Reframe)** define os arquivos de vídeo salvos pelo M7 no iPhone; pode ser Horizontal, Vertical ou Ambos.

O QR expira em dois minutos e só pode ser usado uma vez. A senha SSH fica somente na memória do processo. O PIN recebido do iPhone permanece no processo principal e não é exposto ao renderer. A chave SSH aceita é lembrada em `~/.config/Manual7 Studio/known-hosts.json`.

## Câmera virtual

A prévia funciona sem configuração extra. Para apresentar o sinal a OBS, Meet ou outro programa como uma webcam V4L2, instale FFmpeg com o filtro `zscale` e crie um dispositivo `v4l2loopback`:

```sh
sudo apt install ffmpeg v4l2loopback-dkms
sudo modprobe v4l2loopback video_nr=10 card_label="Manual7 Webcam" exclusive_caps=1
```

Depois de iniciar o retorno, selecione `/dev/video10` e clique em **Transmitir para o Linux**. Se aparecer erro de permissão, inclua o usuário no grupo `video`, encerre a sessão e entre novamente:

```sh
sudo usermod -aG video "$USER"
```

## Desenvolvimento e AppImage

```sh
cd desktop
npm install
npm test
npm run build:appimage
```

O arquivo final fica em `desktop/dist/Manual7-Studio-0.1.2-x86_64.AppImage`. Para troca segura ao modo Vídeo e transmissão de até 30 fps, use o M7 móvel 0.7.5 ou superior.
