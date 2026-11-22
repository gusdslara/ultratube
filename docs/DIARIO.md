# Ultratube: diário de desenvolvimento

> Registro das rodadas de trabalho. O README principal fica na raiz do repositório.
> Caminhos como `C:\dev\tv\Ultratube` são da máquina de desenvolvimento; `verification/`
> agora é `docs/verificacao/`, e `reference-zenith/` (pesquisa antiga) não faz parte do repositório.

Projeto separado de MeuTube e KidsTV. O aplicativo principal parte do
[PPPlayer](https://github.com/ppplayer-labs/app), conforme solicitado.

## Estrutura

- `ppplayer/`: clone editável do PPPlayer (Flutter), com remoção do SDK de anúncios,
  identidade Android `app.ultratube.mobile` e uma nova área de Shorts.
- `android/media/`: catálogo YouTube/YouTube Music via NewPipeExtractor, letras via
  LRCLIB e serviço de reprodução Media3, independente de WebView.
- `android/wear/`: aplicativo nativo Wear OS independente para Galaxy Watch 7.
- `artifacts/Ultratube-WearOS-debug.apk`: APK de desenvolvimento compilado e instalado
  no Watch 7 conectado. Não é uma versão de produção.
- `verification/`: evidências de validação.
- `reference-zenith/`: clone Tauri pesquisado antes da identificação do PPPlayer.
  É apenas referência técnica; não representa um port pronto do Ultratube.

## Estado real

O usuário escolheu evoluir o PPPlayer em Flutter em 16/11/2026. Flutter é a base
principal; não será feito um port Tauri nesta implementação. `reference-zenith/`
fica apenas como material de pesquisa anterior.

### Implementado

- Remoção da dependência Google Mobile Ads, inicialização, IDs e inserções
  promocionais da cópia do PPPlayer. No Android, a reprodução não usa mais o
  player/WebView do YouTube: o áudio/vídeo é resolvido via NewPipeExtractor e
  tocado pelo MediaKit, então não há anúncios do YouTube no fluxo.
- Downloads offline (celular e relógio, motor compartilhado em `android/media`):
  fila em serviço de primeiro plano com notificação de progresso, áudio M4A na
  melhor taxa, vídeo 720p/1080p (faixa de vídeo + áudio juntadas com MediaMuxer,
  sem recodificar), capa salva junto, cancelar/tentar de novo/apagar, retomada
  após o app ser fechado. No celular os arquivos entram na Biblioteca com título,
  canal e capa do catálogo. Ficam em `Android/data/<app>/files/downloads`.
- SponsorBlock: patrocínio, autopromoção, pedido de inscrição e trechos sem
  música são pulados automaticamente (consulta por prefixo de hash, sem enviar o
  ID do vídeo).
- Reprodução contínua: quando a fila de um vídeo/música do YouTube está acabando,
  o app acrescenta os "a seguir" do próprio YouTube (respeita a opção de autoplay).
- Menu de cada resultado: tocar em seguida, adicionar à fila, baixar áudio,
  baixar vídeo 720p/1080p. Aba "Downloads" na navegação do celular.
- Cliente estilo YouTube/ReVanced no celular (sem conta Google, tudo local):
  - Início: feed "Para você" (uploads recentes das inscrições + "a seguir" do
    que você assistiu + Em alta, intercalados) e categorias do próprio YouTube
    (Em alta, Música, Ao vivo, Games, Podcasts), com prateleira de Shorts e
    rolagem infinita.
  - Inscrições: inscrever-se em canais, feed cronológico (RSS de cada canal,
    em paralelo), importação do Google Takeout (`subscriptions.csv`) ou de
    exportações JSON do NewPipe/LibreTube, e cópia da lista.
  - Canal: banner, avatar, inscritos, descrição, abas Vídeos/Shorts/Ao vivo.
  - Assistir: vídeo até 4K (faixa de vídeo + áudio separadas, qualidade
    escolhida no ⚙), toque duplo ±10 s, tela cheia, título/descrição,
    curtidas, canal com Inscrever-se, Baixar, Só áudio, Fila, comentários e
    "A seguir" com reprodução contínua.
  - Shorts: feed vertical automático (sem colar links), em loop, com canal,
    Inscrever-se, compartilhar e baixar.
  - Busca com sugestões, buscas recentes e filtros Tudo/Vídeos/Músicas/Canais/Shorts.
  - Histórico (pausar, limpar, remover item) — alimenta o "Para você".
- Rodada de acabamento (17/11/2026):
  - "A seguir" confiável: quando a fila acaba, o app busca os relacionados e
    toca de fato (antes só agendava); autoplay próprio do Ultratube (ligado por
    padrão, botão no player e na fila); o próximo vídeo é resolvido durante a
    reprodução do atual (cache de 45 min, descartado em erro).
  - Fila em folha estilo YouTube: arrastar para reordenar, deslizar para
    remover, embaralhar, repetir, limpar "a seguir" e salvar como playlist.
  - Playlists: abrir playlists do YouTube (paginação, Reproduzir tudo,
    Aleatório, salvar na biblioteca), playlists locais (criar, renomear,
    reordenar, remover) e "Vídeos curtidos" (Curtir agora funciona).
  - Tela "Você": histórico, playlists, downloads, arquivos do aparelho e
    ajustes (qualidade, autoplay, SponsorBlock, pausar histórico).
  - Capas em alta: cards e player usam a maior miniatura; capas do YouTube
    Music são pedidas em 1080 px (antes vinham em 60–120 px).
  - Busca: filtros Playlists, Álbuns e Clipes, continuação automática quando
    uma página vem vazia e aviso "Mostrando resultados para…".
  - Identidade própria: ícone adaptativo (com monocromático), splash, logo
    interno, ícone do relógio e da notificação — "U" branco com play sobre
    vermelho. Tema preto OLED + vermelho único, barra inferior e miniplayer
    estilo YouTube (vídeo ao vivo dentro do miniplayer). Gerador:
    `ppplayer/tool/brand.py` (geometria única para PNG e vetores; `python tool/brand.py . ../android/media/src/main/res`).
- Rota `/shorts`, navegação móvel/desktop, importação de links de Shorts, deduplicação,
  lista local persistente e páginas verticais. A seleção mantém o ID exato do vídeo,
  sem substituí-lo por uma busca musical. Shorts não iniciam recomendações musicais.
- Wear OS (0.2.0): nova interface redonda (capa, progresso, anterior/play/próxima),
  busca por voz/texto, fila de verdade (cada item é resolvido só quando vai tocar,
  URLs vencidas são renovadas e um vídeo com erro não derruba a fila), tocar em
  seguida, downloads offline no próprio relógio, favoritos, letra, timer para
  pausar (15–90 min), serviço MediaSession/Media3, foco de áudio e rolagem rotativa.
- Conteúdo e erros reais; sem catálogo ou reprodução simulados.

### Validação em 16/11/2026

- `:wear:assembleDebug :wear:assembleDebugAndroidTest`: PASS.
- Instalação e abertura no Samsung SM-L300 (Galaxy Watch 7): PASS.
- Teste instrumental no relógio: 20 resultados reais de música, resolução de
  endereço HTTPS e leitura de 2048 bytes do áudio: PASS. O teste não iniciou som.
- Validação de URLs Shorts (10 casos incluindo domínios falsos): PASS.
- Análise estática dos arquivos alterados de Shorts, player, navegação e remoção
  de anúncios: PASS, `No issues found!`. `git diff --check`: PASS.
- Reprodução audível, tela apagada, reconexão Bluetooth, bateria e letras no
  dispositivo: ainda não validados.
- A interface Shorts e a compilação completa do PPPlayer ainda precisam de teste.
- `flutter pub get` resolveu dependências e removeu `google_mobile_ads`, mas o passo
  de integração dos plugins parou porque o Windows não disponibiliza criação de
  links simbólicos nesta sessão. O Modo de Desenvolvedor não foi alterado.

## Compilar o relógio

Requisitos: JDK 17+, Android SDK 35 e acesso ao Maven/JitPack.

```powershell
cd C:\dev\tv\Ultratube\android
$env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr'
.\gradlew.bat :wear:assembleDebug
```

O `local.properties` é local e não deve ser versionado. O serviço compartilhado
aceita HTTPS e domínios YouTube explícitos. As URLs de mídia são resolvidas novamente
a cada reprodução; favoritos armazenam o vídeo, não um endereço temporário.

## Executar o fork PPPlayer

```powershell
cd C:\dev\tv\Ultratube\ppplayer
flutter pub get
flutter analyze
flutter run
dart tool/check_ultratube_links.dart
```

O upstream exige Dart >=3.12 e pode depender de credenciais locais para metadados
Spotify. Não há credenciais copiadas ou incluídas neste projeto.

## iOS

O iPhone usa a mesma interface do Android (feed, busca, canal, playlist, Assistir,
Shorts, comentários, conta, downloads, SponsorBlock) e o mesmo player próprio
(MediaKit, sem iframe nem anúncios). Como o NewPipeExtractor é Java, o catálogo
no iOS é um port em Dart com os mesmos métodos e formatos de JSON:

- `lib/core/api/innertube.dart`: cliente da API web do YouTube (`/youtubei/v1`)
  e parsers dos renderers (videoRenderer, lockupViewModel, Shorts, canais,
  playlists, YouTube Music).
- `lib/core/api/dart_catalog.dart`: busca (inclusive Músicas/Álbuns/Artistas),
  sugestões, categorias, feed RSS das inscrições, canal e abas, playlist, vídeo,
  relacionados, comentários, letras e resolução de streams (`youtube_explode_dart`).
- `lib/core/ultratube/dart_account.dart`: conta do YouTube opcional. O login abre a
  página do Google num WKWebView sem dados persistentes; os cookies do youtube.com
  ficam no Keychain.
- `lib/core/downloads/dart_downloads.dart`: fila de downloads; vídeo acima de 360p
  é juntado (MP4 + M4A) pelo AVFoundation sem recodificar.
- `ios/Runner/AppDelegate.swift` (`UltratubeIOSHost`): login e mux nativos.

O Android continua no NewPipe nativo. Gerar o `.ipa` sem assinatura: GitHub Actions
› "Ultratube iOS (unsigned IPA)" (`.github/workflows/ios.yml`). Instalar por
Sideloadly/AltStore com Apple ID; com conta grátis a assinatura vale 7 dias.

Limites no iOS: downloads pausam com o app em segundo plano e continuam ao voltar;
sem Picture-in-Picture (o MediaKit não usa AVPlayer); a categoria Games/Podcasts do
NewPipe não existe mais e foi trocada por Notícias/Esportes; o login do Google em
WebView pode ser recusado pelo Google em algumas contas.

## Próximas entregas

1. Validar o aplicativo principal Flutter com o backend nativo Android.
2. Integrar o backend nativo Android ao player principal e testar áudio/vídeo/Shorts.
3. Busca e descoberta de Shorts (hoje a área importa links), letras sincronizadas,
   alternância capa/vídeo sem perder posição e persistência da fila.
4. Testes de reprodução em segundo plano, interrupções, Bluetooth e bateria no Watch 7.
5. Recursos adicionais: temporizador, controle de autoplay, playlists, histórico,
   importação/exportação e sincronização opcional entre celular e relógio.

“Tudo que o YouTube não oferece” permanece um direcionamento de produto, não uma
lista finita de recursos concluídos. Android e Wear são a prioridade de validação.
O catálogo Dart do iOS foi validado contra o YouTube real a partir do Windows; o app
iOS em si ainda precisa ser compilado no Actions e testado num iPhone.
Windows/macOS/Linux do upstream não foram recompilados nesta etapa.

## Origem e licenças

- PPPlayer commit `6cea891ad31bb88a1d4ac1a0c524a57c795632e7`, licença preservada em
  `ppplayer/assets/LICENSE` (MIT, PPPlayer Music).
- Zenith commit `e5af6fbebc6fa59df480dcbc9e4a6252ed6c3c20`, licença preservada na referência.
- NewPipeExtractor `v0.27.1`, GPL-3.0: os módulos novos em `android/` são distribuídos
  sob GPL-3.0-or-later; a licença MIT original dos outros componentes é preservada.
- Media3 e OkHttp: Apache-2.0. Consulte também os avisos de cada dependência.

Os instaladores e atualizadores dos upstreams não devem ser publicados como
Ultratube antes de substituir identidade, assinatura, ícones e endpoints de atualização.

### Relógio 0.4.0 (testado no Galaxy Watch 7, 17/11/2026)

- Player em tela cheia com 3 páginas no deslize horizontal: controles
  (esquerda) · vídeo/capa com anel de progresso na borda (centro) · fila,
  baixar e timer (direita). Botão voltar: página lateral → centro → sai,
  com a reprodução continuando.
- Vídeo no relógio: faixa de vídeo até 360p + áudio unidos sob demanda.
  Toque duplo alterna "vídeo inteiro" e "preencher a tela"; botões para só
  áudio/vídeo sem perder a posição. Tela fica acesa só enquanto o vídeo toca.
- Shorts: fila vertical (deslize para cima/baixo), preenchendo o círculo.
  Vídeos bloqueados pelo YouTube são pulados automaticamente.
- Segundo plano/tela apagada: o decodificador de vídeo é liberado e o áudio
  continua (verificado por `dumpsys media.resource_manager`).
- Limite conhecido: alguns Shorts genéricos retornam "This video is not
  available" no NewPipeExtractor v0.27.1 (único cliente visionOS); são
  pulados. Coroa giratória controla o volume (não testável via adb).

### Celular 1.0.2 (testado no S23, release com R8, 17/11/2026)

- Início, categorias (Música/Ao vivo/Games/Podcasts/Trailers), busca, canal
  e tela Assistir em HD funcionando na build release.
- "Em alta" removido: o YouTube encerrou a página Trending global em 2025 e o
  kiosk do NewPipe falha sempre. "Para você" usa as categorias que funcionam e,
  sem histórico/inscrições, buscas populares.
- Paisagem: tela Assistir entra em tela cheia automaticamente; feed em grade
  (2–4 colunas); barra inferior e miniplayer compactos.
- Shorts: Short que não inicia em 12 s ou dá erro é pulado; canais com
  restrição saem da fila e do histórico (não contaminam as próximas buscas).
- Pendência: em 17/11 às ~21:45, após muitos testes seguidos, praticamente
  todos os Shorts passaram a retornar UNPLAYABLE no NewPipeExtractor v0.27.1,
  enquanto músicas e vídeos comuns continuavam tocando. Possível limitação
  temporária do YouTube para o IP ou mudança no cliente visionOS; revalidar
  mais tarde ou após atualização do extrator.

### Relógio 0.4.1 — busca (17/11/2026)

- O ✓ do teclado Samsung (Honeyboard) agora executa a busca na hora, no último
  tipo usado (padrão: Músicas). Antes ele só fechava o teclado e parecia não
  fazer nada.
- Resultados com seletor Músicas · Vídeos · Shorts para a mesma busca; buscas
  recentes na tela de busca; erro de rede com "Tentar de novo".
- Testado no Galaxy Watch 7 com o teclado real: digitar → ✓ → resultados →
  Vídeos → vídeo tocando em tela cheia.
### Celular — lives, Perguntar e Twitch (18/11/2026)

- **Lives do YouTube**: o resolvedor marca a mídia como ao vivo (HLS, DASH como
  reserva) e o player deixa de esperar uma duração que lives não têm (antes a
  tela Assistir ficava carregando para sempre). Controles de live: selo AO VIVO,
  "Voltar ao vivo" depois de pausar, sem barra de busca nem toque duplo ±10 s.
- **Chat ao vivo** (YouTube e Twitch, sem conta): sobre o vídeo, transparente,
  com fundo ajustável (0–90 %), tamanho do texto e botão para ligar/desligar;
  painel completo abaixo do vídeo com "N novas mensagens". YouTube via
  `/live_chat` + `youtubei/v1/live_chat/get_live_chat` (Super Chat e membros
  destacados). Código: `lib/core/live/`, `lib/features/live/`.
- **Contador de espectadores** ("assistindo agora", `youtubei/v1/updated_metadata`
  a cada 20 s; Twitch a cada 30 s), com chave liga/desliga nos ajustes do chat.
- **Perguntar (Gemini)**: botão ✦ na tela Assistir com sugestões (Resumir o
  vídeo, Pontos principais, Recomendar relacionados, Explicar de um jeito
  simples; em lives: O que está acontecendo agora, Do que o chat está falando).
  Usa as legendas do vídeo (youtube_explode) com marcas de tempo tocáveis que
  pulam o vídeo; sem legendas, o Gemini assiste o próprio vídeo (URL do
  YouTube, resolução baixa, até 2 h); em lives, título/descrição + chat recente.
  Chave do Google AI Studio do próprio usuário, guardada no armazenamento
  seguro; modelo padrão `gemini-flash-latest` (ajustável em Você › Ajustes).
- **Aba Twitch** (nova aba na barra inferior): Seguindo (local, sem conta; ao
  vivo primeiro), Ao vivo agora (filtro de idioma, padrão Português),
  Categorias, busca de canais/categorias, página do canal com transmissões
  anteriores (VODs), player com qualidade (incl. só áudio), chat com emotes
  Twitch/7TV/BTTV e badges, contador e tempo de live. Código: `lib/core/twitch/`,
  `lib/features/twitch/`.
- **Twitch sem anúncios**: `TwitchProxy` é um proxy HLS local (127.0.0.1) que
  reescreve só a playlist. Segmentos de anúncio (inseridos pela Twitch no
  servidor) nunca chegam ao player; durante o intervalo o mesmo momento vem de
  um token reserva (embed/popout/autoplay), juntado por PROGRAM-DATE-TIME com
  marca de descontinuidade. Sem reserva limpa, a imagem segura até o intervalo
  acabar. A tela mostra "Anúncio bloqueado".
- Limites conhecidos: a Twitch exige token de integridade para paginar, então
  "Ao vivo agora" traz as 30 maiores e cada categoria até 80 lives de uma vez.
- Lives do YouTube tocam **uma** variante HLS (respeitando a qualidade máxima)
  + a playlist de áudio do grupo: com o manifesto mestre o player abria todas
  as variantes em paralelo, o YouTube recusava um dos handshakes TLS e a live
  caía (achado no teste do emulador). Uma falha de live agora tenta de novo
  uma vez antes de pular para o próximo vídeo.
- Validado no Windows contra os serviços reais: API Twitch (destaques, categorias,
  busca, canal, VODs), proxy com ffmpeg (25 s normal e 45 s alternando principal
  ↔ reserva 6 vezes, sem erro), chat do YouTube e da Twitch ao vivo (mensagens,
  emotes, badges, contador), legendas para o Perguntar. `flutter analyze`: 0
  erros. Falta validar no S23: reprodução das lives no MediaKit, overlay e
  gestos, e o Perguntar com uma chave real.

### Relógio 0.5 e desktop (18/11/2026)

- **Relógio — fim do "processo invisível"**: a notificação de reprodução agora
  é uma *Ongoing Activity* do Wear OS (ícone do Ultratube no mostrador enquanto
  toca, que leva de volta ao player) com Pausar/Próxima/**Parar**. Fechar o app
  (voltar na tela inicial ou remover dos recentes) para a música e encerra o
  serviço; sair pela coroa continua tocando, com o ícone para voltar. Pausado
  e sem nenhuma tela do Ultratube aberta, o serviço se encerra sozinho em 5 min.
- **Correção Android 16 (Galaxy Watch 7)**: com o voltar preditivo o
  `onBackPressed` nunca era chamado — o voltar das sub-telas saía do app e
  fechar não parava nada. Agora usa `OnBackInvokedDispatcher`.
- **Relógio — Twitch e lives do YouTube**: "Twitch ao vivo" (mais vistas em
  português + busca de canal) e "Lives do YouTube". Twitch toca em vídeo 360p
  (segure para só áudio) com o mesmo filtro de anúncios do celular, portado
  para Kotlin (`android/media/.../Twitch.kt`, servido ao ExoPlayer como
  playlist gerada). Lives do YouTube tocam uma variante HLS + áudio. O player
  mostra "● AO VIVO" e alterna vídeo/só áudio também em lives.
- Validado no Galaxy Watch 7 (Android 16): Twitch em vídeo, 60 s no mostrador
  continuando a tocar com o ícone, voltar das sub-telas, fechar → serviço e
  notificação encerrados; live do YouTube em vídeo.
- **Desktop (Windows, macOS, Linux)**: o shell do Ultratube (feed, Twitch,
  chat ao vivo, Perguntar, player próprio com MediaKit e catálogo Dart) agora
  roda no desktop. Janelas largas usam barra lateral (com rótulos a partir de
  1200 px) e mini player; a tela Assistir limita o player à altura da janela e
  leva "A seguir" para uma coluna lateral a partir de 1280 px; na Twitch o chat
  vira coluna à direita. Paisagem só vira tela cheia no celular; no desktop é o
  botão ou a tecla F (tela cheia real da janela), Espaço pausa, e passar o mouse
  mostra os controles. Login Google fica só no celular (precisa do WebView nativo).
- Builds desktop: workflow manual "Ultratube Desktop" (`.github/workflows/
  ultratube-desktop.yml`) gera Windows x64 (.zip), Linux x64 (.tar.gz) e macOS
  (.app com assinatura ad-hoc). Compilar Windows localmente exige o Modo de
  Desenvolvedor do Windows (links simbólicos dos plugins); por isso a interface
  desktop ainda não foi vista rodando.

### Celular 1.0.4 — Shorts e Início rápidos, conta e voltar (21/11/2026)

- **Voltar fechava o app (Android 16)**: com targetSdk 36 o `onBackPressed` não é
  mais chamado e o Flutter só registra o `OnBackInvokedCallback` quando o
  framework avisa que há algo para voltar; esse aviso se perdia e o sistema
  fechava a activity. `MainActivity` mantém o callback sempre registrado, então
  o voltar sempre chega ao Flutter. Numa aba que não é o Início, voltar leva ao
  Início; só no Início ele sai do app (`_TabBack` em `app_router.dart`). A tela
  de login do Google também passou a usar o dispatcher novo.
- **Shorts — feed real**: a aba usa o feed de Shorts do próprio YouTube
  (`reel/reel_item_watch` + `reel/reel_watch_sequence`), personalizado com a
  conta conectada e regional sem conta; a busca por temas ficou como reserva.
  Abrir a aba custava 4 buscas com várias páginas; agora são 2 chamadas leves.
- **Shorts — troca rápida**: os 2 próximos Shorts são preparados enquanto o atual
  toca (URL resolvida, capa em cache, título e contadores). Shorts resolvem
  primeiro pelo cliente do app iOS (1 chamada, ~0,45 s contra ~1,2 s da extração
  completa), com o NewPipe como reserva.
- **Shorts — comentários e curtidas**: botão de comentários com a contagem real,
  painel de comentários paginado, curtidas reais no botão (que salva em Curtidos).
- **Início**: abre na hora com a última página salva (até 10 min sem recarregar;
  depois mostra a salva e atualiza por trás). Sem conta, cada fonte aparece assim
  que chega em vez de esperar a mais lenta ("a seguir" do histórico, que exige
  extração completa, vai por último). Com conta, "Para você" é o Início do
  YouTube da conta, na ordem do YouTube, com a prateleira de Shorts dela.
- **Twitch — conta**: entrar pelo código de dispositivo (twitch.tv/activate; a
  senha nunca passa pelo app). Os canais seguidos na conta entram em "Seguindo"
  e são sincronizados ao abrir e ao puxar para atualizar. Tokens no keystore.
- **Twitch — busca e categorias**: sugestões ao digitar, buscas recentes,
  categorias em alta, resultados com filtros (Tudo, Canais, Categorias, Ao vivo,
  Vídeos). Categoria com ordenação, gêneros e aba de vídeos; aba Categorias com
  filtro por gênero; prateleira de categorias em "Ao vivo agora".
- Verificado: `flutter analyze` sem erros; testes novos de Dart (feed de Shorts,
  API da Twitch) e de Kotlin (parser de Shorts contra respostas reais do
  YouTube); APIs conferidas contra os serviços reais (`tool/reels_probe.dart`,
  `tool/twitch_probe.dart`); APK release compila. **Falta validar no S23**: voltar,
  tempo de troca dos Shorts, feed da conta e o login da Twitch com conta real.
  `playback_providers_test` já falhava antes (2 testes do PPPlayer original).

### Celular 1.0.5 — aquecimento e janela flutuante (21/11/2026)

- **Aquecimento**: o player decodificava por hardware mas em modo cópia
  (`hwdec-current=mediacodec-copy`, `vo=gpu`): cada quadro de um Short
  1080×1920 a 60 fps ia para a memória e voltava para a GPU. No Android o
  decodificador agora desenha direto na superfície do vídeo
  (`vo=mediacodec_embed`, `hwdec=mediacodec`). Medido no S23 tocando um
  Short: de ~75–110 % para ~50–60 % de um núcleo; pausado, 0 %. O que sobra é
  o Flutter compondo cada quadro do vídeo.
- Tela de Shorts não é reconstruída a cada atualização de posição (só a linha
  de progresso acompanha); log detalhado do mpv só em build de depuração.
- Shorts: o degradê sob o título engolia os toques e tocar na metade de baixo
  não pausava. Um Short cujo link rápido (cliente iOS) dá 403 passa a ser
  tentado de novo pela extração completa, sem repetir o mesmo link 3 vezes.
- **Janela flutuante (PiP)**: ligada por padrão no Android. Ao sair do app com
  um vídeo, Short ou live da Twitch tocando, ele continua numa janela no
  formato do vídeo (vertical nos Shorts). Botão de PiP no player do YouTube,
  da Twitch e no topo dos Shorts; chave em Você › Ajustes. Corrigido: a janela
  guardava o formato do primeiro vídeo, e ao voltar do PiP a interface ficava
  escondida (o pedido de PiP nunca era dado como concluído).
- Testado no S23 por adb: PiP automático (vídeo e Twitch), botão nos Shorts,
  volta ao app com a interface completa. Não testado: vídeo sem decodificador
  de hardware no modo direto, PiP com legendas e com chat sobreposto.

### Celular 1.0.6 + Relógio 0.5.0 — só áudio, controles no relógio, conta no relógio (21/11/2026)

- **Só áudio de verdade**: virou uma preferência própria (`audioOnlyProvider`).
  Antes, abrir qualquer vídeo forçava `PlayerView.video` e desfazia a escolha.
  Agora a escolha fica entre vídeos, a tela Assistir mostra a capa com o selo
  "Só áudio" em vez de tela preta, e há chave em Você › Reprodução e qualidade.
  Shorts continuam com vídeo.
- **Qualidade do áudio** (Econômica ~50 kbps / Normal ~128 kbps / Alta ~160 kbps,
  `AudioQuality.kt`), aplicada ao só áudio e à faixa de áudio dos vídeos. Em
  vídeos com dublagem a faixa escolhida é sempre a original (antes podia vir a
  dublada ou a cópia "volume estável"). **Economia na rede móvel** (desligada por
  padrão): fora do Wi-Fi, vídeo até 480p e áudio econômico.
- **mpv**: em só áudio a faixa de vídeo fica desligada (`vid=no`) e o cache vira
  2 min / 16 MB; vídeo lê 1 min à frente / 64 MB (antes 100 s / 150 MB + 50 MB
  para trás — memória e dados jogados fora a cada pulo). Com o app em segundo
  plano sem PiP (ou tela bloqueada), a imagem é suspensa: o áudio continua e o
  vídeo não é decodificado nem baixado até voltar.
- **Performance**: a posição do mpv chegava a cada quadro (até 60×/s) e cada
  uma reconstruía o estado do player; agora ~5×/s (saltos e buscas na hora).
  O mini player só reconstrói a linha de progresso.
- **Controles no relógio (sessão de mídia do celular)**: ±10 s (`fastForward`/
  `rewind`), sem barra/busca em lives (antes uma barra parada em 0:00), capa
  reduzida a 512 px (chega mais rápido pelo Bluetooth), e em Shorts
  próximo/anterior passam o feed (antes não faziam nada: a fila tinha 1 item).
- **Relógio — Entrar com o celular**: o Wear OS não tem WebView, então o login
  do Google não abre no relógio. O relógio liga o Wi-Fi, mostra QR + endereço +
  código de 16 caracteres; o celular (já com a conta) envia os cookies cifrados
  com AES-GCM (chave derivada do código, que nunca passa pela rede). Pelo QR a
  câmera abre a página do relógio, que chama `ultratube://link` no app; ou em
  Você › Conectar relógio digitando endereço e código (`WatchLink.kt`,
  `AccountLink.kt`, `WatchLinkActivity.kt`). Com conta: Para você, Inscrições,
  Shorts da conta, Trocar de conta, Sair.
- **Relógio — Shorts**: feed real do YouTube (o mesmo do celular; da conta quando
  conectada) com títulos completados em paralelo e páginas novas ao deslizar;
  resolução rápida pelo cliente do app (como no celular) e áudio econômico no
  vídeo do relógio. A busca por tema ficou como reserva.
- Testes: `WatchLinkTest`, `AudioQualityTest` (JVM), testes Dart do controlador
  e do motor; `flutter analyze` sem erros.
- Limite conhecido: celular e relógio passam a usar a mesma sessão; se o Google
  renovar os cookies em um deles, o outro pode precisar conectar de novo.
- **Testado no Galaxy Watch 7 (0.5.0)**: Entrar com o celular (Wi-Fi ligou sozinho,
  QR + endereço + código; enviado do S23 pelo QR → conta "Gustavo L" no relógio),
  Para você com o Início da conta, Shorts da conta: 6 deslizes seguidos, todos
  tocaram, resolução rápida em ~0,25 s cada. Achado no teste e corrigido: um Short
  cujo link rápido dá 403 era pulado; agora é tentado de novo pela extração
  completa (como no celular). Os botões Músicas · Vídeos · Shorts saíram de
  Para você/Inscrições (buscavam o nome da tela).
- O 0.4.1 do relógio tinha sido assinado com a chave de debug do Windows: foi
  preciso desinstalar (downloads e favoritos do relógio foram apagados).
- Sessão de mídia do celular (o que o relógio controla), testada no S23 com os
  mesmos comandos que o relógio envia: ±10 s num vídeo de 2 h (10 → 20 → 31 → 20 s),
  próximo nos Shorts passa o feed, e numa live a busca (barra) some da sessão.
  O audio_service sempre anuncia ±10 s; numa live o app ignora o comando (a live
  seguiu sem salto). Não testado tocando os botões no próprio relógio.
- **Shorts — atualizar o feed** (celular e relógio): puxar para baixo no primeiro
  Short, botão ⟳ no topo (celular) ou "Atualizar" na fila (relógio), e
  "anterior" no primeiro Short — inclusive vindo do relógio/fone — trazem um
  feed novo. O YouTube começa toda sequência pelo mesmo Short, então os que já
  estavam no feed são descartados. No celular, um Short sem título espera até
  0,8 s pelo título antes de tocar, para a notificação e o relógio não
  mostrarem só "Shorts". Testado no S23: 3 atualizações seguidas, 3 Shorts
  novos com título; próximo/anterior remotos ok. No Galaxy Watch (22/11):
  puxar para baixo no primeiro Short e o botão "Atualizar" trazem feed novo,
  próximo/anterior normais, e um Short com link rápido recusado (403) foi
  recuperado pela extração completa em vez de pulado. O botão "Atualizar"
  ganhou linha própria na fila (três botões não cabiam na tela redonda).

### Código compartilhado celular ↔ relógio (22/11/2026)

- **Letras**: havia três implementações (Kotlin compartilhado, port Dart do iOS e outra
  direto na tela do celular). A tela agora usa o catálogo (`Catalog.lyrics` no Android,
  `DartCatalog.lyrics` no iOS), e a limpeza do título — antes só no relógio — vale para
  todos, com busca de reserva no LRCLIB quando o nome exato não acha. Teste:
  `LyricsTitleTest`.
- **Versões**: `android/gradle/libs.versions.toml` serve às duas builds Gradle que
  compilam `android/media` (o celular importa o arquivo em `settings.gradle.kts`), então
  o módulo compartilhado usa as mesmas bibliotecas nos dois apps.
- README ganhou a seção "Código compartilhado" (o que é comum, o que é port do iOS e o
  que é separado de propósito). Corrigido: o README dizia que o SponsorBlock estava em
  `android/media`; ele só existe no Dart.

### Celular 1.0.7 + Relógio 0.5.1 — portfólio e correções achadas nos prints (22/11/2026)

- **Portfólio** em `docs/portfolio/`: 28 prints do celular, 20 do app do relógio e 3 do
  relógio controlando o celular (recortados no formato redondo), logo (SVG/PNG, ícone,
  símbolo, nome em fundo escuro/claro) e três imagens de destaque. README do projeto
  reescrito com essas imagens.
- **Fila do celular no relógio**: a sessão de mídia nunca publicava a fila, então "faixas
  em fila" no controle do Galaxy Watch ficava vazio. Agora vão até 60 itens em volta do
  atual, e tocar um item no relógio troca a música no celular (`publishQueue`,
  `skipToQueueItem`). Testado: "Reproduzindo a faixa 2 de 21", toque num item → trocou.
- **Play de fora com o celular bloqueado**: o pedido chegava, mas o app ficava sem rede
  ("Unable to resolve host") porque só dizia "tocando" ao Android depois de o vídeo começar
  — sem isso o serviço em primeiro plano não sobe. Agora o play já publica "tocando
  (carregando)". Um play durante a restauração da fila salva era descartado; agora espera
  ela terminar. Vídeo aberto sem nada na tela começa sem a faixa de imagem (o mpv travava
  até o timeout pedindo uma superfície que não existe). Testado: celular bloqueado, app em
  segundo plano, play de fora → toca.
- **Plugins nativos em qualquer motor** (`UltratubeApplication`): quando o audio_service
  liga o Flutter sem a tela (play pelo relógio/fone com o app fechado), os plugins do
  Ultratube não existiam ("No implementation found for method resolve"). Agora o motor é
  criado com eles. Limite que sobra: com o app encerrado pelo sistema, o mpv só termina de
  inicializar com a tela — anotado em "Limites conhecidos".
- **Aba Música do Início** voltou: o gráfico de música do NewPipe parou de responder;
  `Catalog.kiosk` usa uma busca de reserva quando um gráfico falha (vale para o relógio).
- **Textos com `&apos;`/`&nbsp;`** em comentários e descrições: o catálogo compartilhado
  converte o HTML do YouTube em texto; o Dart também trata as entidades (iOS).
- **Relógio**: Letra quebrava ("MediaController method is called from a wrong thread");
  foto da conta saía borrada (pedia 88 px); código de entrada agora numa linha própria.
