# Pareamento por QR no Linux

O Manual7 0.7.0 elimina a digitação do IP do iPhone e do PIN. O script Linux abre um callback temporário na rede local, cria um QR de uso único e aguarda o M7. No iPhone, **Conexão → Ler QR do PC** usa os frames do visor e o Vision para reconhecer o código. O M7 envia ao callback o IP de origem do iPhone, o PIN atual e a porta OpenSSH que ele comprovou estar ativa; em seguida o script abre os túneis da API e da webcam.

O QR vence após 90 segundos por padrão. O token é aleatório, aceito uma vez, enviado ao `qrencode` pela entrada padrão e removido da memória de estado após o retorno. PIN e token não entram nos relatórios do M7. O callback aceita somente a rota de pareamento, limita o corpo a 16 KiB e vincula-se ao IPv4 privado escolhido no notebook.

## Preparar o notebook

Em Debian ou Ubuntu:

```sh
sudo apt update
sudo apt install qrencode openssh-client python3
```

O iPhone e o notebook precisam estar na mesma rede local, sem isolamento entre clientes Wi-Fi. Configure antes a autenticação SSH da conta `mobile`; uma chave pública evita pedir a senha a cada conexão.

## Parear e abrir o túnel

Na raiz do repositório:

```sh
python3 tools/manual7_pair.py
```

O script detecta o IPv4 local, mostra o QR no terminal e escuta por até 90 segundos. No iPhone:

1. Abra Câmera → **M7** e aguarde a linha Remoto mostrar `SSH 22` ou `SSH 2222`.
2. Toque em **Ler QR do PC**.
3. Aponte o visor para o QR do terminal.
4. No Linux, confirme a chave do host e autentique o usuário `mobile` se o SSH solicitar.

O terminal passa a manter os dois encaminhamentos:

```text
127.0.0.1:17837 -> /var/tmp/Manual7-api.sock
127.0.0.1:17838 -> /var/tmp/Manual7-webcam.sock
```

O script mostra um comando `export MANUAL7_PIN=...` para uso em outro terminal. Depois disso, os comandos existentes continuam iguais:

```sh
export MANUAL7_PIN=123456
python3 tools/manual7_remote.py ping
python3 tools/manual7_remote.py state
python3 tools/manual7_remote.py photo
python3 tools/manual7_remote.py webcam-feed --device /dev/video10 --format horizontal
```

Se a detecção automática escolher a interface errada, informe o IPv4 que está na mesma rede do iPhone:

```sh
python3 tools/manual7_pair.py --listen-host 192.168.1.20
```

Para salvar também um PNG, testar somente o retorno ou trocar as portas locais:

```sh
python3 tools/manual7_pair.py --output manual7-pair.png
python3 tools/manual7_pair.py --no-tunnel
python3 tools/manual7_pair.py --local-port 27837 --webcam-local-port 27838
```

## Diagnóstico

O relatório registra `pairingScanStarted`, `pairingCodeRecognized`, `pairingAccepted`, rejeição, timeout, cancelamento e erro de rede. `pairing` contém estado, contadores, horários e somente host/porta do callback; token e PIN são omitidos. `sessionNow` informa se a leitura, análise ou submissão está ativa.

Se o QR não for reconhecido, aumente o terminal, reduza reflexos, mantenha o código inteiro dentro do visor e tente novamente. Se o callback falhar, confira o firewall do notebook e o isolamento Wi-Fi. No iOS, permita acesso à rede local se o sistema apresentar a solicitação. O callback usa HTTP somente na LAN; o token de uso único autentica esse retorno curto. A sessão permanente, a API e o MJPEG continuam protegidos pelo OpenSSH.

O processo Câmera permanece em primeiro plano durante o pareamento. Ir ao segundo plano, fechar o painel, interromper a sessão ou tocar em **Cancelar QR** invalida a tentativa. O M7 não altera senha, chave ou configuração do OpenSSH.

Referências: [Apple — detecção de códigos de barras com Vision](https://developer.apple.com/documentation/vision/vndetectbarcodesrequest), [Apple — privacidade de rede local](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) e [OpenSSH `ssh(1)`](https://man.openbsd.org/ssh).
