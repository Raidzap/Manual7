# Controle remoto do Manual7

O Manual7 0.6.0 executa um servidor HTTP/JSON no socket Unix `/var/tmp/Manual7-api.sock` dentro do processo Câmera. O notebook encaminha esse endpoint para `127.0.0.1:17837` por um túnel SSH autenticado; cada requisição, exceto `ping`, precisa do PIN de seis dígitos mostrado na linha **Remoto** do M7. A mesma sessão SSH encaminha `/var/tmp/Manual7-webcam.sock` para `127.0.0.1:17838`.

O primeiro teste físico da 0.5.0 retornou `EPERM` em `bind(AF_INET)` no sandbox do processo Câmera. A 0.5.1 não abre porta TCP no iPhone: cria um socket Unix com modo `0600`, acessível somente pelo usuário `mobile`, e o remove ao parar. O formato `ssh -L porta:socket_remoto` é suportado pelo OpenSSH para encaminhar uma porta TCP local a um socket Unix remoto.

O servidor de controle existe enquanto o painel M7 está aberto e o app está em primeiro plano. Um novo painel recebe outro PIN. A webcam é ligada separadamente pela interface ou pelo comando `webcam.start`. Os dois servidores param quando a Câmera vai para segundo plano; a API volta com o mesmo PIN quando o painel retorna, enquanto a webcam permanece desligada até nova solicitação.

## OpenSSH incluído na instalação

O `.deb` do M7 depende do pacote `openssh-server` do Procursus. Instalando pelo Sileo ou com `apt install ./arquivo.deb`, o gerenciador baixa o servidor e suas bibliotecas, gera chaves de host próprias do iPhone e carrega `com.openssh.sshd` no `launchd`. O M7 não define senha, não inclui chave privada e não substitui os arquivos pertencentes ao pacote oficial.

O serviço do Procursus aceita as portas 22 e 2222. O cliente abaixo testa ambas automaticamente. Configure uma senha forte ou, de preferência, uma chave pública para a conta `mobile`; não reutilize credenciais padrão. O M7 somente informa se o serviço está alcançável e registra esse estado no diagnóstico como `openSSH`.

## Preparar o iPhone e o Linux

Descubra o IP do iPhone na rede local, abra M7 e confirme que a linha Remoto mostra `SSH 22 · API Unix` ou `SSH 2222 · API Unix`. No primeiro terminal do notebook:

```sh
python3 tools/manual7_remote.py tunnel 192.168.1.50
```

Se a porta 22 estiver ativa, isso executa o equivalente a:

```sh
ssh -N \
  -L 127.0.0.1:17837:/var/tmp/Manual7-api.sock \
  -L 127.0.0.1:17838:/var/tmp/Manual7-webcam.sock \
  mobile@192.168.1.50
```

Mantenha o túnel aberto. Em outro terminal, informe o PIN que aparece no iPhone:

```sh
export MANUAL7_PIN=123456
python3 tools/manual7_remote.py ping
python3 tools/manual7_remote.py state
```

É possível usar outra porta local sem alterar o iPhone:

```sh
python3 tools/manual7_remote.py tunnel 192.168.1.50 --local-port 27837
export MANUAL7_URL=http://127.0.0.1:27837
```

Para escolher a porta SSH explicitamente:

```sh
python3 tools/manual7_remote.py tunnel 192.168.1.50 --ssh-port 2222
```

`--remote-port 17837` mantém compatibilidade com o transporte TCP da 0.5.0, embora esse transporte tenha sido negado pelo sandbox no aparelho testado.

## Ações

```sh
python3 tools/manual7_remote.py photo
python3 tools/manual7_remote.py record start
python3 tools/manual7_remote.py record stop
python3 tools/manual7_remote.py webcam start --format horizontal
python3 tools/manual7_remote.py webcam stop
python3 tools/manual7_remote.py capture
python3 tools/manual7_remote.py retry photo
python3 tools/manual7_remote.py retry videos
python3 tools/manual7_remote.py diagnostic --output relatorio-m7.json
python3 tools/manual7_remote.py watch --interval 1
python3 tools/manual7_remote.py close
```

