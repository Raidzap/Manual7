# Manual7 — 0.7.5 experimental

Tweak rootless para **iPhone 7 Plus, iOS 15.8.3 e Dopamine 2.2.1**. Acrescenta o botão **M7** ao aplicativo Câmera da Apple. O botão abre um modo manual com visor e disparador próprios dentro do mesmo aplicativo. Fechar esse modo devolve o controle à Câmera.

**Estado:** JPEG foi confirmado pelo usuário como salvo no Fotos na 0.1.3. RAW e RAW + JPEG chegaram ao callback de processamento, mas falharam antes de produzir pixel buffer ou bytes com AVFoundation −11800 / OSStatus −12780, inclusive com somente `AVCapturePhotoOutput`, zoom 1× e sessão ativa. A 0.7.4 moveu a API remota para um bridge `launchd` fora do sandbox da Câmera. A 0.7.5 corrige o modo da webcam e remove os limites artificiais de 10 fps. **RAW, vídeo, Reframe, rastreamento e a webcam otimizada ainda precisam de validação física completa no iPhone.**

## Manual7 Studio para Linux

O cliente gráfico em [desktop/README.md](desktop/README.md) reúne o pareamento por QR, autenticação SSH, visor MJPEG e todos os controles remotos em uma interface semelhante ao módulo do iPhone. Ele também envia o retorno para uma câmera virtual `v4l2loopback`, permitindo usar a imagem já ajustada no OBS, Meet e outros programas. A distribuição é um AppImage x86_64; Electron e as bibliotecas do cliente ficam dentro do arquivo. Baixe-o na [release desktop-v0.1.2](https://github.com/Raidzap/Manual7/releases/tag/desktop-v0.1.2).

O Studio 0.1.2 envia imediatamente a escolha **Horizontal 16:9** ou **Vertical 9:16**, impede que a atualização periódica restaure o formato anterior e só abre o visor depois que o iPhone confirma o formato e as dimensões correspondentes. **Formato do retorno** controla a webcam/OBS; **Formato da gravação (Reframe)** controla os vídeos salvos no iPhone.

## Webcam estável na 0.7.5

Ao ativar a webcam, o M7 agora troca primeiro para **Vídeo**, espera a sessão 4:3 a 30 fps ficar ativa e só então abre o endpoint MJPEG. A troca de volta para Foto fica bloqueada até desligar a webcam, evitando reconstruir a topologia do `AVCaptureSession` com um cliente de frames conectado.

O limite fixo de 10 fps foi removido do iPhone e do FFmpeg. O encoder tenta processar cada frame entregue pela câmera; quando o A10 ou a rede não acompanha, descarta trabalho antigo e conserva somente o frame mais recente. O servidor mantém no máximo um frame pendente, evitando que uma conexão SSH lenta aumente continuamente a latência e a memória. O bridge usa buffers maiores e blocos de 64 KiB.

`webcam.inputFrames`, `encodedFrames`, `busyDrops`, tempos de codificação e `server.framesSubmitted`, `framesPublished`, `framesCoalesced`, `effectiveFPS` e tamanho do último JPEG mostram separadamente sensor, encoder e transporte. O FFmpeg converte explicitamente JPEG full-range para YUV limited-range, eliminando os avisos de pixel format depreciado sem interpretar a faixa de luminância de forma ambígua.

## OpenSSH e controle remoto

O pacote agora declara `openssh-server` como dependência. Durante a instalação pelo Sileo ou `apt`, o pacote oficial do Procursus instala o `sshd`, gera as chaves exclusivas do aparelho e registra `com.openssh.sshd` no `launchd`. O M7 não inclui senha, chave privada ou cópia própria dos binários do OpenSSH.

O M7 verifica a instalação em `/var/jb`, as chaves de host e as portas 22 e 2222. A linha **Remoto** mostra a porta SSH ativa, `API bridge` e o PIN. O mesmo estado aparece em `state.openSSH` e `openSSH` no diagnóstico. O LaunchDaemon `dev.manual7.bridge` publica a API e a webcam somente no loopback do iPhone, nas portas 27839 e 27840, e também mantém os sockets Unix `0600` para diagnóstico. O processo Câmera faz apenas conexões de saída para o bridge, contornando a proibição de `bind` imposta pelo sandbox. O PIN de seis dígitos é renovado quando um novo painel M7 é aberto e é exigido em todas as rotas de estado, diagnóstico e comando.

## Inicialização e bridge remoto na 0.7.4

O teste físico confirmou que o notebook alcançava a porta 22 e autenticava no OpenSSH, enquanto o sandbox da Câmera impedia criar os sockets públicos. As tentativas anteriores também eram executadas de forma síncrona em `viewDidLoad`, atrasando toda a interface quando a API não respondia.

A 0.7.4 instala um processo auxiliar mínimo pelo `launchd`. Ele recebe workers autenticados da Câmera e publica endpoints TCP somente em `127.0.0.1`, que o OpenSSH encaminha sem depender do suporte a Unix stream forwarding do iOS. Workers encerrados são removidos antes de atender o próximo cliente, e um handshake confirma cada worker antes de entregar HTTP. O painel agenda a API em uma fila própria; a câmera e os controles iniciam imediatamente. Cada conexão inicial tem limite de 250 ms, não há mais sequência de fallbacks bloqueantes e as reconexões usam espera de um segundo. `remoteStartup`, `remoteBindAttempts` e `remoteEvents` registram fila, motivo, duração, geração, timeout e erro.

O cliente `tools/manual7_remote.py`, feito apenas com a biblioteca padrão do Python, consulta estado, copia diagnóstico, fotografa, inicia/para vídeo e webcam, repete salvamentos pendentes e altera modo, lente, exposição, ISO, shutter, EV, foco, RAW, tamanho JPEG, Reframe, tracking e peaking. Cada requisição aceita, recusada ou malformada é contabilizada; comandos e resultados aparecem em `remoteEvents`, e comandos feitos durante vídeo também entram em `lastVideo.events`. O PIN não é registrado.

O fluxo completo, comandos e valores aceitos estão em [API-REMOTE.md](API-REMOTE.md). O [pareamento por QR](PAIRING-LINUX.md) exibe um código de uso único, o botão **Ler QR do PC** reconhece o notebook e o Linux abre os dois túneis sem digitar o IP do iPhone ou copiar o PIN para configurar a conexão.

## Pareamento QR na 0.7.0

Execute `python3 tools/manual7_pair.py` no notebook e toque em **Conexão → Ler QR do PC** no M7. O leitor reutiliza a saída de vídeo já ativa e limita a análise Vision a 3 Hz. Após reconhecer o QR, o iPhone faz um callback temporário com o PIN da sessão e as portas SSH comprovadamente abertas; o script usa o endereço de origem do callback como IP do iPhone e inicia a API em `127.0.0.1:17837` e a webcam em `127.0.0.1:17838`.

O token do QR vence, só funciona uma vez e não é gravado. O PIN também continua ausente dos diagnósticos. Estados, tempos, host/porta, erros e contadores ficam em `pairing` e `sessionEvents`. A rede persistente continua sob OpenSSH; o callback HTTP existe apenas durante o pareamento na rede local. Instalação, opções e solução de problemas estão em [PAIRING-LINUX.md](PAIRING-LINUX.md).

## Webcam SSH na 0.6.0

O controle **Webcam** inicia um servidor MJPEG no mesmo diretório Unix selecionado para a API, também com permissão `0600` e autenticação pelo PIN atual. O túnel do cliente encaminha simultaneamente a API para `127.0.0.1:17837` e o vídeo para `127.0.0.1:17838`. No Linux, `webcam-feed` usa FFmpeg para alimentar uma câmera virtual `v4l2loopback` que pode ser selecionada no OBS, navegador ou aplicativo de reunião.

Os frames vêm da mesma saída AVFoundation e recebem as alterações de ISO, shutter, EV, foco, travas e lente. **WC formato** escolhe 1280 × 720 horizontal ou 720 × 1280 vertical. Quando **Rastrear** está ativo, o centro suavizado da pessoa/rosto dirige o recorte da webcam. O alvo é 30 fps; o FPS efetivo depende do tempo de codificação no A10 e da vazão Wi-Fi/SSH, sem acumular uma fila atrasada.

Esta versão transmite somente vídeo. O focus peaking não é queimado no sinal. Um formato de webcam é emitido por vez; a exportação local de vídeo continua oferecendo **Ambos**. Ao ir para segundo plano, fechar M7 ou perder a sessão, o socket e os clientes são encerrados. Estado, formato, clientes, frames, bytes, descartes e erros do encoder ficam em `webcam` e `sessionEvents` no relatório.

Veja a preparação do Linux e o uso completo em [WEBCAM-LINUX.md](WEBCAM-LINUX.md).

## Vídeo, Reframe e rastreamento na 0.3.0

O seletor **Modo** alterna entre Foto e Vídeo. O modo Vídeo mantém ISO, shutter em 1/3 stop, AUTO/M/AE-L, AF/MF/AF-L, compensação EV e focus peaking. Os ajustes podem mudar durante a gravação. A lente, o modo de captura e o formato de saída ficam bloqueados enquanto o master está sendo gravado ou processado.

O M7 seleciona em tempo de execução o melhor formato 4:3 que a lente física oferece a 30 fps, dando preferência a resoluções de até 1920 × 1440 para limitar a carga no A10. Se a lente não expuser um formato 4:3 adequado, usa o formato mais próximo e registra `fourThirds: false`, dimensões, pixel format, faixa de ISO e exposição no relatório.

O seletor **Reframe** oferece:

- **16:9:** gera um MP4 horizontal 1920 × 1080.
- **9:16:** gera um MP4 vertical 1080 × 1920.
- **Ambos:** grava uma vez e gera os dois arquivos a partir do mesmo take.

O controle **Rastrear** usa Vision para procurar uma pessoa, aceitando o tronco superior, e usa detecção de rosto quando não encontra um retângulo humano. A análise é limitada a 5 vezes por segundo em uma fila separada. O candidato escolhido combina área e proximidade da posição anterior; o centro é suavizado e cada deslocamento é limitado para reduzir saltos. Após cinco análises sem detecção, o enquadramento retorna gradualmente ao centro. O círculo da guia fica verde quando há detecção e amarelo quando o assunto foi perdido.

O rastreamento atua no recorte depois da gravação. O master 4:3 continua intacto. Cada ponto recebe o tempo relativo do sample buffer gravado, e o Reframe interpola transformações entre esses pontos. Com **Rastrear** desligado, sem pontos válidos ou após uma falha do Vision, a exportação usa o centro. Em uma cena com várias pessoas, a seleção favorece a maior pessoa próxima do alvo anterior; esta versão não permite tocar para escolher uma identidade específica.

A gravação cria um master H.264 temporário a partir dos sample buffers do `AVCaptureVideoDataOutput` e acrescenta AAC quando o microfone está autorizado e disponível. O Reframe ocorre após parar: duas composições usam o mesmo master e preservam a faixa de áudio. Esse desenho mantém as saídas sincronizadas sem depender de multicâmera. As linhas no visor mostram os recortes simultâneos.

Os arquivos finais são enviados ao Fotos um por vez. O master é removido somente depois do processamento. Se o Fotos falhar, o MP4 fica pendente na pasta temporária e **Exportar → Tentar salvar vídeos pendentes** repete a inclusão. Se a exportação do enquadramento falhar, o master 4:3 é preservado como recuperação. Ao reabrir M7, MP4/MOV temporários são descobertos novamente. O fechamento exige salvar ou descartar explicitamente qualquer vídeo pendente.

`lastVideo` registra configuração, autorização de microfone/Fotos, espaço disponível, estado do writer, frames gravados, frames descartados, backpressure, áudio, arquivo master, geometria e status de cada exportação, resultado do Fotos, identificador do asset e limpeza. Para rastreamento, registra detector, frequência, número total de pontos, amostragem do relatório, tempos, centros, confiança, candidatos humanos/rostos, caixas do Vision, perdas consecutivas e erros. Até 600 pontos são incluídos no relatório copiado; `totalPoints` e `reportStride` indicam eventual redução. `trackingNow`, `videoWriterNow`, `videoFormat` e `pendingVideos` aparecem no diagnóstico geral. Mudanças de ISO, shutter, foco, EV, travas, lente, peaking e rastreamento são correlacionadas com a gravação.

## Correção RAW/DNG na 0.7.1

O relatório anterior mostrou `rgg4` (`kCVPixelFormatType_14Bayer_RGGB`) em `availableRawPhotoPixelFormatTypes`, mas a configuração usava somente esse inventário geral. A API da Apple também exige que o formato esteja na lista aceita pelo tipo de arquivo escolhido. A 0.7.1 exige `AVFileTypeDNG` em `availableRawPhotoFileTypes`, cruza os formatos com `supportedRawPhotoPixelFormatTypesForFileType:`, escolhe somente Bayer nessa interseção e cria a captura com DNG explícito. O teste combinado valida também o par codec/contêiner JPEG.

Para Bayer RAW, a configuração usa prioridade `Speed`, estabilização automática desligada, flash desligado, zoom e recorte 1× e alta resolução desligada no pedido RAW. `maxPhotoQualityPrioritization` é definido antes de iniciar a sessão. O M7 também chama `setPreparedPhotoSettingsArray:` depois de cada troca de lente ou topologia, preparando RAW e RAW + JPEG antes do disparo. O disparador aguarda até três segundos pela preparação e pelo término dos ajustes de exposição/foco; se o foco contínuo continuar se movendo, envia o pedido e marca `timedOut` no relatório.

O relatório agora inclui `rawCompatibility`, com tipos de arquivo, valores numéricos, FourCC, classificação Bayer, formatos DNG aceitos e formato selecionado; `rawPreparation`, com resultado da alocação antecipada; e, em `submit`, `rawFileType`, `processedFileType`, estabilização e prioridade efetivas. O código −12780 não possui um nome público documentado, portanto o M7 registra toda a cadeia `NSError` sem atribuir a ele um significado inventado.

Em **Exportar → Testar RAW DNG explícito**, o M7 remove a saída de vídeo, configura AUTO/AF e solicita DNG e JPEG no mesmo disparo. O JPEG acompanhante serve apenas para diagnóstico; somente um DNG genuíno é encaminhado ao Fotos.

## Captura de compatibilidade na 0.1.6

O teste anterior removeu a saída de vídeo, configurou AUTO/AF e solicitou RAW e JPEG no mesmo disparo. O aparelho confirmou que essa combinação também falhava com −11800 / −12780 antes de produzir bytes. O JPEG nunca substitui o RAW nem é convertido para DNG.

O relatório registra cada callback separadamente, com formato, ID, presença e dimensões do pixel buffer, erro e tamanho do arquivo. `representationSkipped` significa que o callback falhou antes de chamar `fileDataRepresentation`; `representation` com `attempted: true` significa que houve tentativa de gerar o arquivo. Um buffer ausente em um formato comprimido não basta, isoladamente, para diagnosticar falha do sensor. Os callbacks RAW/JPEG podem chegar em qualquer ordem: o JPEG nunca substitui o RAW nem apaga seu erro.

O relatório automático é congelado ao terminar e abre com o título **Teste RAW DNG** e um identificador curto. **Último teste RAW DNG** reabre exatamente esse resultado mesmo depois de outra foto ou de fechar/reabrir o M7 dentro do mesmo processo Câmera. Encerrar o processo apaga essa cópia em memória. **Ver diagnóstico** gera um relatório separado, intitulado **Estado atual**. `reportOrigin`, `reportID` e `lastComparison.mode` identificam a origem e o tipo do teste.

O teste verifica que resta apenas `AVCapturePhotoOutput` antes da submissão. **Restaurar saída de peaking** é uma ação separada. O modo sem saída de vídeo persiste entre instâncias do M7 dentro do mesmo processo.

## Correção de armazenamento na 0.1.3

No processo Câmera, os caminhos retornados para Documents e Application Support podem apontar para `/var/mobile`, sem autorização de gravação. O diagnóstico confirmou `NSCocoaErrorDomain` 513 nos dois caminhos, com sessão configurada e em execução. A 0.1.2 encerrava a tentativa antes de enviar o disparo ao AVFoundation, porque exigia uma cópia local gravável.

Agora a captura prossegue mesmo quando essa cópia não é possível. M7 mantém os dados JPEG/DNG codificados e os entrega ao PhotoKit com `addResourceWithType:data:options:`. A biblioteca Fotos é o destino principal; Documents e Application Support servem apenas para uma cópia opcional. Não é necessário alterar permissões dessas pastas nem escrever diretamente na base de dados da galeria.

Se o Fotos confirmar a inclusão, a interface mostra **Salvo no Fotos** e libera a próxima captura. Se houver erro e nenhuma cópia local, o M7 conserva uma foto pendente na memória. **SALVAR FOTO PENDENTE**, ou a ação equivalente em Exportar, tenta incluir a mesma imagem novamente. Um novo disparo não substitui essa foto. Ao tentar fechar, M7 avisa sobre a imagem não salva; uma falha permite tentar novamente, continuar ou descartar explicitamente e fechar. A memória não sobrevive a encerramento forçado, reinicialização ou término do processo pelo iOS.

A autorização é consultada antes da importação. Uma solicitação de acesso de adição ocorre somente quando o estado e a declaração de permissões já existente no aplicativo permitem. M7 não modifica o Info.plist da Câmera. Uma recusa ou falha do PhotoKit aparece na interface e no diagnóstico.

**Exportar → Ver diagnóstico → Copiar diagnóstico** funciona sem Filza e sem pasta gravável. `recentPhotosResults` registra os resultados desta sessão; `pendingPhotoBytes` indica dados pendentes na memória. Quando existe cópia local, o resultado também vai para `.photos.json`. A confirmação impede repetir uma importação já concluída, mas não acompanha exclusões posteriores feitas no Fotos.

## Correção de captura na 0.1.1

A implementação anterior usava `photoOutput:didFinishProcessingPhoto:error:` e `photoOutput:didFinishCaptureForResolvedSettings:error:`. Esses nomes não são os seletores Objective-C de AVFoundation: a forma correta começa com `captureOutput:`. O protocolo original declara os callbacks como opcionais, mas exige o callback de processamento ao disparar RAW ou JPEG, lançando `NSInvalidArgumentException` se ele estiver ausente. Isso explica um caminho concreto de fechamento nos dois formatos.

O relatório recebido do aparelho mostra `EXC_CRASH (SIGABRT)` com `objc_exception_throw` em `AVCapturePhotoOutput capturePhotoWithSettings:delegate:`, na fila `dev.manual7.session`. O UUID da biblioteca corresponde ao pacote 0.1.0, e os símbolos desse build mapeiam o offset 60604 para o bloco de `M7CameraController capture`. O relatório não inclui a mensagem textual da exceção; o contrato ausente foi verificado separadamente no SDK e no código.

Os dois seletores foram corrigidos. Um protocolo adicional os torna obrigatórios na compilação, e os testes negativos verificam que voltar à grafia incorreta faz o build falhar. A captura também valida a conexão, o formato e a alta resolução, trata exceções síncronas, registra as etapas e libera a interface se não houver término em 30 segundos. Esse tratamento não intercepta falhas de memória, encerramentos pelo sistema ou exceções em threads internas do iOS.

## Recursos

| Controle | Comportamento |
| --- | --- |
| ISO | Slider logarítmico, com limites lidos do formato ativo. Em M, ISO e tempo ficam explícitos. |
| Shutter | Grade exata de 1/3 stop: `t(k) = 2^(k/3)` segundos. ISO e shutter são aplicados ao soltar o slider. O visor mostra o valor reportado pelo dispositivo. |
| DNG RAW | Captura Bayer RAW com `AVCapturePhotoOutput`; usa `fileDataRepresentation` para obter o arquivo. Desabilitado quando a lente/sessão não expõe RAW. |
| JPEG | Desligar DNG RAW seleciona JPEG. Tamanho Original ou redução para 3264, 2560, 2048, 1600 ou 1280 px no maior lado. RAW+JPEG simultâneo está restrito ao teste de compatibilidade. |
| Vídeo | Master H.264 em formato próximo de 4:3 a 30 fps, AAC quando o microfone está disponível e ajustes manuais durante a gravação. |
| Reframe | Exportação 1920 × 1080, 1080 × 1920 ou as duas a partir do mesmo master, preservando áudio. Centralizado com rastreamento desligado. |
| Rastreamento | Pessoa com tronco superior e rosto como fallback via Vision, análise máxima de 5 Hz, suavização e retorno gradual ao centro quando o alvo é perdido. |
| Controle remoto | API HTTP/JSON em socket Unix com PIN por sessão e cliente Python para Linux através de túnel SSH. |
| Pareamento QR | QR de uso único reconhecido com Vision; callback local entrega porta SSH/PIN ao script, que abre os túneis sem digitar o IP do iPhone. |
| Webcam Linux | MJPEG autenticado no túnel SSH, 1280 × 720 ou 720 × 1280 com alvo de 30 fps e fila de frame mais recente, entregue a `v4l2loopback` por FFmpeg. |
| Foco manual | Posição normalizada de 0 a 1, sem inferir distância em metros; atualiza durante o arraste com limitação de frequência. |
| Focus peaking | Bordas em verde, limiar ajustável, análise de luminância reduzida a até 480 pixels na maior dimensão e no máximo 10 atualizações/s. |
| Compensação EV | Passos de 1/3 EV em AUTO, dentro dos limites do aparelho. Em M, o fotômetro auxilia o ajuste de ISO e shutter. |
| AE-L / AF-L | Travas independentes. AUTO e AF liberam as respectivas travas. M e MF já fixam os parâmetros manuais. |
| Lentes | Seleção física de grande-angular 1× ou teleobjetiva 2×. A troca reinicia exposição/foco em automático. |

A grade usa passos matematicamente exatos. Por exemplo, um ponto da grade é 1/128 s, próximo ao valor nominal fotográfico 1/125 s. Os limites de hardware não são adicionados como passos artificiais. A duração aplicada ainda pode sofrer quantização pelo sensor; confira o DNG. Não há promessa de exposições longas além do limite informado pelo formato ativo.

O foco por bordas é um auxílio visual: textura, ruído de ISO alto e contraste também influenciam o destaque. Os limites de resolução/frequência são definidos no código; fluidez, consumo e aquecimento precisam ser medidos no A10.

## Tamanhos JPEG

Com **DNG RAW desligado**, toque em **Tamanho**. Original solicita a maior resolução fotográfica do formato ativo usando as APIs do iOS 15 e preserva o JPEG recebido, sem recodificá-lo. As opções menores mantêm a proporção, nunca ampliam e usam JPEG com qualidade de codificação 0,95. Quando há redução, ImageIO aplica a orientação aos pixels e atualiza os metadados de dimensão/orientação, conservando os campos fotográficos, como ISO e tempo de exposição.

Para uma foto de 4032 × 3024, as opções são:

| Opção | Dimensões em paisagem |
| --- | --- |
| Original | 4032 × 3024 |
| 3264 | 3264 × 2448 |
| 2560 | 2560 × 1920 |
| 2048 | 2048 × 1536 |
| 1600 | 1600 × 1200 |
| 1280 | 1280 × 960 |

As dimensões mostradas no menu vêm da lente/formato ativos; opções acima da resolução nativa são omitidas. Na imagem orientada em retrato, largura e altura podem aparecer invertidas. O diagnóstico registra as dimensões efetivas do arquivo salvo.

O original permanece na memória durante a redução. Se ela falhar, o M7 envia o JPEG original ao Fotos e registra `resizeError` no diagnóstico. A cópia local opcional contém o mesmo JPEG enviado ao Fotos. DNG ignora a seleção JPEG e mantém a imagem RAW entregue pelo sensor.

## Instalar no iPhone

Baixe o pacote `.deb` e seu checksum na [release v0.7.5](https://github.com/Raidzap/Manual7/releases/tag/v0.7.5).

1. Confirme que o Dopamine está ativo e a injeção de tweaks está habilitada.
2. Confirme que o repositório Procursus está habilitado no gerenciador de pacotes do bootstrap.
3. Transfira `dev.manual7.camera_0.7.5_iphoneos-arm64.deb` para o iPhone e abra-o no Sileo, que resolverá a dependência `openssh-server`. Alternativamente, use `apt` como abaixo.
4. Feche completamente a Câmera no seletor de aplicativos e abra novamente. Toque em **M7** com o iPhone desbloqueado.

Exemplo de instalação por terminal, caso tenha colocado o pacote em `/var/mobile/Downloads`:

```sh
cd /var/mobile/Downloads
sudo apt install ./dev.manual7.camera_0.7.5_iphoneos-arm64.deb
```

Use `apt` ou Sileo nesta versão: `dpkg -i` sozinho não baixa uma dependência ausente. O pacote instala a biblioteca e seu filtro em `/var/jb/Library/MobileSubstrate/DynamicLibraries`. O filtro restringe a injeção a `com.apple.camera`. As dependências `mobilesubstrate` e `openssh-server` são fornecidas pelo ambiente rootless/Procursus; o script do OpenSSH carrega o serviço no `launchd`.

## Usar e exportar

O visor permanece fixo acima dos controles. Deslize a área dos controles para acessar todos eles; o status e o disparador ficam fixos na parte inferior.

- Selecione **M** para ajustar ISO e shutter. A entrada nesse modo parte da exposição medida, arredondando o tempo à grade de 1/3 stop.
- Selecione **MF** e ative **Peaking** para ajustar o foco. Um limiar menor destaca mais bordas.
- Use **AUTO** para compensação EV. **AE-L** mantém a exposição; **AF-L** mantém o foco atual. As travas são imediatas: aguarde o foco/exposição estabilizarem antes de travar.
- Para JPEG, desligue **DNG RAW** e escolha **Tamanho**. Para RAW, ative **DNG RAW**. Toque em **FOTOGRAFAR**. O disparador aguarda os callbacks de aplicação dos ajustes manuais pendentes.
- Para vídeo, selecione **Vídeo**, escolha **16:9**, **9:16** ou **Ambos** em Reframe. Ative **Rastrear** para seguir automaticamente uma pessoa ou deixe desligado para recorte central. Toque em **GRAVAR VÍDEO**, toque novamente para parar e mantenha o M7 aberto até o Fotos confirmar as saídas.
- Para conectar o notebook, instale `qrencode`, execute `python3 tools/manual7_pair.py`, toque em **Ler QR do PC** e siga [PAIRING-LINUX.md](PAIRING-LINUX.md). Para conexão manual e todos os comandos, consulte [API-REMOTE.md](API-REMOTE.md).
- Para usar o iPhone como webcam no Linux, carregue `v4l2loopback`, abra o túnel e execute `webcam-feed` conforme [WEBCAM-LINUX.md](WEBCAM-LINUX.md). ISO, shutter, foco, EV, lente e rastreamento permanecem ajustáveis no painel ou pelo notebook.
- **Exportar** lista até 12 cópias locais recentes, **Ver diagnóstico** e a ação de salvar uma foto pendente, quando houver. Ao selecionar uma foto, escolha **Adicionar ao Fotos** ou **Compartilhar**. A folha de compartilhamento permite salvar no app Arquivos e oferece as ações disponíveis no sistema para o formato selecionado. Fotos anteriores continuam preservadas; a interface lista somente as 12 recentes.

As capturas confirmadas ficam no app Fotos. **Exportar pode ficar sem imagens mesmo após um salvamento bem-sucedido**, pois lista somente cópias locais. Quando o processo consegue gravá-las, o caminho aparece em `outputDirectory`; caso contrário, esse campo fica vazio. Uma falha no Fotos não apaga uma cópia local existente. Exportar não remove arquivos; o espaço ocupado pelas cópias cresce com as capturas.

**Exportar → Ver diagnóstico → Copiar diagnóstico** reúne estado atual da sessão, pastas verificadas, quantidade de fotos locais, etapas da última captura, resultados do Fotos e capacidades da lente. Cole o texto na conversa para análise. Se não houver nenhuma foto local, essa tela continua disponível. O diagnóstico em memória funciona durante a sessão mesmo quando a gravação falha; copie antes de fechar o aplicativo nesse caso.

Quando o armazenamento funciona, `ultima-captura.json` preserva as etapas após o fechamento, até uma nova tentativa; `diagnostico.json` registra os limites da lente. Quando serializáveis, os metadados de cada foto ficam em um JSON ao lado da imagem; o próprio DNG/JPEG também contém seus metadados.

## Teste de aceitação no aparelho

1. Abra a Câmera → M7 e verifique se o visor aparece na grande-angular.
2. Em M, ajuste um ISO baixo e quatro posições consecutivas de shutter. Fotografe a mesma cena e confira ISO/ExposureTime no DNG em um leitor de metadados. A razão esperada dos tempos vizinhos é aproximadamente `2^(1/3)`; a razão entre o primeiro e o quarto é aproximadamente 2.
3. Arraste MF entre perto e longe diante de um objeto texturizado. Verifique foco óptico e alinhamento do verde com as bordas. O verde deve desaparecer ao desligar Peaking e não deve estar gravado na fotografia.
4. Em AUTO, compare EV −1, 0 e +1. Depois trave AE-L, mude a iluminação e confira a estabilidade de ISO/tempo. Repita AF-L aproximando e afastando um objeto.
5. Comece com AUTO, AF, lente 1×, RAW desligado e JPEG Original: use FOTOGRAFAR dentro do M7, confira a mensagem, a lista Exportar e o Fotos. Se falhar, copie Ver diagnóstico antes de tentar outra foto. Depois capture DNG, JPEG Original e cada tamanho JPEG, exporte e confirme dimensões, orientação, ISO/ExposureTime e reconhecimento do DNG como RAW. Compare as fotos em retrato; reabra o app Fotos e confirme que as imagens continuam disponíveis. Se houver cópias locais, confira também Exportar após reabrir M7.
6. Teste a teleobjetiva separadamente e exporte seu diagnóstico. Não use o resultado da grande-angular para presumir os mesmos limites.
7. Feche M7 e teste foto/vídeo na Câmera normal. Repita abrir/fechar, alternar lentes e bloquear/desbloquear o aparelho. Confirme que não há sessão presa, tela preta ou travas persistentes.
8. Teste retorno de segundo plano e captura repetida por alguns minutos, observando latência, aquecimento e uso de armazenamento.
9. Com as pastas locais negadas, confirme que o diagnóstico avança de `localBackupUnavailable` para `submit`, `encodedPhotoReady`, importação com `source: data` e `state: saved`. Se o Fotos falhar, confirme `pendingPhotoBytes > 0`, nova tentativa sem novo disparo e aviso ao fechar. Esses fluxos precisam ser verificados no aparelho.
10. Em Vídeo/Ambos, grave ao menos 15 s com áudio. Confirme dois assets no Fotos, um 1920 × 1080 e outro 1080 × 1920, mesma duração, áudio sincronizado e conteúdo central coerente com as duas guias.
11. Durante outra gravação, altere ISO/shutter, foco, EV e travas. Confirme efeito visual e eventos `controlChange`; confira `videoFrames`, `audioSamples`, `droppedVideoFrames` e backpressure.
12. Repita 16:9, 9:16 e Ambos em cada lente. Interrompa uma gravação indo ao segundo plano e confirme finalização ou erro explícito. Se o Fotos falhar, use **Tentar salvar vídeos pendentes** sem gravar novamente.
13. Ative Rastrear, mantenha uma pessoa no quadro e mova-a lentamente da esquerda para a direita e de cima para baixo. Confirme círculo verde durante a detecção, guias móveis e movimento suave nos dois vídeos. Saia do quadro por mais de um segundo e confirme retorno gradual ao centro. Repita com duas pessoas e com apenas o rosto visível. Copie o diagnóstico e confira `tracking.totalPoints`, `detections`, `misses`, `points` e `dynamicReframe`.
14. Confirme que a linha Remoto mostra `SSH 22 · API bridge` ou `SSH 2222 · API bridge`. No Linux, abra o túnel SSH, configure `MANUAL7_PIN` e execute `ping` e `state`. Verifique `state.openSSH` e `state.remoteServer.transport: launchd-bridge-unix`, altere cada controle remoto, fotografe JPEG, inicie/pare um vídeo e obtenha `diagnostic`. Confirme no iPhone que a interface acompanha as alterações e confira `remoteStartup`, `openSSH`, `remoteServer` e `remoteEvents`. Teste PIN incorreto, segundo plano e fechamento do painel; a API deve recusar conexões nesses estados.
15. Execute `manual7_pair.py`, leia o QR pelo botão **Ler QR do PC** e confirme que o script identifica o IP/porta do iPhone e abre os dois túneis. Repita com token inválido, timeout, cancelamento, firewall bloqueando o callback e segundo plano. Verifique `pairing`, ausência de PIN/token no relatório e os eventos `pairingScanStarted`, `pairingCodeRecognized` e `pairingAccepted` ou erro explícito.
16. No Linux, crie `/dev/video10` com `v4l2loopback`, execute `webcam-feed` em 16:9 e selecione **Manual7 Webcam** em um consumidor V4L2. Altere ISO, shutter, foco, EV e lente durante o uso; confirme o efeito sem reiniciar. Repita em 9:16, com rastreamento ligado, PIN incorreto e segundo plano. No diagnóstico, verifique `webcam.server.clientCount`, `framesPublished`, `bytesPublished`, `busyDrops`, dimensões, permissões `0600` e ausência de erros.

Se ocorrer erro de sessão, a interface permite fechar e reabrir o modo. Se a Câmera não abrir após instalar, desative a injeção para ela pelo recurso disponível no jailbreak ou remova o pacote em um terminal:

```sh
sudo dpkg -r dev.manual7.camera
```

Depois feche e reabra a Câmera. A remoção do pacote não apaga as capturas existentes no contêiner.

## Arquitetura e limites desta versão

`Tweak.m` instala o botão e intercepta somente `AVCaptureSession startRunning/stopRunning` para suspender sessões nativas enquanto M7 controla a câmera, conservando a intenção de retomada. `M7CameraController` possui uma sessão AVFoundation separada, operada em filas seriais de sessão, mídia, rastreamento, webcam e pareamento. `M7PairingManager` valida o URI, reconhece QR com Vision e envia o callback temporário sem incluir segredos no snapshot. `M7RemoteServer` atende HTTP/JSON no socket Unix e encaminha comandos autenticados para as mesmas ações da interface. `M7WebcamEncoder` recorta o pixel buffer com Core Image e codifica JPEG; `M7WebcamServer` envia multipart MJPEG autenticado por outro socket Unix. `M7OpenSSHStatus` verifica o pacote e os sockets do serviço sem executar comandos privilegiados. `M7DeviceControls` aplica os controles e seleciona o formato de vídeo. `M7VideoRecorder` grava os sample buffers em um master H.264/AAC. `M7SubjectTracker` analisa pessoas/rostos com Vision. `M7VideoReframe` interpola os recortes 16:9/9:16. `M7Math` implementa a grade de shutter, mapeamento ISO e detecção Sobel. `M7JPEG` usa ImageIO para JPEG. `M7Storage` mantém as cópias opcionais e relatórios.

O modo M7 tem interface em retrato, usa as lentes traseiras e mantém flash/torch desligados. Vídeo é 30 fps; não inclui 4K garantido, 60/120/240 fps, estabilização eletrônica, HDR, Live Photos, modo Retrato, câmera frontal, ProRAW, escolha manual de identidade, rastreamento de objetos genéricos ou controle do disparador nativo. A webcam não transmite áudio e entrega um formato por vez. O rastreamento detecta novamente a pessoa/rosto a cada análise; pessoas que se cruzam podem trocar de prioridade. O controle remoto e a webcam requerem M7 aberto, iPhone desbloqueado e túnel até os sockets Unix; eles não iniciam a Câmera nem desbloqueiam o iPhone. A autenticação e a exposição do SSH à rede continuam sob a configuração do OpenSSH/Procursus. Resolução/fps efetivos do master dependem dos formatos expostos pela lente no iOS 15.8.3 e aparecem no relatório. A carga térmica, a latência MJPEG e o desempenho do Vision/Core Image no A10 ainda precisam de medição física.

## Compilar e testar

Configure Theos com um compilador iOS e SDK 15.6. A variável `THEOS` deve apontar para essa instalação. O Makefile seleciona arm64, rootless e deployment target 15.0.

```sh
make clean package FINALPACKAGE=1
THEOS="$THEOS" python3 -m unittest discover -s tests -v
```

Os testes C são executáveis em Linux com Python 3 e `cc`. Cobrem limites de hardware, extremos da grade, razão entre os passos, arredondamento logarítmico, ISO, rejeição de entradas inválidas, strides de imagem e diferença entre bordas nítidas e desfocadas. Não simulam o sensor nem os frameworks da Apple. Com `THEOS` apontando para o compilador Linux e SDK iOS 15.6, também rodam três testes de compilação dos callbacks: código atual aceito e duas regressões de nome rejeitadas. Sem esse ambiente, os testes de contrato são explicitamente ignorados.

Para executar os testes reais de codificação JPEG/ImageIO em um Mac com Command Line Tools:

```sh
bash tests/run_jpeg_native.sh
```

Eles verificam bytes idênticos em Original, ausência de ampliação, três tamanhos menores, orientações 1/6/8, dimensões EXIF, ISO, tempo de exposição e rejeição de entrada inválida. Esses testes nativos passaram no runner macOS do GitHub Actions na 0.1.6; não são executáveis no ambiente Linux de build. A captura e a leitura dos arquivos gerados no iPhone continuam sendo parte necessária da validação.

O teste `bash tests/run_storage_native.sh` exercita gravação real com Foundation no macOS: pasta principal, alternativa, busca de imagens nas duas pastas e erro quando nenhuma pode ser usada. Esse teste passou no runner macOS do GitHub Actions na 0.1.6. Ele não simula as permissões de sandbox/TCC da Câmera no iPhone.

O teste `bash tests/run_error_details_native.sh` usa Foundation no macOS para verificar erro interno, JSON e limite de recursão. Passou no runner macOS do GitHub Actions na 0.1.6.

`bash tests/run_video_reframe_native.sh` cria um master H.264 real, verifica a geometria aspect-fill central e móvel e exporta arquivos 16:9 e 9:16 com AVFoundation. `bash tests/run_video_recorder_native.sh` cobre término sem frames, diagnóstico e cancelamento idempotente. `bash tests/run_subject_tracker_native.sh` executa o caminho sem pessoa em um pixel buffer real, conferindo rastros temporizados, estado, reset e JSON. Esses testes exigem macOS e não simulam câmera, microfone, PhotoKit, temperatura, uma pessoa real ou capacidade de codificação do iPhone.

A suíte da 0.7.5 também valida a seleção pela interseção Bayer/DNG e a representação FourCC, além de compilar e exercitar o LaunchDaemon, autenticação dos workers, descarte de worker encerrado, endpoint TCP loopback, transportes TCP e Unix da API, MJPEG, parser/retorno de pareamento, Vision, tokens de uso único, permissões `0600`, autenticação por PIN, multipart, geometria dos recortes, JPEG 1280 × 720 e 720 × 1280, cadência de 30 fps, fila limitada ao frame mais recente, conversão explícita de faixa de cor, contadores, desligamento, detecção do OpenSSH, túnel duplo e comandos dos clientes Python. O reconhecimento positivo do QR continua como validação obrigatória no iPhone.

A suíte completa passou no [GitHub Actions](https://github.com/Raidzap/Manual7/actions/runs/38035846130).

Consulte `BUILD.txt` para as versões efetivamente usadas neste pacote. As ferramentas de build não estão incluídas no arquivo de código-fonte.

## Visualizador de crashes

[KrashKop, da FoxFortMobile, no Havoc](https://havoc.app/package/krashkop) informa compatibilidade com iOS 15.0–16.7.1 e rootless. Procure por KrashKop no Sileo. Após um fechamento, procure o relatório mais recente de Camera; o relatório do sistema pode complementar o `ultima-captura.json` do M7.

## Fontes técnicas

- [Apple — compatibilidade de câmeras](https://developer.apple.com/library/archive/documentation/DeviceInformation/Reference/iOSDeviceCompatibility/Cameras/Cameras.html): suporte RAW no iPhone 7/7 Plus e escolha de lentes físicas para RAW/controles manuais. As tabelas históricas não substituem a consulta em tempo de execução no iOS 15.8.3.
- [Apple — captura RAW e ProRAW](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats): formatos disponíveis, captura e representação DNG.
- [Apple — exposição manual](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:)): priorização de velocidade para respeitar ISO e duração manuais.
- [Apple — foco manual](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setfocusmodelocked(lensposition:completionhandler:)): posição da lente e trava.
- [Apple — formato ativo](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat): seleção do formato e duração de frame dentro da configuração da sessão.
- [Apple — gravação em tempo real](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/05_Export.html): AVAssetWriter com entradas marcadas como fontes em tempo real.
- [Apple — composição de vídeo](https://developer.apple.com/documentation/avfoundation/avassetexportsession/videocomposition): aplicação de transformações e render size durante a exportação.
- [Apple — detecção de pessoas](https://developer.apple.com/documentation/vision/vndetecthumanrectanglesrequest): retângulos de pessoas e opção de tronco superior no Vision.
- [Apple — detecção de rostos](https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest): retângulos normalizados de rostos usados como fallback.
- [Apple — rampas de transformação](https://developer.apple.com/documentation/avfoundation/avmutablevideocompositionlayerinstruction/settransformramp(fromstart:toend:timerange:)): interpolação temporal aplicada ao recorte durante a exportação.
- [Apple — privacidade de rede local](https://developer.apple.com/documentation/Technotes/tn3179-understanding-local-network-privacy): distinção entre aceitar TCP e iniciar conexões para a LAN, inclusive para BSD sockets.
- [OpenSSH — `ssh(1)`](https://man.openbsd.org/ssh): encaminhamento local `-L` usado para transportar a API de loopback.
- [v4l2loopback — README oficial](https://github.com/v4l2loopback/v4l2loopback/blob/main/README.md): criação da câmera virtual, número, nome e `exclusive_caps` para Chrome/WebRTC.
- [FFmpeg — dispositivos](https://ffmpeg.org/ffmpeg-devices.html): entrada/saída de dispositivos usada pelo alimentador V4L2.
- [Procursus — dependências do `openssh-server`](https://github.com/ProcursusTeam/Procursus/blob/main/build_info/openssh-server.control): pacote oficial solicitado pelo M7.
- [Procursus — serviço `com.openssh.sshd`](https://github.com/ProcursusTeam/Procursus/blob/main/build_misc/openssh/com.openssh.sshd.plist): socket activation nas portas 22 e 2222 no ambiente rootless.
- [Procursus — instalação do serviço](https://github.com/ProcursusTeam/Procursus/blob/main/build_info/openssh-server.extrainst_): carregamento do plist pelo `launchctl` do bootstrap.
- [Theos — rootless](https://theos.dev/docs/rootless): empacotamento e arquitetura.
- [Dopamine — repositório oficial](https://github.com/opa334/Dopamine): jailbreak rootless.

- [Apple — protocolo de callbacks](https://developer.apple.com/documentation/avfoundation/avcapturephotocapturedelegate?language=objc): nomes Objective-C e callbacks obrigatórios conforme o tipo de captura.

- [Apple — autorização no PhotoKit](https://developer.apple.com/documentation/photos/phphotolibrary/requestauthorization(for:handler:)): solicitação de acesso ao Fotos.
- [Apple — descrição de acesso de adição](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryaddusagedescription): declaração exigida para solicitar esse acesso.

- [Apple — recurso PhotoKit a partir de dados](https://developer.apple.com/documentation/photos/phassetcreationrequest/addresource(with:data:options:)): inclusão dos bytes codificados sem arquivo intermediário obrigatório.

## Verificação automatizada

`tests/run_capture_result_native.sh` exercita o seletor de resultados usado em produção com Foundation: ambas as ordens de callbacks, isolamento de RAW, sucesso JPEG, erro de processamento/término, bytes vazios, ausência de RAW e callbacks atrasados/duplicados/de outra captura. Os dados desse teste são fixtures; não simulam um sensor nem validam um DNG.

O workflow `.github/workflows/native-tests.yml` executa os programas nativos de captura, erros, armazenamento, JPEG/ImageIO, gravação, Reframe, rastreamento, reconhecimento QR, servidor remoto, encoder e servidor MJPEG em macOS, além dos testes C e dos clientes Python. Os contratos de compilação iOS são executados separadamente no ambiente Theos Linux. Resultados da versão são registrados em `BUILD.txt`. Esses testes não substituem a validação da câmera, microfone, Fotos, callback local, túnel SSH, V4L2, detecção real, desempenho e temperatura no iPhone.
