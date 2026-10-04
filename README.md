# Manual7 — 0.1.1 experimental

Tweak rootless para **iPhone 7 Plus, iOS 15.8.3 e Dopamine 2.2.1**. Acrescenta o botão **M7** ao aplicativo Câmera da Apple. O botão abre um modo manual com visor e disparador próprios dentro do mesmo aplicativo. Fechar esse modo devolve o controle à Câmera.

**Estado:** código compilado, vinculado e assinado para arm64 com Theos e SDK iOS 15.6, deployment target iOS 15.0. Os oito testes do núcleo C e três testes do contrato de callbacks passaram. A análise estática do controlador e do módulo JPEG não reportou problemas. **A execução no iPhone, a injeção pelo Dopamine, o salvamento no Fotos e a qualidade/alinhamento do peaking ainda não foram validados.** Esta versão corrige um defeito de callbacks encontrado após o fechamento reportado na versão anterior; a correção ainda precisa ser confirmada no iPhone.

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
| JPEG | Desligar DNG RAW seleciona JPEG. Tamanho Original ou redução para 3264, 2560, 2048, 1600 ou 1280 px no maior lado. RAW+JPEG simultâneo não faz parte desta versão. |
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

O original é gravado antes da redução. Se o redimensionamento ou a substituição atômica falhar, a imagem original permanece exportável e a interface informa a falha. DNG ignora a seleção JPEG e mantém a imagem RAW entregue pelo sensor.

## Instalar no iPhone

