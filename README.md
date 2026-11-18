# Ultratube

Cliente de **YouTube, YouTube Music e Twitch sem anúncios**, para celular Android e
**Galaxy Watch (Wear OS)**. Não precisa de conta Google: inscrições, histórico,
playlists e downloads ficam no próprio aparelho.

| App | Pacote | Versão | Testado em |
|---|---|---|---|
| Celular (Flutter) | `app.ultratube.mobile` | 1.0.3 | Galaxy S23 |
| Relógio (Kotlin, Wear OS) | `app.ultratube.wear` | 0.4.1 | Galaxy Watch 7 (SM-L300) |

## De onde veio

O app do celular é um **fork do [PPPlayer](https://github.com/ppplayer-labs/app)**
(Flutter), a partir do commit `6cea891`. Sobre essa base o Ultratube:

- **tirou todos os anúncios**: removeu o Google Mobile Ads e trocou o player/WebView do
  YouTube por extração própria (NewPipeExtractor) + MediaKit;
- ganhou identidade própria (nome, ícone, splash, tema preto OLED + vermelho);
- ganhou tudo o que está na lista abaixo.

O app do relógio e a biblioteca `android/media` são **código novo**, escritos para o Ultratube.

## Recursos

**Celular**
- Início "Para você" (inscrições + "a seguir" do que você viu + categorias), Shorts em feed
  vertical, busca com sugestões e filtros (vídeos, músicas, canais, playlists, álbuns, Shorts).
- Inscrições locais com feed por RSS; importa Google Takeout (`subscriptions.csv`),
  NewPipe e LibreTube.
- Tela Assistir até 4K, toque duplo ±10 s, comentários, "A seguir" com reprodução contínua,
  fila estilo YouTube (arrastar, embaralhar, repetir, salvar como playlist).
- **SponsorBlock** automático (patrocínio, autopromoção, pedidos de inscrição).
- **Downloads offline**: áudio M4A ou vídeo 720p/1080p (sem recodificar), com capa e fila em
  segundo plano.
- **Lives do YouTube** com chat ao vivo sobre o vídeo e contador de espectadores.
- **Twitch sem anúncios**: aba própria (seguindo, ao vivo, categorias, VODs, chat com emotes
  7TV/BTTV). Um proxy HLS local remove os intervalos comerciais.
- **Perguntar (Gemini)**: resumo e explicação do vídeo com marcas de tempo clicáveis, usando a
  chave do Google AI Studio do próprio usuário.
- Letras via LRCLIB.

**Relógio (Galaxy Watch)**
- App independente: não precisa do celular para tocar.
- Busca por voz/texto, música, vídeo (até 360p) e Shorts; fila, favoritos e letras.
- Downloads offline no próprio relógio, timer para pausar (15–90 min) e tela apagada com
  áudio continuando.

## Estrutura

```
ppplayer/           app do celular (fork Flutter do PPPlayer) — também gera iOS
android/media/      biblioteca nativa compartilhada: catálogo NewPipe, player Media3,
                    downloads, SponsorBlock (usada pelo celular e pelo relógio)
android/wear/       app do Galaxy Watch (Wear OS)
docs/DIARIO.md      diário detalhado de cada rodada de desenvolvimento e testes
docs/verificacao/   evidências de teste no relógio
.github/workflows/  build do iOS sem assinatura (disparo manual)
```

O build Android do celular inclui `android/media` como módulo Gradle
(`ppplayer/android/settings.gradle.kts`), então as duas pastas precisam ficar lado a lado.

## Compilar

Requisitos: Flutter (Dart ≥ 3.12), JDK 17+ e Android SDK 35. O `local.properties` e as
chaves de assinatura não são versionados.

```sh
# celular
cd ppplayer
flutter pub get
flutter build apk --release      # ou: flutter run

# relógio
cd android
./gradlew :wear:assembleDebug
adb -s <relógio> install -r wear/build/outputs/apk/debug/wear-debug.apk
```

No Windows, o `flutter pub get` precisa do Modo de Desenvolvedor ligado (links simbólicos).
Para o build release assinado, crie `ppplayer/android/key.properties` com `storeFile`,
`storePassword`, `keyAlias` e `keyPassword`; sem ele, o release usa a chave de debug.

**iOS**: GitHub Actions › *Ultratube iOS (unsigned IPA)* gera um `.ipa` sem assinatura para
instalar com Sideloadly/AltStore. No iOS o catálogo é um port em Dart
(`ppplayer/lib/core/api/`). Ainda não foi testado num iPhone.

## Limites conhecidos

- Alguns Shorts voltam como indisponíveis no NewPipeExtractor v0.27.1 e são pulados.
- A Twitch só deixa listar as 30 maiores lives em "Ao vivo agora" sem token de integridade.
- Ainda falta testar no aparelho: lives no S23, Perguntar com chave real, bateria e Bluetooth
  no relógio. Detalhes em [`docs/DIARIO.md`](docs/DIARIO.md).

## Licença

- Código novo em `android/` e a distribuição Android/Wear combinada: **GPL-3.0-or-later**
  (usa NewPipeExtractor, GPL-3.0). Veja `android/LICENSE` e `android/NOTICE.md`.
- `ppplayer/`: licença do PPPlayer preservada em `ppplayer/COPYING` e `ppplayer/assets/LICENSE`;
  notas do fork em `ppplayer/ULTRATUBE-NOTICE.md`.
- Media3 e OkHttp: Apache-2.0.

Ao distribuir um APK, o código-fonte correspondente precisa estar disponível (este repositório).
Projeto pessoal, sem relação com o Google, o YouTube ou a Twitch.