`capture` aciona o mesmo disparador mostrado no M7: fotografa no modo Foto e inicia ou encerra no modo Vídeo. `photo` recusa a ação fora do modo Foto. `record start/stop` recusa estados incompatíveis. `webcam start/stop` controla o servidor MJPEG; `--format` aceita `horizontal` ou `vertical`. Respostas `202 Accepted` indicam que o comando foi aceito; use `state` para acompanhar a aplicação assíncrona, a gravação, o processamento, a webcam e o salvamento.

O preparo do dispositivo virtual, o comando `webcam-feed` e os limites da primeira versão estão em [WEBCAM-LINUX.md](WEBCAM-LINUX.md).

## Controles

O formato é `set CONTROLE VALOR`:

| Controle | Valores |
| --- | --- |
| `captureMode` | `photo`, `video` |
| `lens` | `wide`, `tele` |
| `exposureMode` | `auto`, `manual`, `lock` |
| `iso` | ISO real dentro de `state.limits.minISO/maxISO`; requer exposição manual |
| `shutterSeconds` | segundos, arredondados à grade de 1/3 stop; requer exposição manual |
| `evThirds` | inteiro em terços de EV; requer exposição automática |
| `focusMode` | `auto`, `manual`, `lock` |
| `focusPosition` | número de `0` a `1`; requer foco manual |
| `raw` | `true`, `false` |
| `jpegLongEdge` | `0`, `3264`, `2560`, `2048`, `1600`, `1280`; `0` significa Original |
| `videoFormat` | `horizontal`, `vertical`, `both` |
| `webcamFormat` | `horizontal`, `vertical`; requer webcam parada |
| `tracking` | `true`, `false` |
| `peaking` | `true`, `false` |
| `peakingThreshold` | número de `0.03` a `0.6` |

Exemplo de fotografia manual:

```sh
python3 tools/manual7_remote.py set captureMode photo
python3 tools/manual7_remote.py set exposureMode manual
python3 tools/manual7_remote.py set iso 100
python3 tools/manual7_remote.py set shutterSeconds 0.0078125
python3 tools/manual7_remote.py set focusMode manual
python3 tools/manual7_remote.py set focusPosition 0.42
python3 tools/manual7_remote.py set raw false
python3 tools/manual7_remote.py set jpegLongEdge 0
python3 tools/manual7_remote.py photo
```

Exemplo de vídeo com Reframe duplo e tracking:

```sh
python3 tools/manual7_remote.py set captureMode video
# Aguarde state.configured=true e state.available.shutterButton=true.
python3 tools/manual7_remote.py set videoFormat both
python3 tools/manual7_remote.py set tracking true
python3 tools/manual7_remote.py record start
python3 tools/manual7_remote.py record stop
```

## API HTTP

- `GET /v1/ping`: não exige PIN.
- `GET /v1/state`: estado atual e limites.
- `GET /v1/diagnostic`: relatório completo.
- `POST /v1/command`: ação ou alteração.

Exemplo direto com `curl` através do túnel:

```sh
curl -s -H "X-Manual7-PIN: $MANUAL7_PIN" http://127.0.0.1:17837/v1/state | jq

curl -s -X POST \
  -H "X-Manual7-PIN: $MANUAL7_PIN" \
  -H 'Content-Type: application/json' \
  -d '{"command":"set","control":"iso","value":100}' \
  http://127.0.0.1:17837/v1/command | jq
```

O servidor aceita corpo JSON de até 64 KiB, fecha a conexão após cada resposta e aplica timeout de dez segundos. Requisições malformadas, PINs incorretos, comandos bloqueados e respostas aparecem em `remoteServer` e `remoteEvents` no diagnóstico. `remoteServer` informa `transport`, `unixSocketPath` e estado da escuta; erros incluem a operação POSIX, código e motivo. `webcam` informa formato, dimensões, frames, clientes, bytes, descartes, último erro e o socket MJPEG. `openSSH` registra presença do pacote, configuração, quantidade de chaves e portas abertas, sem ler ou copiar chaves. O PIN não é copiado para os logs.

Referências: [Apple TN3179 — local network privacy](https://developer.apple.com/documentation/Technotes/tn3179-understanding-local-network-privacy), [OpenSSH `ssh(1)` — encaminhamento `-L`](https://man.openbsd.org/ssh), [controle do pacote OpenSSH no Procursus](https://github.com/ProcursusTeam/Procursus/blob/main/build_info/openssh-server.control) e [plist do `sshd`](https://github.com/ProcursusTeam/Procursus/blob/main/build_misc/openssh/com.openssh.sshd.plist).