Baixe o pacote `.deb` e seu checksum na [pré-release v0.1.1](https://github.com/Raidzap/Manual7/releases/tag/v0.1.1).

1. Confirme que o Dopamine está ativo e a injeção de tweaks está habilitada.
2. Transfira `dev.manual7.camera_0.1.1_iphoneos-arm64.deb` para o iPhone.
3. Abra o pacote em um instalador de `.deb`, como o do Filza, se já estiver instalado. Alternativamente, em um terminal no iPhone, use o comando abaixo com o caminho real do arquivo.
4. Feche completamente a Câmera no seletor de aplicativos e abra novamente. Toque em **M7** com o iPhone desbloqueado.

Exemplo de instalação por terminal, caso tenha colocado o pacote em `/var/mobile/Downloads`:

```sh
sudo dpkg -i /var/mobile/Downloads/dev.manual7.camera_0.1.1_iphoneos-arm64.deb
```

O pacote instala a biblioteca e seu filtro em `/var/jb/Library/MobileSubstrate/DynamicLibraries`. O filtro restringe a injeção a `com.apple.camera`. A dependência `mobilesubstrate` é a interface de compatibilidade de hooking; use a implementação já fornecida pelo jailbreak.

## Usar e exportar

O visor permanece fixo acima dos controles. Deslize a área dos controles para acessar todos eles; o disparador fica na parte inferior.

- Selecione **M** para ajustar ISO e shutter. A entrada nesse modo parte da exposição medida, arredondando o tempo à grade de 1/3 stop.
- Selecione **MF** e ative **Peaking** para ajustar o foco. Um limiar menor destaca mais bordas.
- Use **AUTO** para compensação EV. **AE-L** mantém a exposição; **AF-L** mantém o foco atual. As travas são imediatas: aguarde o foco/exposição estabilizarem antes de travar.
- Para JPEG, desligue **DNG RAW** e escolha **Tamanho**. Para RAW, ative **DNG RAW**. Toque em **FOTOGRAFAR**. O disparador aguarda os callbacks de aplicação dos ajustes manuais pendentes.
- **Exportar** lista as 12 fotos mais recentes e o diagnóstico da lente. A folha de compartilhamento permite salvar no app Arquivos. Os arquivos anteriores continuam preservados na pasta de saída; a interface desta versão lista somente os 12 recentes.

Cada captura é gravada primeiro em `Documents/Manual7` dentro do contêiner da Câmera, com nome único. Quando o processo já possui autorização compatível, o tweak também solicita a inclusão no Fotos. Caso contrário, use Exportar; o tweak não altera o Info.plist da Câmera para solicitar permissões. Uma falha no Fotos não apaga o arquivo local. Exportar não remove os originais; o espaço ocupado cresce com as capturas.

`diagnostico.json` contém os limites e formatos RAW da última lente selecionada, além da versão do iOS. **Exportar → Última captura (diagnóstico)** compartilha `ultima-captura.json`, com as etapas do disparo, dimensões e erros. O arquivo sobrevive ao fechamento do aplicativo e é atualizado pela próxima tentativa; exporte-o antes de fotografar novamente se quiser preservar uma falha. Quando serializáveis, os metadados de cada foto ficam em um JSON ao lado do arquivo no contêiner; o próprio DNG/JPEG também contém seus metadados.

## Teste de aceitação no aparelho

1. Abra a Câmera → M7 e verifique se o visor aparece na grande-angular.
2. Em M, ajuste um ISO baixo e quatro posições consecutivas de shutter. Fotografe a mesma cena e confira ISO/ExposureTime no DNG em um leitor de metadados. A razão esperada dos tempos vizinhos é aproximadamente `2^(1/3)`; a razão entre o primeiro e o quarto é aproximadamente 2.
3. Arraste MF entre perto e longe diante de um objeto texturizado. Verifique foco óptico e alinhamento do verde com as bordas. O verde deve desaparecer ao desligar Peaking e não deve estar gravado na fotografia.
4. Em AUTO, compare EV −1, 0 e +1. Depois trave AE-L, mude a iluminação e confira a estabilidade de ISO/tempo. Repita AF-L aproximando e afastando um objeto.
5. Capture DNG, JPEG Original e cada tamanho JPEG, exporte e confirme dimensões, orientação, ISO/ExposureTime e reconhecimento do DNG como RAW. Compare as fotos em retrato; reabra M7 e confira que os arquivos ainda podem ser exportados.
6. Teste a teleobjetiva separadamente e exporte seu diagnóstico. Não use o resultado da grande-angular para presumir os mesmos limites.
7. Feche M7 e teste foto/vídeo na Câmera normal. Repita abrir/fechar, alternar lentes e bloquear/desbloquear o aparelho. Confirme que não há sessão presa, tela preta ou travas persistentes.
8. Teste retorno de segundo plano e captura repetida por alguns minutos, observando latência, aquecimento e uso de armazenamento.

Se ocorrer erro de sessão, a interface permite fechar e reabrir o modo. Se a Câmera não abrir após instalar, desative a injeção para ela pelo recurso disponível no jailbreak ou remova o pacote em um terminal:

```sh
sudo dpkg -r dev.manual7.camera
```

Depois feche e reabra a Câmera. A remoção do pacote não apaga as capturas existentes no contêiner.

## Arquitetura e limites desta versão

`Tweak.m` instala o botão e intercepta somente `AVCaptureSession startRunning/stopRunning` para suspender sessões nativas enquanto M7 controla a câmera, conservando a intenção de retomada. `M7CameraController` possui uma sessão AVFoundation separada, operada em fila serial. `M7DeviceControls` aplica os controles sob `lockForConfiguration`. `M7Math` implementa a grade de shutter, mapeamento ISO e detecção Sobel. `M7JPEG` usa ImageIO para a redução exclusiva de JPEG, preservando o tamanho original quando solicitado.

O modo M7 tem interface em retrato, captura apenas pelas lentes traseiras e usa flash desligado. Não inclui vídeo, Live Photos, HDR computacional, modo Retrato, câmera frontal, ProRAW ou controle do disparador nativo enquanto M7 está aberto. O botão M7 exige disponibilidade dos dados protegidos do aparelho; a operação pela tela bloqueada não é suportada neste protótipo. A arbitragem com a Câmera nativa ainda depende de validação real no iOS 15.8.3.

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

Eles verificam bytes idênticos em Original, ausência de ampliação, três tamanhos menores, orientações 1/6/8, dimensões EXIF, ISO, tempo de exposição e rejeição de entrada inválida. **Esses testes nativos não foram executados neste ambiente Linux**; o código foi verificado sintaticamente com o SDK iOS. A captura e a leitura dos arquivos gerados no iPhone continuam sendo parte necessária da validação.

Consulte `BUILD.txt` para as versões efetivamente usadas neste pacote. As ferramentas de build não estão incluídas no arquivo de código-fonte.

## Visualizador de crashes

[KrashKop, da FoxFortMobile, no Havoc](https://havoc.app/package/krashkop) informa compatibilidade com iOS 15.0–16.7.1 e rootless. Procure por KrashKop no Sileo. Após um fechamento, procure o relatório mais recente de Camera; o relatório do sistema pode complementar o `ultima-captura.json` do M7.

## Fontes técnicas

- [Apple — compatibilidade de câmeras](https://developer.apple.com/library/archive/documentation/DeviceInformation/Reference/iOSDeviceCompatibility/Cameras/Cameras.html): suporte RAW no iPhone 7/7 Plus e escolha de lentes físicas para RAW/controles manuais. As tabelas históricas não substituem a consulta em tempo de execução no iOS 15.8.3.
- [Apple — captura RAW e ProRAW](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats): formatos disponíveis, captura e representação DNG.
- [Apple — exposição manual](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:)): priorização de velocidade para respeitar ISO e duração manuais.
- [Apple — foco manual](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setfocusmodelocked(lensposition:completionhandler:)): posição da lente e trava.
- [Theos — rootless](https://theos.dev/docs/rootless): empacotamento e arquitetura.
- [Dopamine — repositório oficial](https://github.com/opa334/Dopamine): jailbreak rootless.

- [Apple — protocolo de callbacks](https://developer.apple.com/documentation/avfoundation/avcapturephotocapturedelegate?language=objc): nomes Objective-C e callbacks obrigatórios conforme o tipo de captura.
