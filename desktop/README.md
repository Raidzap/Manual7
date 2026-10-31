# Manual7 Studio para Linux

Aplicativo gráfico para parear o M7 por QR, abrir o túnel SSH (pelo cabo USB quando possível), acompanhar o retorno H.264 ou MJPEG e ajustar a câmera do iPhone em tempo real. O AppImage não precisa instalar o Electron no sistema.

Baixe `Manual7-Studio-0.1.6-x86_64.AppImage` na [release desktop-v0.1.6](https://github.com/Raidzap/Manual7/releases/tag/desktop-v0.1.6), torne-o executável e abra:

```sh
chmod +x Manual7-Studio-0.1.6-x86_64.AppImage
./Manual7-Studio-0.1.6-x86_64.AppImage
```

## Fluxo de uso

1. Abra o M7 no iPhone e mantenha a Câmera em primeiro plano.
2. Abra o AppImage e clique em **Parear iPhone**.
3. No M7, use **Conexão com o PC → Pareamento → Ler QR do PC** e leia o código exibido.
4. Digite a senha SSH do usuário `mobile`. Na primeira conexão, confira e aceite a impressão digital da chave do iPhone. Se a chave mudar (depois de reinstalar o jailbreak ou o OpenSSH, por exemplo), o Studio mostra a chave conhecida e a nova e só conecta se você tocar em **Substituir chave e conectar**; até lá a senha não é enviada.
5. Em **Formato do retorno**, escolha **Horizontal 16:9** ou **Vertical 9:16**.
6. Clique em **Iniciar retorno**. O Studio confere o formato e as dimensões confirmados pelo iPhone antes de abrir o visor.
7. ISO, shutter, EV, foco, peaking, RAW/JPEG, lente, vídeo, Reframe e rastreamento passam a usar a mesma API do painel do iPhone.

**Formato do retorno** define a imagem enviada ao visor e à câmera virtual Linux. **Formato da gravação (Reframe)** define os arquivos de vídeo salvos pelo M7 no iPhone; pode ser Horizontal, Vertical ou Ambos.

Clique no visor ao vivo para focar e medir a exposição naquele ponto (requer M7 0.7.6; modos manuais e bloqueados não mudam). Atalhos: **Espaço** dispara foto ou vídeo, **P** inicia/para o retorno e **F** (ou duplo clique no visor) alterna a tela cheia. Com a janela estreita, os controles passam para baixo do visor.

Endereços IP aparecem ocultos (`•••.•••.•••.•••`) no seletor de rede, no diálogo de SSH e nas mensagens de erro. Clique no endereço para exibi-lo; ele volta a ser ocultado após 10 segundos. O diagnóstico salvo em arquivo continua completo. Enquanto a janela estiver minimizada ou oculta, o Studio para de consultar o estado do iPhone.

**USB.** Com `usbmuxd` instalado (`sudo apt install usbmuxd`) e exatamente um iPhone ligado por cabo, o Studio conecta o SSH pelo USB e mostra **Conectado · USB**. A chave do aparelho é conferida da mesma forma; se o USB falhar por qualquer motivo que não seja senha incorreta, o Studio usa o Wi-Fi.

**Atraso e temperatura.** O chip do visor mostra fps, o atraso iPhone → PC (rede, SSH e bridges; o erro estimado do relógio aparece ao passar o mouse) e "quente" quando o iPhone limita a webcam.

**Codec.** Com um M7 que oferece H.264, o visor decodifica o stream com WebCodecs (decodificador de software do Chromium) e a câmera virtual recebe o mesmo stream, sem conversão de faixa. Com a montagem **Paisagem** (padrão) o 16:9 sai em 1920 × 1080; com **Retrato**, o 9:16 sai em 1080 × 1920. Trocar a montagem com o retorno ativo reinicia o retorno. Se o iPhone ou o decodificador não suportarem H.264, o Studio volta ao MJPEG sozinho. O visor e o FFmpeg sempre compartilham uma única conexão com o iPhone.

O QR expira em dois minutos e só pode ser usado uma vez. A senha SSH fica somente na memória do processo. O PIN recebido do iPhone permanece no processo principal e não é exposto ao renderer. A chave SSH aceita é lembrada em `~/.config/manual7-studio/known-hosts.json`.

## Câmera virtual

A prévia funciona sem configuração extra. Para apresentar o sinal a OBS, Meet ou outro programa como uma webcam V4L2, instale FFmpeg (o filtro `zscale` só é necessário no modo MJPEG) e crie um dispositivo `v4l2loopback`:

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

O arquivo final fica em `desktop/dist/Manual7-Studio-0.1.6-x86_64.AppImage`. Para troca segura ao modo Vídeo e transmissão de até 30 fps, use o M7 móvel 0.7.5 ou superior; clicar no visor para focar requer o M7 0.7.6; H.264, montagem em paisagem, latência e aviso de temperatura requerem o M7 0.7.7. A **Taxa de quadros** (30 ou 24 fps fixos, em Captura e enquadramento) requer o M7 0.7.10; com versões anteriores ela fica desativada. Com versões anteriores do M7, o Studio usa MJPEG.
