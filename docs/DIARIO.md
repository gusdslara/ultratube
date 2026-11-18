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
