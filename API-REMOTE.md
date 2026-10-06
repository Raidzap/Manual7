# Controle remoto do Manual7

O Manual7 0.4.0 executa um servidor HTTP/JSON apenas em `127.0.0.1:17837` dentro do processo Câmera. A porta não é exposta diretamente ao Wi‑Fi. O notebook chega a ela por um túnel SSH autenticado e cada requisição, exceto `ping`, precisa do PIN de seis dígitos mostrado na linha **Remoto** do M7.

Essa arquitetura segue a distinção documentada pela Apple: escutar e aceitar TCP não exige acesso à rede local, enquanto iniciar uma conexão TCP para um endereço da LAN exige. O M7 também evita Bonjour e interfaces Wi‑Fi, mantendo o listener apenas no loopback. O encaminhamento `ssh -L` cria a porta no notebook e pede ao lado remoto para conectar ao loopback do iPhone por dentro do canal SSH.

O servidor existe enquanto o painel M7 está aberto e o app está em primeiro plano. Um novo painel recebe outro PIN. O servidor para quando a Câmera vai para segundo plano e volta com o mesmo PIN quando o painel retorna.

## Preparar o iPhone e o Linux

Instale e habilite um servidor OpenSSH compatível com o ambiente rootless do Dopamine. Descubra o IP do iPhone na rede local e abra M7. No primeiro terminal do notebook:

```sh
python3 tools/manual7_remote.py tunnel 192.168.1.50
```

Isso executa o equivalente a:

```sh
ssh -N -L 17837:127.0.0.1:17837 mobile@192.168.1.50
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

## Ações

```sh
python3 tools/manual7_remote.py photo
python3 tools/manual7_remote.py record start
python3 tools/manual7_remote.py record stop
python3 tools/manual7_remote.py capture
python3 tools/manual7_remote.py retry photo
python3 tools/manual7_remote.py retry videos
python3 tools/manual7_remote.py diagnostic --output relatorio-m7.json
python3 tools/manual7_remote.py watch --interval 1
python3 tools/manual7_remote.py close
```

`capture` aciona o mesmo disparador mostrado no M7: fotografa no modo Foto e inicia ou encerra no modo Vídeo. `photo` recusa a ação fora do modo Foto. `record start/stop` recusa estados incompatíveis. Respostas `202 Accepted` indicam que o comando foi aceito; use `state` para acompanhar a aplicação assíncrona, a gravação, o processamento e o salvamento.

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

O servidor aceita corpo JSON de até 64 KiB, fecha a conexão após cada resposta e aplica timeout de dez segundos. Requisições malformadas, PINs incorretos, comandos bloqueados e respostas aparecem em `remoteServer` e `remoteEvents` no diagnóstico. O PIN não é copiado para os logs.

Referências: [Apple TN3179 — local network privacy](https://developer.apple.com/documentation/Technotes/tn3179-understanding-local-network-privacy) e [OpenSSH `ssh(1)` — encaminhamento `-L`](https://man.openbsd.org/ssh).
